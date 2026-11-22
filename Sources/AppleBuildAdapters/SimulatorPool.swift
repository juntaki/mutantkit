import Foundation
import MutationExecution

/// One simulator, as `simctl` describes it.
///
/// This is the shape encoded into run manifests (via `ResolvedDestination`), so
/// it must stay `{udid, name, runtimeIdentifier, state}`: the runtime's platform
/// and version are catalog-side facts (`CatalogDevice`), and the identifier is
/// an opaque key that is never parsed.
public struct SimulatorDevice: Codable, Sendable, Hashable {
    public let udid: String
    public let name: String
    /// Opaque runtime key, e.g. `com.apple.CoreSimulator.SimRuntime.iOS-18-2`.
    public let runtimeIdentifier: String
    public let state: String

    public init(udid: String, name: String, runtimeIdentifier: String, state: String) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.state = state
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
    /// The `-destination` addressing this device by UDID, with the platform
    /// label taken from its runtime's `platform` field.
    public let destination: String

    public init(device: SimulatorDevice, destination: String) {
        self.device = device
        self.destination = destination
    }
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

    /// The one source of truth for discovered devices; `devices` is a view of it.
    var catalog = SimulatorRuntimeCatalog(runtimes: [])
    var devices: [SimulatorDevice] { catalog.devices.map(\.device) }
    var leased: Set<String> = []
    /// UDIDs a `deleteDevice` is in the middle of removing: reserved from before its
    /// first `await`, so no lease can be granted on a device that is being deleted.
    var deleting: Set<String> = []
    /// Callers waiting for a device to come back.
    var waiters: [CheckedContinuation<Void, Never>] = []
    var loaded = false
    /// Bumped by every `invalidate()` and `deleteDevice`; a load started under an
    /// older generation is stale and its result is never committed.
    var generation = 0
    let timeoutSeconds: Double
    let workingDirectory: URL
    let runProcess: ProcessRunner

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

    /// The runtime catalog, discovering it once per pool.
    public func runtimeCatalog() async throws -> SimulatorRuntimeCatalog {
        try await loadIfNeeded()
        return catalog
    }

    /// Every available device with its runtime's platform and version.
    public func catalogDevices() async throws -> [CatalogDevice] {
        try await loadIfNeeded()
        return catalog.devices
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
    func attemptBoot(udid: String, bootTimeoutSeconds: Double) async throws {
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
    /// one runtime: `candidates` keeps every match in catalog order (runtime
    /// version ascending, then runtime identifier, then name, then UDID), so the
    /// *oldest* matching runtime's device wins if several are free — not
    /// necessarily the latest. Callers that already know exactly which device a
    /// run resolved to — see `DestinationResolver` — should use `lease(udid:)`
    /// instead, which has no such ambiguity to resolve.
    public func lease(matching runtimeHint: String? = nil) async throws -> SimulatorLease {
        try await loadIfNeeded()

        let candidates = catalog.devices.filter { device in
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

        guard !deleting.contains(udid), let device = catalog.devices.first(where: { $0.udid == udid }) else {
            throw SimulatorPoolError.noneAvailable(runtimeHint: udid)
        }

        return try await waitForLease(among: [device], hint: udid)
    }

    private func waitForLease(among candidates: [CatalogDevice], hint: String?) async throws -> SimulatorLease {
        while true {
            // Also after waking from a release: a cancelled waiter must not take it.
            try Task.checkCancellation()
            // A candidate deleted while we waited is gone for good: don't wait for it.
            let present = candidates.filter { candidate in catalog.devices.contains { $0.udid == candidate.udid } }
            if present.isEmpty { throw SimulatorPoolError.noneAvailable(runtimeHint: hint) }
            if let free = present.first(where: { !leased.contains($0.udid) && !deleting.contains($0.udid) }) {
                leased.insert(free.udid)
                return SimulatorLease(device: free.device, destination: free.destination)
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

    /// Forces the next `loadIfNeeded` to list again. A load already running in
    /// another caller started before this call is stale and is never committed.
    func invalidate() {
        loaded = false
        generation += 1
    }

    /// Loads the catalog if it is not loaded: each caller lists in its own task
    /// (structured, so its cancellation is its own; concurrent cold callers may
    /// list twice, as they always did).
    ///
    /// A result is committed only if no `invalidate()`/`deleteDevice` happened
    /// while it was being read and nobody else committed meanwhile. A stale
    /// result — or a failure of a stale load — is dropped and the loop re-reads,
    /// so it can neither overwrite newer state nor fail a caller whose own,
    /// newer state is fine.
    func loadIfNeeded() async throws {
        while !loaded {
            try Task.checkCancellation()
            let startedAt = generation
            let built: SimulatorRuntimeCatalog
            do {
                built = try await fetchCatalog()
            } catch {
                if error is CancellationError { throw error }
                if startedAt != generation || loaded { continue }
                throw error
            }
            try Task.checkCancellation()
            guard startedAt == generation, !loaded else { continue }
            catalog = built
            loaded = true
        }
        // A warm pool, or a loop left by a stale failure, never saw the caller's
        // cancellation: a cancelled caller must not proceed to lease or boot.
        try Task.checkCancellation()
    }

    private func fetchCatalog() async throws -> SimulatorRuntimeCatalog {
        try Task.checkCancellation()
        let runtimesJSON = try await runSimctlList(SimulatorRuntimeCatalog.runtimesArguments)
        try Task.checkCancellation()
        let devicesJSON = try await runSimctlList(SimulatorRuntimeCatalog.devicesArguments)
        try Task.checkCancellation()
        do {
            return try SimulatorRuntimeCatalog.build(runtimesJSON: runtimesJSON, devicesJSON: devicesJSON)
        } catch {
            throw SimulatorPoolError.simctlFailed(detail: "\(error)")
        }
    }

    private func runSimctlList(_ arguments: [String]) async throws -> Data {
        let result: ProcessResult
        do {
            result = try await runProcess(ToolPaths.xcrun, arguments, workingDirectory, timeoutSeconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SimulatorPoolError.simctlFailed(detail: "\(error)")
        }
        guard result.succeeded else {
            throw SimulatorPoolError.simctlFailed(
                detail: OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutput
    }
}
