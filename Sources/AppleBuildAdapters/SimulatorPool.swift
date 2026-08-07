import Foundation
import MutationExecution
import MutationModel

/// One simulator, as `simctl` describes it.
public struct SimulatorDevice: Codable, Sendable, Hashable {
    public let udid: String
    public let name: String
    /// e.g. `com.apple.CoreSimulator.SimRuntime.iOS-18-2`.
    public let runtimeIdentifier: String
    public let state: String

    public init(udid: String, name: String, runtimeIdentifier: String, state: String) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.state = state
    }

    /// The `-destination` argument that addresses this exact device.
    ///
    /// By UDID, never by name: names are not unique — a machine can carry several
    /// "iPhone 16" devices across runtimes — and `xcodebuild` resolves a duplicate
    /// name to whichever it finds first, which is how two workers end up on one
    /// simulator.
    public var destination: String { "platform=iOS Simulator,id=\(udid)" }

    public var isBooted: Bool { state == "Booted" }
}

/// What `prepare(udid:)` found when it verified a device's readiness, so a run
/// can record whether it found the simulator warm or paid to boot it cold.
public enum BootOutcome: Sendable {
    /// The device was already `Booted` before this call; `bootstatus` confirmed
    /// it ready. The boot command's exit code is irrelevant here (it is non-zero
    /// for an already-booted device — see `prepare`), so this is decided from the
    /// device's state at discovery, not from `boot`'s output.
    case alreadyBooted
    /// The device was not booted; this call booted it and `bootstatus` confirmed
    /// it ready.
    case prepared
}

/// Exclusive use of a simulator for the duration of one mutant's test run.
///
/// The pool hands out at most one lease per device at a time, so two mutants
/// cannot install to the same simulator and read each other's results.
public struct SimulatorLease: Sendable {
    public let device: SimulatorDevice
    public var destination: String { device.destination }
}

public enum SimulatorPoolError: Error, CustomStringConvertible {
    case simctlFailed(detail: String)
    case noneAvailable(runtimeHint: String?)
    case bootFailed(detail: String)

    public var description: String {
        switch self {
        case let .simctlFailed(detail):
            "Could not list simulators: \(detail)"
        case let .noneAvailable(hint):
            if let hint {
                "No available simulator matches \(hint). Install one in Xcode > Settings > Components."
            } else {
                "No available simulators are installed. Add one in Xcode > Settings > Components."
            }
        case let .bootFailed(detail):
            "Could not boot the simulator: \(detail)"
        }
    }
}

