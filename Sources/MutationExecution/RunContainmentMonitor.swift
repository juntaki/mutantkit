import Foundation
import MutationModel

/// The run-level fail-closed abort for an unverified post-SIGKILL cleanup.
///
/// When close-out had to SIGKILL and could not then verify that every
/// tracked descendant was gone, a stray process may still be alive. Its
/// reach cannot be bounded to one chunk, mutant or worker: it can hold a
/// sandbox, a simulator, a port or a file that a later observation reads.
/// So the whole run stops. The observation that exposed it is never scored,
/// no later result is produced, and the run throws `RunAbortedError` instead
/// of returning a report. There is no isolated fallback, because the stray
/// may still exist and would contaminate that evidence too.
///
/// One monitor is shared by everything in a run. It is bound as a task
/// local by `withRunScope`, and nested scopes (the CLI command around the
/// hybrid engine around the schemata and fallback runners) reuse the outer
/// one. Two paths trip it:
/// - `ProcessSupervisor.run` records every `ProcessResult` whose
///   `cleanupVerified` is `false`, for every process launched inside the
///   scope, including helpers such as `xcresulttool` or `simctl` whose
///   results never become a `TestRunResult`.
/// - The runners record every `TestRunResult` whose `cleanupVerified` is
///   `false` (`observe(_:)`), which is the explicit propagation path
///   through each adapter.
///
/// Once it has tripped, `ProcessSupervisor.run` refuses every new launch
/// (except teardown, see `permittingTeardownLaunches`), and evidence the
/// run already persisted is discarded (see `onAbort`).
public final class RunContainmentMonitor: @unchecked Sendable {
    @TaskLocal public static var current: RunContainmentMonitor?

    private let lock = NSLock()
    private var firstDiagnosis: String?
    private var abortCleanups: [@Sendable () async -> Void] = []

    public init() {}

    /// The first unverified cleanup recorded in this run, or `nil`.
    public var abortDiagnosis: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstDiagnosis
    }

    public var isAborted: Bool { abortDiagnosis != nil }

    /// Records an unverified cleanup. The first diagnosis wins; later ones
    /// add nothing a reader needs to act on.
    public func recordUnverifiedCleanup(_ diagnosis: String) {
        lock.lock()
        if firstDiagnosis == nil { firstDiagnosis = diagnosis }
        lock.unlock()
    }

    /// Records `run` when its cleanup was not verified. Returns `true` when
    /// the run is (now) aborted, so a caller can stop before doing more
    /// work with the result.
    @discardableResult
    public func observe(_ run: TestRunResult) -> Bool {
        if !run.cleanupVerified {
            recordUnverifiedCleanup(run.cleanupDiagnosis ?? "a test run's descendant cleanup could not be verified")
        }
        return isAborted
    }

    /// Registers `cleanup` to run if this run aborts. It is for evidence
    /// the run has already persisted (checkpoint records, result-cache and
    /// coverage-cache entries). A worker can finish and persist a mutant
    /// while an uncontained process from another worker is still alive,
    /// before that process's close-out trips the monitor. Such evidence
    /// was gathered while containment was unproven. Leaving it on disk
    /// would let a resume, `--replay` or the next run score it.
    public func onAbort(_ cleanup: @escaping @Sendable () async -> Void) {
        lock.lock()
        abortCleanups.append(cleanup)
        lock.unlock()
    }

    /// Runs, once, every cleanup registered with `onAbort`. Called by
    /// `withRunScope` after `body` has finished, so no worker in the scope
    /// is still writing, and by a caller that must discard before it
    /// releases a lock.
    public func discardPersistedEvidence() async {
        let cleanups = lock.withLock {
            let pending = abortCleanups
            abortCleanups = []
            return pending
        }
        for cleanup in cleanups {
            await cleanup()
        }
    }

    public func throwIfAborted() throws {
        if let diagnosis = abortDiagnosis { throw RunAbortedError(diagnosis: diagnosis) }
    }

    /// `true` inside `permittingTeardownLaunches`.
    @TaskLocal static var teardownLaunchPermitted = false

    /// Runs `body` with `ProcessSupervisor.run` allowed to launch after the
    /// monitor has tripped. Only for teardown that removes what the run
    /// itself created, such as the simulators it cloned: it builds and tests
    /// nothing, and skipping it would leave that state behind.
    public static func permittingTeardownLaunches<T>(
        isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T
    ) async rethrows -> T {
        try await $teardownLaunchPermitted.withValue(true, operation: body, isolation: isolation)
    }

    /// Throws `RunAbortedError` when the bound monitor has tripped, unless
    /// the caller is inside `permittingTeardownLaunches`.
    /// `ProcessSupervisor.run` calls it before every launch.
    static func refuseLaunchIfAborted() throws {
        guard !teardownLaunchPermitted else { return }
        try current?.throwIfAborted()
    }

    /// Runs `body` with a monitor bound, reusing the one already bound by an
    /// enclosing scope. Throws `RunAbortedError` if the monitor tripped,
    /// even when `body` returned normally or threw something else: once
    /// containment is unproven nothing `body` produced is trustworthy. Before
    /// throwing, it discards what the run persisted (see `onAbort`).
    public static func withRunScope<T>(_ body: (RunContainmentMonitor) async throws -> T) async throws -> T {
        let monitor = current ?? RunContainmentMonitor()
        let outcome: Result<T, Error>
        do {
            outcome = try await .success($current.withValue(monitor) { try await body(monitor) })
        } catch {
            outcome = .failure(error)
        }
        if monitor.isAborted {
            await monitor.discardPersistedEvidence()
        }
        try monitor.throwIfAborted()
        return try outcome.get()
    }
}

extension RunContainmentMonitor {
    /// Registers the discard of everything `MutationRunner` persists
    /// through `checkpoints` and `resultCache`. `finalize` stops persisting
    /// once the monitor trips, but with more than one worker another mutant
    /// can be finalized while the uncontained process is still alive, before
    /// its close-out trips the monitor. On abort all of it is discarded, so
    /// no resume, `--replay` or later run can score it.
    func discardOnAbort(checkpoints: CheckpointStore?, resultCache: MutationResultCache?) {
        onAbort {
            await checkpoints?.discardRecordsFromThisSession()
            await resultCache?.discardEntriesStoredThisSession()
        }
    }
}

/// The run stopped because a process's descendant cleanup could not be
/// verified after SIGKILL. See `RunContainmentMonitor`.
public struct RunAbortedError: Error, CustomStringConvertible, Sendable {
    public let diagnosis: String

    public init(diagnosis: String) {
        self.diagnosis = diagnosis
    }

    public var description: String {
        """
        Run aborted: \(diagnosis). After a forced SIGKILL the tool could not verify that every descendant \
        process was gone, so a stray process may still be running and could affect any later result. No \
        mutant from this run is scored, no report was written, and the checkpoint records and cache entries this \
        run wrote were discarded. Check for leftover processes (for example `ps -axo pid,ppid,pgid,command`), \
        then rerun.
        """
    }
}
