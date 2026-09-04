import Darwin
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
    ///
    /// The `platform=` value is derived from `runtimeIdentifier`, not
    /// hardcoded to iOS Simulator — this was previously wrong
    /// unconditionally: `SimulatorPool.parse` groups devices by whatever
    /// runtime `simctl list devices` itself reports, with no iOS filter at
    /// all, so a machine with tvOS/watchOS/visionOS runtimes installed
    /// already has those devices flowing through this same type — and
    /// every one of them was getting labeled `platform=iOS Simulator`
    /// regardless. A UDID is unambiguous on its own, so `xcodebuild` may
    /// well have tolerated the mismatched label in practice, but shipping a
    /// destination string that misdescribes the device's own platform is
    /// wrong independently of whether `xcodebuild` happens to forgive it —
    /// and `DestinationResolver`'s own doc comment already treats "which
    /// runtime did this actually run against" as a question that must have
    /// one honest answer, not a guess.
    public var destination: String { "platform=\(Self.platformLabel(forRuntimeIdentifier: runtimeIdentifier)),id=\(udid)" }

    /// Maps a `simctl`-reported runtime identifier
    /// (`com.apple.CoreSimulator.SimRuntime.<Platform>-<Major>-<Minor>`, e.g.
    /// `...SimRuntime.tvOS-17-0`) to the platform name `xcodebuild
    /// -destination`'s own `platform=` key expects. Covers every
    /// simulator-capable Apple platform `simctl` reports today; visionOS's
    /// own runtime identifier segment is `xrOS`, not `visionOS` — confirmed
    /// against Apple's own `SimRuntime` naming — but `-destination` still
    /// expects `platform=visionOS Simulator`, so that mapping is deliberate,
    /// not a typo.
    ///
    /// An identifier this cannot classify is real `simctl` data this type
    /// has never observed — rather than silently mislabeling it as iOS (the
    /// exact bug this method exists to fix), the raw runtime identifier is
    /// used as the platform label verbatim, which reliably produces a clear
    /// "no such platform" `xcodebuild` error instead of a silently-wrong,
    /// misleadingly-plausible one.
    private static func platformLabel(forRuntimeIdentifier runtimeIdentifier: String) -> String {
        if runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.tvOS") {
            "tvOS Simulator"
        } else if runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.watchOS") {
            "watchOS Simulator"
        } else if runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.xrOS") {
            "visionOS Simulator"
        } else if runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.iOS") {
            "iOS Simulator"
        } else {
            runtimeIdentifier
        }
    }

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
    /// A caller tried to delete or otherwise dispose of a device this same
    /// pool instance currently has leased out to a mutant's test run. Purely
    /// defense-in-depth: the realistic caller (`RunCommand`'s
    /// `provisionSimulatorWorkerPoolIfNeeded`) uses a dedicated,
    /// never-leased `SimulatorPool` instance just for provisioning/cleanup,
    /// so `leased` is always empty on it — but nothing in the public API
    /// enforces that separation, so a future caller that reused one pool
    /// for both leasing and cleanup must not be able to silently delete a
    /// device out from under an in-flight test.
    case deviceIsLeased(udid: String)

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
        case let .deviceIsLeased(udid):
            "Refusing to delete \(udid): it is currently leased to an in-flight test run."
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
    /// ready after every retry (see `bootstatusRetries`). Propagates
    /// cancellation immediately — a caller that cancelled `prepare` (a CLI
    /// stop, an overall run timeout) must never see one more `simctl`
    /// process launched on its behalf after that.
    ///
    /// `bootstatusRetries` exists because a `bootstatus` **non-zero exit or
    /// timeout** under real, heavy host contention (many concurrent
    /// simulator boots on a shared CI runner) is routinely transient, not a
    /// genuinely broken device — a second attempt on the same UDID, moments
    /// later, has repeatedly succeeded in exactly that situation. Only that
    /// case retries. A `boot`/`bootstatus` process that could not even be
    /// *launched* (`xcrun` missing, a sandboxing/permission failure) is a
    /// structural host problem retrying cannot fix, and throws immediately
    /// — see `BootAttemptFailure`. Each retry re-issues *both* `boot` and
    /// `bootstatus`, since a `bootstatus` that gave up may have left the
    /// device in a state only a fresh `boot` call resolves. A short fixed
    /// delay between attempts (`retryDelaySeconds`) gives transient host
    /// load a moment to actually clear rather than hammering an
    /// already-overloaded host immediately again.
    @discardableResult
    public func prepare(
        udid: String,
        bootTimeoutSeconds: Double = 90,
        bootstatusRetries: Int = 2,
        retryDelaySeconds: Double = 5
    ) async throws -> BootOutcome {
        try await loadIfNeeded()
        guard let device = devices.first(where: { $0.udid == udid }) else {
            throw SimulatorPoolError.noneAvailable(runtimeHint: udid)
        }
        let wasBooted = device.isBooted

        var lastRetryableDetail = "prepare never attempted a boot"
        for attempt in 0 ... max(bootstatusRetries, 0) {
            if attempt > 0 {
                // Not `try?`: a cancellation here must abort `prepare`
                // outright, not be swallowed into "start the next attempt
                // anyway".
                try await Task.sleep(for: .seconds(retryDelaySeconds))
            }
            do {
                try await attemptBoot(udid: udid, bootTimeoutSeconds: bootTimeoutSeconds)
                return wasBooted ? .alreadyBooted : .prepared
            } catch let error as BootAttemptFailure {
                switch error {
                case let .retryableBootstatus(detail):
                    lastRetryableDetail = detail
                case let .fatalInvocation(detail):
                    throw SimulatorPoolError.bootFailed(detail: detail)
                }
            }
        }
        throw SimulatorPoolError.bootFailed(detail: lastRetryableDetail)
    }

    /// `attemptBoot`'s own failure classification — kept separate from the
    /// public `SimulatorPoolError` so `prepare`'s retry loop can tell "worth
    /// trying again" apart from "a structural problem retrying cannot fix"
    /// without re-deriving that distinction from a `bootFailed` string.
    private enum BootAttemptFailure: Error {
        /// `bootstatus` ran and reported not-ready (non-zero exit or
        /// timeout) — the one case `prepare` retries.
        case retryableBootstatus(detail: String)
        /// `boot` or `bootstatus` itself could not be launched at all — a
        /// structural host problem, not a device-readiness one; retrying
        /// would just repeat the same failure.
        case fatalInvocation(detail: String)
    }

    /// One `simctl boot` + `simctl bootstatus` attempt — the body `prepare`
    /// retries as a unit. Split out purely so retrying means calling this
    /// again, not duplicating the sequence inline per attempt.
    ///
    /// `Task.checkCancellation()` before each of the two process launches,
    /// not just at the top: `runProcess` blocks on a real subprocess and
    /// does not itself observe cancellation, so a cancellation that lands
    /// *while* `boot` is running would otherwise still be free to launch
    /// `bootstatus` next, once `boot` happens to finish — the exact "one
    /// more process launched after cancellation" `prepare`'s own doc
    /// promises never happens. A `CancellationError` the injected
    /// `runProcess` itself throws is rethrown as-is (never folded into
    /// `.fatalInvocation`), so it keeps propagating as cancellation rather
    /// than becoming an ordinary, retryable-looking failure.
    private func attemptBoot(udid: String, bootTimeoutSeconds: Double) async throws {
        try Task.checkCancellation()

        // Best-effort boot: the exit code is intentionally not checked.
        // See `prepare`'s own doc for why — the short version is that every
        // already-booted device exits non-zero here, and the string the
        // tool prints varies across toolchain versions, so the only robust
        // signal is bootstatus below. A throw here means the process could
        // not be *launched* at all (not a non-zero exit) — fatal, not
        // retried.
        do {
            _ = try await runProcess(
                ToolPaths.xcrun, ["simctl", "boot", udid],
                workingDirectory, bootTimeoutSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BootAttemptFailure.fatalInvocation(detail: "boot could not be launched: \(error)")
        }

        try Task.checkCancellation()

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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BootAttemptFailure.fatalInvocation(detail: "bootstatus could not be launched: \(error)")
        }

        try Task.checkCancellation()

        if !statusResult.succeeded {
            let output = OutputRedactor.redactAndTruncate(statusResult.combinedOutput, limit: 400)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BootAttemptFailure.retryableBootstatus(detail: output)
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

    // MARK: - Worker-pool cloning

    /// Every MutantKit-created clone's name carries this prefix, so a later
    /// run can find exactly the clones this tool created and nothing else,
    /// regardless of what a developer has named their own simulators.
    /// `simctl clone`'s new-name argument accepts any string; nothing about
    /// this prefix is special to CoreSimulator, it is purely a convention
    /// this type imposes and later greps for.
    ///
    /// Every clone's name also embeds the PID of the process that created
    /// it (`ownedCloneLabel(_:)`), so `cleanupOrphanClones()` can tell a
    /// clone that belongs to a *currently running* MutantKit process (do
    /// not touch — it may still be mid-test) apart from one whose owning
    /// process is confirmed dead (safe to sweep). Without this, a global
    /// sweep by name prefix alone could delete a concurrently-running run's
    /// live devices — see `parseOwnerPID(fromCloneName:)`.
    public static let clonePrefix = "mutantkit-clone-"

    /// Builds the full label passed to `cloneDevice(from:label:)`, embedding
    /// this process's PID ahead of the caller-supplied, human-readable
    /// suffix. Format: `<pid>-<suffix>`. Parsed back by
    /// `parseOwnerPID(fromCloneName:)`.
    private static func ownedCloneLabel(_ suffix: String) -> String {
        "\(ProcessInfo.processInfo.processIdentifier)-\(suffix)"
    }

    /// Recovers the owning process's PID from a clone's full device name
    /// (`clonePrefix` + `ownedCloneLabel(_:)`'s output), if the name is
    /// shaped as this pool itself would have produced it. A clone name that
    /// does not parse (e.g. hand-created, or from a version of this tool
    /// predating PID-embedding) is treated as ownerless — `cleanupOrphanClones`
    /// still sweeps it, matching this method's only caller's own fallback.
    static func parseOwnerPID(fromCloneName name: String) -> Int32? {
        guard name.hasPrefix(clonePrefix) else { return nil }
        let remainder = name.dropFirst(clonePrefix.count)
        guard let dashIndex = remainder.firstIndex(of: "-") else { return nil }
        return Int32(remainder[remainder.startIndex ..< dashIndex])
    }

    /// Mirrors `RunIsolationLock`'s own private `processIsAlive(_:)` exactly
    /// (`kill(pid, 0) == 0` means alive and signalable; `errno == EPERM`
    /// means alive but owned by another user, e.g. root) — duplicated here
    /// rather than shared because that method is private to its own file.
    private static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public enum SimulatorCloneError: Error, CustomStringConvertible, Sendable {
        case cloneFailed(source: String, detail: String)
        case cloneNotFound(udid: String)
        case bootFailed(udid: String, detail: String)

        public var description: String {
            switch self {
            case let .cloneFailed(source, detail):
                "Could not clone simulator \(source): \(detail)"
            case let .cloneNotFound(udid):
                "simctl clone reported UDID \(udid), but it does not appear in `simctl list` afterward."
            case let .bootFailed(udid, detail):
                "Clone \(udid) could not be booted: \(detail)"
            }
        }
    }

    /// Clones `source` via `simctl clone`, then re-lists devices so the
    /// clone's full `SimulatorDevice` record (name, runtime, state) is
    /// known — `simctl clone` itself only ever prints the new UDID, never
    /// the rest of the record.
    ///
    /// Does **not** boot or lease the clone; callers needing a ready
    /// device call `prepare(udid:)` afterward, same as any other device —
    /// cloning and booting are kept as separate steps for the same reason
    /// leasing and booting already are (see this type's own doc comment).
    public func cloneDevice(from source: SimulatorDevice, label: String) async throws -> SimulatorDevice {
        let name = "\(Self.clonePrefix)\(label)"
        let result: ProcessResult
        do {
            result = try await runProcess(
                ToolPaths.xcrun, ["simctl", "clone", source.udid, name],
                workingDirectory, timeoutSeconds
            )
        } catch {
            throw SimulatorCloneError.cloneFailed(source: source.udid, detail: "\(error)")
        }

        guard result.succeeded else {
            throw SimulatorCloneError.cloneFailed(
                source: source.udid,
                detail: OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let newUDID = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Force a fresh `simctl list` — the clone did not exist at the
        // last load, and a stale cache would report it missing forever.
        loaded = false
        try await loadIfNeeded()

        guard let device = devices.first(where: { $0.udid == newUDID }) else {
            throw SimulatorCloneError.cloneNotFound(udid: newUDID)
        }
        return device
    }

    /// Deletes a device via `simctl delete`. The caller is responsible for
    /// only ever passing a UDID this pool itself created (`cloneDevice`) —
    /// this method has no way to verify that and does not try to; see
    /// `releaseWorkerPool`/`cleanupOrphanClones`, the two call sites that
    /// actually enforce the `clonePrefix` naming convention before ever
    /// reaching here.
    public func deleteDevice(udid: String) async throws {
        guard !leased.contains(udid) else {
            throw SimulatorPoolError.deviceIsLeased(udid: udid)
        }

        // Best-effort shutdown first: `simctl delete` has been observed to
        // succeed against an already-booted device directly, but shutting
        // down first is the documented-safe order and costs nothing when
        // the device is already shut down (a no-op, exit code ignored).
        _ = try? await runProcess(ToolPaths.xcrun, ["simctl", "shutdown", udid], workingDirectory, timeoutSeconds)

        let result = try await runProcess(ToolPaths.xcrun, ["simctl", "delete", udid], workingDirectory, timeoutSeconds)
        guard result.succeeded else {
            throw SimulatorPoolError.simctlFailed(
                detail: "could not delete \(udid): "
                    + OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        devices.removeAll { $0.udid == udid }
    }

    /// Provisions `count` devices for worker-affinity assignment: index 0
    /// is `base` itself — the pool must never delete, shut down, or
    /// otherwise treat as disposable a device it did not create — and
    /// indices `1..<count` are fresh clones of `base`, each booted and
    /// `bootstatus`-verified before this returns.
    ///
    /// **`base` is shut down before cloning, if it is booted, and rebooted
    /// afterward.** Confirmed directly against a real simulator, not
    /// assumed: `simctl clone` refuses to clone a booted source
    /// (`"Unable to clone device in current state: Booted"`, exit 405) —
    /// a real constraint this method works around rather than documents
    /// as a caller's problem, since the realistic caller
    /// (`RunCommand.provisionSimulatorWorkerPoolIfNeeded`) only ever
    /// reaches this *after* `prepareSimulatorForRun()` has already booted
    /// `base` for the run's own baseline. Every clone is created while
    /// `base` is shut down, then `base` and every clone are booted
    /// together at the end — never booted, cloned-from, then rebooted
    /// per clone, which would pay the boot/shutdown cost once per clone
    /// instead of once total.
    ///
    /// Throws, rather than returning a partial pool, on the first clone or
    /// boot failure: a caller that received fewer devices than it asked
    /// for with no error would silently under-parallelize with no signal
    /// at all — exactly the "never silently reduce worker count without
    /// reporting it" requirement this feature is held to. Every clone
    /// already created before the failure is deleted before the error
    /// propagates, so a failed provision leaves no orphaned clones behind
    /// for `cleanupOrphanClones` to find on some later, unrelated run. If
    /// `base` itself had to be shut down to make cloning possible, this
    /// method always attempts to reboot it before returning or throwing —
    /// a caller must never be left with a `base` this method quietly put
    /// to sleep and never woke back up.
    public func provisionWorkerPool(base: SimulatorDevice, count: Int) async throws -> [SimulatorDevice] {
        guard count > 1 else { return [base] }

        // Defense-in-depth, matching `deleteDevice`'s own guard: this call
        // is about to shut `base` down out from under whatever holds it, so
        // it must not proceed if this same pool instance has `base` leased
        // to an in-flight test right now.
        guard !leased.contains(base.udid) else {
            throw SimulatorPoolError.deviceIsLeased(udid: base.udid)
        }

        // `base.isBooted` (the caller's own copy) is not trusted here: the
        // realistic caller (`RunCommand`) resolves its `SimulatorDevice`
        // value *before* `prepareSimulatorForRun()` boots it, so that
        // value's own `state` field reads stale ("Shutdown") even once the
        // real device is actually booted -- confirmed the hard way, by a
        // unit test written against exactly this sequence that failed
        // against the caller's-copy check and only passed once this was
        // switched to a fresh, forced re-list. Never skip the shutdown
        // step on a state field that might be lying.
        loaded = false
        try await loadIfNeeded()
        let wasBaseBooted = devices.first(where: { $0.udid == base.udid })?.isBooted ?? base.isBooted
        if wasBaseBooted {
            _ = try? await runProcess(ToolPaths.xcrun, ["simctl", "shutdown", base.udid], workingDirectory, timeoutSeconds)
        }

        var provisioned: [SimulatorDevice] = [base]

        do {
            for index in 1 ..< count {
                let clone = try await cloneDevice(from: base, label: Self.ownedCloneLabel("worker\(index)-\(UUID().uuidString.prefix(8))"))
                // Recorded *before* `prepare`, not after: a boot failure
                // must still roll this clone back. Appending only on
                // success left a booted-but-failed clone permanently
                // untracked and undeleted -- caught by
                // `SimulatorPoolCloningTests.provisionBootFailureRollsBack`.
                provisioned.append(clone)
            }
            // Every device -- base included -- boots only after every
            // clone already exists, so a boot never has to be redone.
            for device in provisioned {
                try await prepare(udid: device.udid)
            }
        } catch {
            if wasBaseBooted {
                _ = try? await prepare(udid: base.udid)
            }
            // Roll back every clone this call itself created — never
            // `base`, and never a clone some other, unrelated call created
            // (provisioned only ever contains this call's own additions
            // past index 0).
            for created in provisioned.dropFirst() {
                _ = try? await deleteDevice(udid: created.udid)
            }
            throw error
        }

        return provisioned
    }

    /// Deletes every clone `provisionWorkerPool` created — every element
    /// of `devices` except `base` itself, which this method never deletes
    /// regardless of what is passed. Best-effort per device: one failed
    /// deletion is recorded and every other deletion still proceeds,
    /// rather than aborting the whole cleanup — an orphaned clone
    /// `cleanupOrphanClones` will find on the next run is a far cheaper
    /// failure mode than leaving nine other clones undeleted because the
    /// tenth failed.
    ///
    /// Returns the UDIDs that failed to delete, for the caller to log —
    /// never thrown, since cleanup failing is not this run's own result to
    /// fail on.
    @discardableResult
    public func releaseWorkerPool(_ devices: [SimulatorDevice], base: SimulatorDevice) async -> [String] {
        var failures: [String] = []
        for device in devices where device.udid != base.udid {
            do {
                try await deleteDevice(udid: device.udid)
            } catch {
                failures.append(device.udid)
            }
        }
        return failures
    }

    /// Finds and deletes every simulator already on this machine whose
    /// name carries `clonePrefix` **and** whose embedded owning PID
    /// (`parseOwnerPID(fromCloneName:)`) is confirmed dead — orphans left
    /// behind by a process that was killed before `releaseWorkerPool` ever
    /// ran (a crash, a `SIGKILL`, a forced quit).
    ///
    /// Deliberately does **not** delete a clone whose owning PID is still
    /// alive: that clone belongs to a concurrently-running MutantKit
    /// process (a different project, or the same project on a different
    /// destination) that may still be mid-test against it. Without this
    /// check, a global sweep by name prefix alone could delete another
    /// live run's devices out from under it — found by adversarial review
    /// of this exact method before it shipped. A clone name that does not
    /// parse as this pool's own PID-embedding format (e.g. hand-created,
    /// or produced by a version of this tool that predates PID-embedding)
    /// is still swept, since there is no owner to check aliveness against.
    ///
    /// Intended to be called once, early, by any entry point that is about
    /// to provision a fresh worker pool — so a machine that has
    /// accumulated orphaned clones across several interrupted runs is
    /// swept clean before adding more, rather than accumulating them
    /// indefinitely. Safe to call even when nothing needs cleaning: an
    /// empty match list does nothing.
    ///
    /// Matches on name only (plus the PID-liveness check above), the same
    /// pragmatic, not-symbol-resolved convention this codebase already uses
    /// elsewhere (`OperatorExclusions`' builder-property-name matching,
    /// `LifecycleSuperCallRemovalOperator`'s method-name denylist) — a
    /// developer's own simulator named with this exact prefix by
    /// coincidence is an accepted, vanishingly unlikely false positive, not
    /// a risk this type tries to eliminate further.
    @discardableResult
    public func cleanupOrphanClones() async -> [String] {
        loaded = false
        try? await loadIfNeeded()

        let candidates = devices.filter { $0.name.hasPrefix(Self.clonePrefix) }
        let orphans = candidates.filter { candidate in
            guard let ownerPID = Self.parseOwnerPID(fromCloneName: candidate.name) else {
                // Unparseable name: no owner to check, treat as an orphan.
                return true
            }
            return !Self.processIsAlive(ownerPID)
        }
        var failures: [String] = []
        for orphan in orphans {
            do {
                try await deleteDevice(udid: orphan.udid)
            } catch {
                failures.append(orphan.udid)
            }
        }
        return failures
    }
}