/// Leases simulators to concurrent mutants.
///
/// Boot policy: the pool does **not** boot or shut down implicitly on lease
/// — a lease is mutual exclusion, not lifecycle. What changed the original
/// "never boot at all" stance was an empirical finding: the implicit boot
/// `xcodebuild` does on each invocation can race CoreSimulator on a cold
/// device (SBMainWorkspace refusing a launch as "Busy"), and an explicit
/// `simctl boot` + `simctl bootstatus` once, up front, removes that failure
/// mode. So the pool gained `prepare(udid:)` for exactly that call site
/// (`RunCommand`), while lease still has no boot responsibility. A lease
/// taken out on a device the caller has not `prepare`d still works — it
/// just pays the cold-boot tax the first time.
///
/// The pool still never shuts a device down. A booted simulator left
/// behind after a run is no different from one a developer's own
/// Simulator.app session leaves behind, and owning shutdown would mean
/// owning cleanup for processes the pool cannot guarantee it outlives (a
/// killed worker, a `^C`, a timeout). Warm-is-the-new-default: a second
/// run finds the device already booted and skips the boot half of
/// `prepare` entirely.
public actor SimulatorPool {
    /// The process-running capability the pool uses for every `simctl`
    /// invocation. Injectable so the `prepare(udid:)` boot/bootstatus
    /// sequence — which has no other test seam — can be exercised against
    /// scripted `ProcessResult`s without a real simulator.
    public typealias ProcessRunner = (
        _ executable: String,
        _ arguments: [String],
        _ workingDirectory: URL,
        _ timeoutSeconds: Double
    ) async throws -> ProcessResult

    private var devices: [SimulatorDevice] = []
    private var leased: Set<String> = []
    /// Callers waiting for a device to come back.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loaded = false
    private let timeoutSeconds: Double
    private let workingDirectory: URL
    private let runProcess: ProcessRunner

    public init(
        workingDirectory: URL,
        timeoutSeconds: Double = 60,
        processRunner: ProcessRunner? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.runProcess = processRunner ?? Self.defaultProcessRunner
    }

    private static func defaultProcessRunner(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: Double
    ) async throws -> ProcessResult {
        try await ProcessSupervisor.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Every available device, discovering them once per pool.
    public func availableDevices() async throws -> [SimulatorDevice] {
        try await loadIfNeeded()
        return devices
    }

    /// Boots a device (best-effort) and waits for `simctl bootstatus` to
    /// report it truly ready — past the boot animation, SpringBoard up.
    ///
    /// Called once at run start, against the destination the run resolved
    /// to, so the first `xcodebuild` invocation does not pay the cold-boot
    /// cost or hit the "Busy" race a back-to-back install on a cold device
    /// was found to hit. Does **not** take out a lease: callers still need
    /// `lease`/`withLease` to claim exclusive use. Safe to call on a device
    /// that is already booted.
    ///
    /// The boot command's exit code is **ignored**. `simctl boot` returns
    /// non-zero for a device that is already booted (CoreSimulator's actual
    /// message is `"Unable to boot device in current state: Booted"`, which
    /// a prior version of this code tried to string-match against a
    /// nonexistent `"already booted"` token — silently breaking every warm
    /// run). Rather than chase the exact phrasing across toolchain
    /// versions, the boot command is treated as a hint: the real readiness
    /// gate is `simctl bootstatus`, which blocks until the device is past
    /// the boot animation and actually usable, and is a fast no-op on a
    /// warm device. A genuine boot failure (corrupt device, missing
    /// runtime) surfaces as a bootstatus failure with a more informative
    /// diagnostic than `simctl boot` would have produced anyway.
    ///
    /// Returns whether the device was already booted (`.alreadyBooted`) or
    /// booted by this call (`.prepared`), decided from the device's state at
    /// discovery — `simctl boot`'s exit code cannot tell the two apart, since an
    /// already-booted device exits non-zero (see above). Throws on any failure
    /// to launch the process, or on a `bootstatus` that still does not report
    /// ready after every retry (see `bootstatusRetries`).
    ///
    /// `bootstatusRetries` exists because a `bootstatus` failure under real,
    /// heavy host contention (many concurrent simulator boots on a shared CI
    /// runner) is routinely transient, not a genuinely broken device — a
    /// second attempt on the same UDID, moments later, has repeatedly
    /// succeeded in exactly that situation. Each retry re-issues *both*
    /// `boot` and `bootstatus`, since a `bootstatus` that gave up may have
    /// left the device in a state only a fresh `boot` call resolves. A short
    /// fixed delay between attempts (`retryDelaySeconds`) gives transient
    /// host load a moment to actually clear rather than hammering an
    /// already-overloaded host immediately again.
    @discardableResult
    public func prepare(
        udid: String,
        bootTimeoutSeconds: Double = 90,
        bootstatusRetries: Int = 2,
        retryDelaySeconds: UInt64 = 5
    ) async throws -> BootOutcome {
        try await loadIfNeeded()
        guard let device = devices.first(where: { $0.udid == udid }) else {
            throw SimulatorPoolError.noneAvailable(runtimeHint: udid)
        }
        let wasBooted = device.isBooted

        var lastFailure: SimulatorPoolError = .bootFailed(detail: "prepare never attempted a boot")
        for attempt in 0 ... max(bootstatusRetries, 0) {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
            }
            do {
                try await attemptBoot(udid: udid, bootTimeoutSeconds: bootTimeoutSeconds)
                return wasBooted ? .alreadyBooted : .prepared
            } catch let error as SimulatorPoolError {
                lastFailure = error
            }
        }
        throw lastFailure
    }

    /// One `simctl boot` + `simctl bootstatus` attempt — the body `prepare`
    /// retries as a unit. Split out purely so retrying means calling this
    /// again, not duplicating the sequence inline per attempt.
    private func attemptBoot(udid: String, bootTimeoutSeconds: Double) async throws {
        // Best-effort boot: the exit code is intentionally not checked.
        // See `prepare`'s own doc for why — the short version is that every
        // already-booted device exits non-zero here, and the string the
        // tool prints varies across toolchain versions, so the only robust
        // signal is bootstatus below. A throw (process could not be
        // launched at all) is still fatal.
        do {
            _ = try await runProcess(
                ToolPaths.xcrun, ["simctl", "boot", udid],
                workingDirectory, bootTimeoutSeconds
            )
        } catch {
            throw SimulatorPoolError.bootFailed(detail: "\(error)")
        }

        // bootstatus blocks until the device is past the boot animation and
        // actually usable. On a warm device it returns immediately. This is
        // the real gate: a failure here means the device is genuinely
        // unavailable, regardless of what `boot` printed.
        let statusResult: ProcessResult
        do {
            statusResult = try await runProcess(
                ToolPaths.xcrun, ["simctl", "bootstatus", udid],
                workingDirectory, bootTimeoutSeconds
            )
        } catch {
            throw SimulatorPoolError.bootFailed(detail: "bootstatus could not be run: \(error)")
        }
        if !statusResult.succeeded {
            let output = OutputRedactor.redactAndTruncate(statusResult.combinedOutput, limit: 400)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorPoolError.bootFailed(detail: output)
        }
    }

    /// Takes exclusive use of a simulator, waiting if every match is busy.
    ///
    /// `runtimeHint` narrows by runtime or device name (e.g. `iOS-18`, `iPhone`);
    /// `nil` accepts any available device.
    ///
    /// Ambiguous by construction when a name matches devices under more than
    /// one runtime: `candidates` keeps every match, and whichever sorts
    /// first in `devices` (by `(runtimeIdentifier, name)`, so lexicographic
    /// on the runtime string — the *older* runtime, not necessarily the
    /// latest) wins if both happen to be free. Callers that already know
    /// exactly which device a run resolved to — see `DestinationResolver` —
    /// should use `lease(udid:)` instead, which has no such ambiguity to
    /// resolve.
    public func lease(matching runtimeHint: String? = nil) async throws -> SimulatorLease {
        try await loadIfNeeded()

        let candidates = devices.filter { device in
            guard let runtimeHint else { return true }
            return device.runtimeIdentifier.localizedCaseInsensitiveContains(runtimeHint)
                || device.name.localizedCaseInsensitiveContains(runtimeHint)
        }

        guard !candidates.isEmpty else {
            throw SimulatorPoolError.noneAvailable(runtimeHint: runtimeHint)
        }

        return try await waitForLease(among: candidates, hint: runtimeHint)
    }

    /// Takes exclusive use of one exact device, waiting if it is busy.
    ///
    /// Unlike `lease(matching:)`, there is nothing to disambiguate: the
    /// caller already resolved which device it wants (see
    /// `DestinationResolver`), and this either has that UDID or it doesn't.
    public func lease(udid: String) async throws -> SimulatorLease {
        try await loadIfNeeded()

        guard let device = devices.first(where: { $0.udid == udid }) else {
            throw SimulatorPoolError.noneAvailable(runtimeHint: udid)
        }

        return try await waitForLease(among: [device], hint: udid)
    }

    private func waitForLease(among candidates: [SimulatorDevice], hint: String?) async throws -> SimulatorLease {
        while true {
            if let free = candidates.first(where: { !leased.contains($0.udid) }) {
                leased.insert(free.udid)
                return SimulatorLease(device: free)
            }
            // Every match is busy. Suspend until a release wakes us; the actor
            // serialises this, so no two callers can claim the same device.
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Returns a leased device to the pool. Must be called for every `lease`,
    /// including on the failure paths, or the pool leaks capacity.
    public func release(_ lease: SimulatorLease) {
        leased.remove(lease.device.udid)
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Leases a device, runs `body`, and always returns the device.
    ///
    /// Preferred over the bare calls: the release happens even when `body` throws
    /// or the task is cancelled, which is what keeps a timed-out mutant from
    /// permanently removing a simulator from the pool.
    public func withLease<T: Sendable>(
        matching runtimeHint: String? = nil,
        _ body: (SimulatorLease) async throws -> T
    ) async throws -> T {
        let lease = try await lease(matching: runtimeHint)
        defer { release(lease) }
        return try await body(lease)
    }

    /// Leases one exact device, runs `body`, and always returns the device.
    /// See `lease(udid:)`.
    public func withLease<T: Sendable>(
        udid: String,
        _ body: (SimulatorLease) async throws -> T
    ) async throws -> T {
        let lease = try await lease(udid: udid)
        defer { release(lease) }
        return try await body(lease)
    }

    // MARK: - Discovery

    private func loadIfNeeded() async throws {
        guard !loaded else { return }

        let arguments = ["simctl", "list", "devices", "available", "--json"]
        let result: ProcessResult
        do {
            result = try await runProcess(
                ToolPaths.xcrun, arguments,
                workingDirectory, timeoutSeconds
            )
        } catch {
            throw SimulatorPoolError.simctlFailed(detail: "\(error)")
        }

        guard result.succeeded else {
            throw SimulatorPoolError.simctlFailed(
                detail: OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        devices = try Self.parse(result.standardOutput)
        loaded = true
    }

    /// Parses `simctl list devices available --json`.
    ///
    /// The payload keys devices by runtime identifier, so the runtime is carried
    /// down onto each device rather than being lost with the grouping.
    static func parse(_ data: Data) throws -> [SimulatorDevice] {
        struct Payload: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
                /// `available` is already implied by the query, but a device can
                /// still report itself unusable.
                let isAvailable: Bool?
            }

            let devices: [String: [Device]]
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw SimulatorPoolError.simctlFailed(detail: "simctl emitted unreadable JSON: \(error)")
        }

        return payload.devices
            .flatMap { runtime, devices in
                devices
                    .filter { $0.isAvailable ?? true }
                    .map {
                        SimulatorDevice(
                            udid: $0.udid,
                            name: $0.name,
                            runtimeIdentifier: runtime,
                            state: $0.state
                        )
                    }
            }
            // Sorted so that a given machine leases devices in a repeatable order
            // and a failing run can be reproduced against the same simulator.
            .sorted { ($0.runtimeIdentifier, $0.name) < ($1.runtimeIdentifier, $1.name) }
    }
}
