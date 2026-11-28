import Darwin
import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let durationSeconds: Double
    /// True when the supervisor, not the process, decided the run was over —
    /// for *either* reason below. A caller that only needs "was this killed
    /// by us" (every caller before Gate 3 Phase H10) needs nothing else.
    public let timedOut: Bool
    /// Gate 3 Phase H10: `true` only when `timedOut` is `true` *and* the
    /// reason was `StallDetection` (no growth in `progressFilePath` for
    /// `stallTimeoutSeconds`), never the absolute `timeoutSeconds` deadline.
    /// Exists purely for accurate diagnosis text — "stalled at Ns" reads
    /// very differently from "exceeded its Ns limit" when N is the same
    /// number for both. Never consulted for verdict routing: a stalled kill
    /// is still `timedOut: true` like any other, and every existing
    /// `isBatchAttributedTimeout`/confirmation path already treats that
    /// uniformly, unaware this field even exists.
    public let stalled: Bool
    /// Set when the process died from a signal rather than exiting normally.
    public let terminatingSignal: Int32?
    /// `false` whenever the bounded post-exit drain wait (see `runBlocking`'s
    /// own `drainGroup.wait(timeout:)` call) did not confirm that *both*
    /// stdout and stderr had been fully read to EOF before this result was
    /// built — `true` otherwise. Genuine EOF (`read()` returning `0`) is
    /// tracked separately, per stream, from the drain loop merely exiting:
    /// a real `read()` error (`errno != EINTR`) breaks the same loop the
    /// same way EOF does, but proves nothing about whether the writer was
    /// actually done, so it must not be reported as `outputComplete == true`
    /// either — see `PipeDrain.reachedEOF`. This is a fact
    /// about *evidence*, orthogonal to `exitCode`/`timedOut`/
    /// `terminatingSignal`: a process can exit
    /// cleanly (even successfully) while something other than the process
    /// itself — a descendant that escaped reaping, a slow/contended drain
    /// thread — still holds a pipe open, in which case `standardOutput`/
    /// `standardError` may be truncated relative to what the process
    /// actually wrote. A caller that only checks `succeeded`/`exitCode`
    /// cannot tell "this failure reason is what the output says" apart from
    /// "the output might be missing the very evidence that would explain
    /// this failure" — which is exactly what let a real `simctl uninstall`
    /// failure reach a caller with an empty detail string on one real CI
    /// run, while the identical failing invocation immediately afterward
    /// captured the real "Invalid device: ..." text in full. Every consumer
    /// that derives a cache-identity fact or a failure classification from a
    /// `ProcessResult` must check this field and fail closed when it is
    /// `false`, never treat partial bytes as if they were the whole story.
    public let outputComplete: Bool
    /// `false` when close-out could not verify, after its group SIGKILL,
    /// that every tracked descendant and every other member of the root's
    /// process group was gone (the process table stayed unreadable, or a
    /// process was still running when the bounded re-check ran out). An
    /// escaped process may then outlive this observation and interfere with
    /// later ones anywhere in the run, so this is a run-level
    /// infrastructure failure, not a fact about this one process. Every
    /// consumer carries it forward explicitly (see
    /// `TestRunResult.cleanupVerified`); `ProcessSupervisor.run` also
    /// records it in the run's `RunContainmentMonitor`.
    public let cleanupVerified: Bool
    /// Why `cleanupVerified` is `false`; `nil` when it is `true`.
    public let cleanupDiagnosis: String?

    /// `false` when the root's exit status was never observed (the checked reap
    /// failed, or was handed to a detached thread). `exitCode` is then `-1`, a
    /// placeholder that must not be read as an exit; the reason is in
    /// `cleanupDiagnosis` and `cleanupVerified` is `false`.
    public let exitStatusAvailable: Bool

    public var succeeded: Bool { exitStatusAvailable && exitCode == 0 && !timedOut && terminatingSignal == nil }

    /// The one predicate for a caller that derives a fact from the captured
    /// bytes: the process succeeded *and* both streams are known to be
    /// complete. `succeeded` alone says nothing about truncated output.
    public var succeededWithCompleteOutput: Bool { succeeded && outputComplete }

    /// The exit status for a message or record: the real code, or the words
    /// "unavailable" when it was never observed (`exitCode` is then a `-1`
    /// placeholder that must not be shown or stored as an exit).
    public var exitStatusDescription: String { exitStatusAvailable ? "\(exitCode)" : "unavailable" }

    /// `cleanupVerified` has no default on purpose: a new call site must
    /// state it, so a wrapper cannot silently report success.
    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        durationSeconds: Double,
        timedOut: Bool,
        terminatingSignal: Int32?,
        stalled: Bool = false,
        outputComplete: Bool,
        cleanupVerified: Bool,
        cleanupDiagnosis: String? = nil,
        exitStatusAvailable: Bool = true
    ) {
        self.exitStatusAvailable = exitStatusAvailable
        self.cleanupVerified = cleanupVerified
        self.cleanupDiagnosis = cleanupDiagnosis
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.durationSeconds = durationSeconds
        self.timedOut = timedOut
        self.terminatingSignal = terminatingSignal
        self.stalled = stalled
        self.outputComplete = outputComplete
    }
}

/// Gate 3 Phase H10: an additional, additive kill condition layered
/// *underneath* `timeoutSeconds` — never a replacement for it. `timeoutSeconds`
/// remains the absolute ceiling on the whole process's lifetime regardless of
/// what it is doing; this instead asks "has *anything* written to
/// `progressFilePath` in the last `stallTimeoutSeconds`", independent of how
/// much of the overall `timeoutSeconds` budget remains. Deliberately generic:
/// `ProcessSupervisor` has no notion of `xcodebuild`, XCTest, or test
/// configurations at all — it only ever asks "did this file grow" — so a
/// caller reusing `xcodebuild`'s own `-resultStreamPath` (Gate 3 Phase H9's
/// finding: a live-appended NDJSON stream of `testStarted`/`testFinished`
/// events, structured, not console output to regex) turns "no test in this
/// batch has finished in N seconds" into "this file hasn't grown in N
/// seconds" without teaching this type anything about what the file means.
public struct StallDetection: Sendable {
    /// A file this process is expected to append to while it is making
    /// progress. Growth (byte count increasing since the last check) resets
    /// the stall clock; the file not existing yet, or not growing, does not
    /// — a process that has not started writing to it yet is not stalled
    /// *because of this*, but neither does an absent file count as progress.
    public let progressFilePath: URL
    /// How long `progressFilePath` may go without growing before this is
    /// treated as a stall and the process is killed the same way an absolute
    /// `timeoutSeconds` deadline already is — the same kill path, the same
    /// `timedOut: true` result, so a caller who receives it needs no new
    /// branch to handle "died to a stall" versus "died to the absolute
    /// deadline" differently. No heuristic invented here for what this value
    /// should be — the caller supplies it, exactly as it already supplies
    /// `timeoutSeconds`.
    public let stallTimeoutSeconds: Double
    /// How often to actually check the file's size — deliberately coarser
    /// than the descendant-tracking poll loop's own 1 ms baseline: a `stat`
    /// call on every 1 ms tick would add real, unnecessary syscall overhead
    /// to a loop already tuned tightly for a different purpose, and nothing
    /// about stall detection needs sub-second precision. Configurable only
    /// for tests, which need to observe a stall firing without waiting out
    /// a realistic `stallTimeoutSeconds`.
    let checkIntervalSeconds: Double

    public init(progressFilePath: URL, stallTimeoutSeconds: Double, checkIntervalSeconds: Double = 0.5) {
        self.progressFilePath = progressFilePath
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.checkIntervalSeconds = checkIntervalSeconds
    }
}

public enum ProcessSupervisorError: Error, CustomStringConvertible {
    case spawnFailed(executable: String, errno: Int32)
    /// A required launch-setup step (pipe, descriptor flag, file action,
    /// spawn attribute) failed; no child was started.
    case spawnSetupFailed(operation: String, errno: Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(executable, code):
            "Could not launch \(executable): \(String(cString: strerror(code))) (errno \(code))"
        case let .spawnSetupFailed(operation, code):
            "Launch setup failed in \(operation): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// Launches and supervises child processes.
///
/// Two properties matter here, and neither is available from `Foundation.Process`:
///
/// 1. **The child leads its own process group.** A mutant that deletes a
///    `continuation.resume()` hangs forever, and killing only the `xcodebuild`
///    we spawned leaves the compilers, simulators and test runners beneath it
///    alive — they accumulate across a run until the machine dies. We spawn with
///    `POSIX_SPAWN_SETPGROUP` so the child becomes a group leader, which makes
///    `kill(-pgid)` reach every descendant that stays in the group. `Process`
///    gives the child *our* group, where the same call would kill the tool itself.
///
/// 2. **No shell, ever.** Arguments are passed as an array straight to
///    `posix_spawn`. Nothing is concatenated into a command string, so no source
///    path, scheme name or destination can be interpreted as shell syntax.
///
/// The timeout is ours, not the runner's. `xcodebuild` and `swift test` cannot be
/// relied on to bound their own runtime, and the design requires that this tool
/// always terminates.
///
/// ## Ownership contract (F3 zero-base review)
///
/// This type guarantees deterministic ownership and cleanup for:
///
/// - the supervised root process; and
/// - every process that remains within the supervisor-owned process group
///   (the group `POSIX_SPAWN_SETPGROUP` establishes at spawn time) through
///   `closeOutOwnedGroup`'s own close-out.
///
/// A descendant that independently leaves that process group — calls its
/// own `setsid()`/`setpgid()` — before this type has ever individually
/// observed it via `detectRootExit`'s continuous ancestry polling is
/// **outside** this guarantee. `swiftpm-testing-helper`, which actually
/// runs a mutant's tests, is exactly this shape: it moves itself into a
/// new process group on its own. Such an escaped descendant may still be
/// found and cleaned up — `ProcessTree`'s own continuous polling, paired
/// with the group signal, reaches it whenever the escape happened to be
/// observed at least once before the root exited — but that discovery is
/// **best-effort, not an invariant** of this unprivileged Darwin
/// implementation: no available macOS API (a `kqueue`/`EVFILT_PROC`
/// bounded spike found `NOTE_TRACK`/`NOTE_CHILD` — the one primitive that
/// could make this atomic — `ENOTSUP` on Darwin, and bare `NOTE_FORK`
/// carries no child-pid payload; Endpoint Security could, in principle,
/// but requires a restricted entitlement no ordinary CLI can assume) lets
/// this be closed for the case where the escape and the root's own exit
/// land in the same, arbitrarily narrow observation window. See
/// `Tests/MutantKitTests/Diagnostics
/// /ProcessSupervisorEscapedDescendantOwnershipBoundaryDiagnostic.swift`
/// for the deterministic proof of this exact boundary.
///
/// ## Remaining risks (F3 verdict-contamination audit)
///
/// Whether an escaped, undiscovered descendant surviving is *only* a
/// resource-cleanup limitation, or can also contaminate a *different*,
/// later mutation run's own evidence, was audited across every consumer
/// of a `ProcessSupervisor`-run result. Two real, reproducible instances
/// were found and fixed within F3, both in `MutationRunner`: a
/// `retestKilledMutants` confirmation retest reran directly in the
/// primary test's own sandbox, and `confirmTimeout`'s own internal
/// same-artifact retest reran directly in its confirming rebuild's own
/// sandbox. Both now retest in an independently-cloned workspace,
/// established before the run being confirmed ever started — see
/// `PreparedMutant.confirmationSandbox` and
/// `MutationConfirmationCoordinator.timeoutInnerConfirmKillIfNeeded`. Regression-tested
/// with real, group-escaped descendants continuously writing observable
/// state (`MutationRunnerConfirmKillWorkspaceIsolationTests`,
/// `MutationRunnerTimeoutConfirmationInnerRetestIsolationTests`).
///
/// One further path was probed and left unmitigated, as an **accepted,
/// unproven limitation — not a proven-safe one**: on Darwin, an
/// unobserved descendant may leave the supervisor-owned process group
/// before root exit and survive close-out. In incremental-build mode
/// (`MutationRunner.runIncrementalWorker`/`runIncrementalBuildWorkerSequential`/
/// `runPipelinedBuildWorker`), worker sandboxes are intentionally reused
/// across mutations; therefore such an escaped descendant could in
/// principle retain access to a reused workspace. No deterministic
/// cross-mutant verdict contamination was reproduced in F3, so automatic
/// sandbox poisoning/recreation is not implemented — doing so on an
/// unreproduced hypothesis would bake a large, unvalidated change into
/// incremental-build's own execution contract (worker sandboxes are
/// deliberately long-lived; the whole performance case for incremental
/// mode depends on that). If such contamination is reproduced, the
/// affected worker sandbox must no longer be considered reusable.
///
/// Trigger for reopening this — all three, together, actually
/// reproduced: an escaped process from mutant A, *plus* observable
/// write/read interference in mutant B's own reused workspace, *plus* a
/// resulting change to mutant B's build/test/classification evidence. An
/// escaped process existing on its own, with no shown effect on another
/// mutant's evidence, does not meet this bar.
public enum ProcessSupervisor {
    /// How long to keep reading a killed process's output before giving up on it.
    ///
    /// Only ever reached when something survived a SIGKILL — normally the pipes
    /// close the moment the writers die and the drain ends immediately.
    static let defaultDrainGracePeriodSeconds: Double = 5

    /// The descendant-tracking poll interval on an unloaded machine — see
    /// `wait(for:policy:)`'s own doc comment for
    /// the measurements behind this specific number.
    static let baselinePollIntervalMicroseconds: useconds_t = 1000
    /// The ceiling `wait(for:policy:)`'s adaptive
    /// backoff will not exceed, however slow `sysctl(KERN_PROC_ALL)` itself
    /// gets under load — still an order of magnitude tighter than the
    /// original design's 100 ms fixed throttle, so even a fully backed-off
    /// poll remains meaningfully better than the gap this feature exists to
    /// close, never literally unbounded.
    static let maxPollIntervalMicroseconds: useconds_t = 50000

    /// F3 zero-base review Finding 2: a test-only observation seam, never
    /// read by any production code path. Records the exact ordering of
    /// the events the PID-reuse safety contract depends on — every
    /// `-pid`/process-group signal must happen before the final, consuming
    /// reap that frees `pid` for the kernel to recycle — so a deterministic
    /// regression test can assert that ordering directly (see
    /// `ProcessSupervisorZeroBaseReviewFindingsTests`) instead of trying to
    /// force an actual PID-reuse collision, which no portable API can do on
    /// demand.
    ///
    /// Deliberately **not** process-global mutable state (an earlier
    /// version of this was a single `static var`, flagged in review:
    /// concurrent `ProcessSupervisor.run` invocations — real, ordinary
    /// usage, not a test-only edge case — would all have observed and
    /// mutated the same one hook, corrupting each other's event logs and
    /// introducing a genuine data race this codebase's own concurrency
    /// model has no other reason to need). Instead threaded through
    /// `SupervisionPolicy` below like every other per-invocation setting,
    /// via the `internal`-only `run(...)` overload beneath the public one
    /// — each invocation captures its own, independent hook closure (or
    /// `nil`, the overwhelming common case, costing one already-cheap
    /// optional-closure call per event site), so nothing here is shared
    /// across invocations at all.
    enum LifecycleEvent: Equatable {
        case groupSignal(pid: pid_t, signal: Int32)
        case finalReap(pid: pid_t)
    }

    /// F3: Swift Task cancellation must own-tree-teardown exactly like a
    /// timeout — never leave the underlying blocking thread to run out its
    /// own `timeoutSeconds` regardless of the calling Task's own fate. This
    /// blocking implementation has no cooperative suspension points of its
    /// own to check `Task.isCancelled` at, so `withTaskCancellationHandler`'s
    /// `onCancel` (which fires synchronously, from whatever thread requests
    /// cancellation, the instant it happens — including *before*
    /// `operation` ever starts, if the task was already cancelled) is the
    /// only way in: it flips this shared, lock-protected flag, which
    /// `wait(for:...)`'s own poll loop below checks every tick alongside its
    /// existing deadline check, breaking out into the *identical*
    /// TERM → grace → KILL escalation an absolute timeout already uses —
    /// one mechanism, two triggers, never two independently-maintained
    /// teardown paths (see this function's own doc comment). Once that
    /// teardown (and the same bounded, EOF-driven drain wait every other
    /// path already goes through) completes, `run` rethrows
    /// `CancellationError` rather than returning a `ProcessResult` at all —
    /// matching this codebase's own established convention
    /// (`SimulatorPool.attemptBoot`'s identical "a `CancellationError` is
    /// rethrown as-is, never folded into an ordinary result" rule) — so a
    /// caller's own `try await` naturally keeps propagating cancellation
    /// instead of receiving a `ProcessResult` that merely *looks* like an
    /// ordinary timeout.
    final class CancellationFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()

        func cancel() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double = 5,
        stallDetection: StallDetection? = nil
    ) async throws -> ProcessResult {
        try await run(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory,
            environment: environment, timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: terminationGracePeriodSeconds, stallDetection: stallDetection,
            lifecycleEventHook: nil
        )
    }

    /// The real implementation behind the public `run(...)` above —
    /// `internal`, not `private`, purely so a test can supply
    /// `lifecycleEventHook` (see its own doc comment) via `@testable
    /// import`; every ordinary caller goes through the public overload,
    /// which always passes `nil`.
    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double = 5,
        stallDetection: StallDetection? = nil,
        lifecycleEventHook: (@Sendable (LifecycleEvent) -> Void)?,
        drainGracePeriodSeconds: Double = defaultDrainGracePeriodSeconds,
        processTableReader: @escaping ProcessTree.TableReader = ProcessTree.readProcessTable,
        rootExitProbe: @escaping @Sendable (pid_t) -> Bool = { ProcessSupervisor.hasExited($0) },
        waitpid: @escaping WaitPID = { Darwin.waitpid($0, $1, $2) },
        launchFault: ProcessLaunch.Fault? = nil,
        maxCapturedBytes: Int = PipeDrain.defaultMaxBytes
    ) async throws -> ProcessResult {
        // Once the run has aborted on an unverified cleanup, nothing new is
        // built or tested, whichever path reaches this launch.
        try RunContainmentMonitor.refuseLaunchIfAborted()
        let cancellationFlag = CancellationFlag()
        // Read here, in the async context: the blocking thread below does
        // not inherit task-local values.
        let teardown = RunContainmentMonitor.teardownLaunchPermitted
        // Teardown (removing what the run created) produces no evidence, so an unverified cleanup there
        // cannot taint a result and must not retroactively abort a run whose report is already written.
        let monitor = teardown ? nil : RunContainmentMonitor.current
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    // A dedicated thread: the supervision loop blocks, and we must not
                    // occupy a cooperative-pool thread while a build runs for minutes.
                    let thread = Thread {
                        do {
                            // The gate above ran before this thread existed; another worker may have tripped the
                            // monitor since. Checked again at the spawn boundary.
                            if !teardown, let diagnosis = monitor?.abortDiagnosis {
                                throw RunAbortedError(diagnosis: diagnosis)
                            }
                            let result = try runBlocking(
                                executable: executable,
                                arguments: arguments,
                                workingDirectory: workingDirectory,
                                environment: environment,
                                policy: SupervisionPolicy(
                                    timeoutSeconds: timeoutSeconds,
                                    terminationGracePeriodSeconds: terminationGracePeriodSeconds,
                                    stallDetection: stallDetection,
                                    cancellationFlag: cancellationFlag,
                                    lifecycleEventHook: lifecycleEventHook,
                                    drainGracePeriodSeconds: drainGracePeriodSeconds,
                                    processTableReader: processTableReader,
                                    rootExitProbe: rootExitProbe,
                                    waitpid: waitpid,
                                    launchFault: launchFault,
                                    maxCapturedBytes: maxCapturedBytes
                                )
                            )
                            // Recorded before the cancellation check: an
                            // unverified cleanup taints the run even when
                            // the caller no longer wants this result.
                            if !result.cleanupVerified {
                                monitor?.recordUnverifiedCleanup(
                                    "\(executable): \(result.cleanupDiagnosis ?? "descendant cleanup could not be verified")"
                                )
                            }
                            if cancellationFlag.isCancelled {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(returning: result)
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    thread.stackSize = 512 * 1024
                    // `wait(for:...)`'s own doc comment already documents the one gap its
                    // polling design cannot fully close: a descendant forked and its
                    // parent exiting within the same single poll tick. That window is
                    // ~1 ms on an idle machine, but this thread has no scheduling
                    // priority over anything else by default -- under heavy contention
                    // (many concurrent test-spawned processes competing for very few
                    // cores, the exact shape of a GitHub Actions macOS runner under full
                    // Swift Testing parallelism), the OS scheduler can leave this thread
                    // waiting to run for far longer than 1 ms between iterations,
                    // stretching that documented gap wide enough to matter in practice
                    // (observed for real: `ProcessSupervisorResidueTests`'s
                    // process-group-escape scenario intermittently failing in CI even
                    // after the residue-check's own timing was independently hardened).
                    // `.userInteractive` asks the scheduler to run this loop promptly
                    // whenever it is runnable, the same signal used for anything whose
                    // job is to react within a tight latency budget -- it does not
                    // close the gap outright (no polling design can, short of a kernel
                    // event source), but it materially narrows it by keeping this
                    // thread's own scheduling latency out of the equation.
                    thread.qualityOfService = .userInteractive
                    thread.start()
                }
            },
            onCancel: {
                cancellationFlag.cancel()
            }
        )
    }

    // MARK: - Blocking implementation

    /// Bundles the supervision-policy parameters `runBlocking`/`wait` share
    /// — everything that governs *how long* to wait and *how* to notice the
    /// caller wants out, as opposed to *what* to run — into one value.
    /// Keeps `runBlocking`'s own parameter count from growing every time a
    /// new supervision trigger (like F3's `cancellationFlag`) is added
    /// alongside the pre-existing `timeoutSeconds`/
    /// `terminationGracePeriodSeconds`/`stallDetection`.
    struct SupervisionPolicy {
        let timeoutSeconds: Double
        let terminationGracePeriodSeconds: Double
        let stallDetection: StallDetection?
        let cancellationFlag: CancellationFlag
        /// See `LifecycleEvent`'s own doc comment — `nil` for every
        /// ordinary caller, a per-invocation closure only ever set by a
        /// test going through the `internal` `run(...)` overload.
        let lifecycleEventHook: (@Sendable (LifecycleEvent) -> Void)?
        /// How long to keep reading output after the process is gone; see `defaultDrainGracePeriodSeconds`.
        /// Only a test going through the `internal` `run(...)` overload shortens it.
        let drainGracePeriodSeconds: Double
        /// How close-out reads the process table — `ProcessTree
        /// .readProcessTable` for every ordinary caller; a test injects a
        /// reader that fails on demand (see `ProcessTree.TableReader`).
        let processTableReader: ProcessTree.TableReader
        /// Whether the root has exited, for close-out only. `hasExited` for
        /// every ordinary caller; a test injects a root that never exits.
        let rootExitProbe: @Sendable (pid_t) -> Bool
        /// The consuming reap; a test injects `EINTR`/`ECHILD`.
        let waitpid: WaitPID
        /// Fails a named launch-setup step in tests; `nil` in production.
        let launchFault: ProcessLaunch.Fault?
        /// Per-stream capture ceiling; output beyond it is discarded and the
        /// result reports `outputComplete == false`.
        let maxCapturedBytes: Int
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        policy: SupervisionPolicy
    ) throws -> ProcessResult {
        let launched = try ProcessLaunch.spawn(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory,
            environment: environment, fault: policy.launchFault
        )
        let pid = launched.pid
        let started = launched.started

        // Drain concurrently with waiting. A build easily exceeds the 64 KiB pipe
        // buffer, and a full pipe blocks the child — waiting first and reading
        // afterwards would deadlock on exactly the noisy builds we care about.
        let drainGroup = DispatchGroup()
        let outBox = PipeDrain(fd: launched.outputReadFD, maxBytes: policy.maxCapturedBytes, group: drainGroup)
        let errBox = PipeDrain(fd: launched.errorReadFD, maxBytes: policy.maxCapturedBytes, group: drainGroup)

        // F3 zero-base review, Findings 2 & 3: `detectRootExit` below only
        // ever *peeks* at whether `pid` has exited (`waitid(...,
        // WNOWAIT)`), never reaps it — `pid` is guaranteed to remain
        // reserved (not recyclable to an unrelated process, and in
        // particular not recyclable as an unrelated process-group leader,
        // since forming a new group requires `setpgid`'s pgid argument to
        // equal the creating process's own, still-occupied pid) for as
        // long as this function defers the real, consuming reap below.
        // Every `-pid`/process-group signal in this function — whichever
        // of the three paths below sends one — happens strictly before
        // that deferred reap, never after.
        var pollIntervalMicroseconds = baselinePollIntervalMicroseconds
        let detected = detectRootExit(for: pid, policy: policy, pollIntervalMicroseconds: &pollIntervalMicroseconds)
        var observed = detected.observed

        var drainOutcome: DispatchTimeoutResult = .timedOut
        if detected.rootExitedOnItsOwn {
            // Root exited before any deadline/cancellation/stall fired —
            // give the drain its own fair, bounded chance to reach EOF
            // *before* any signal is sent, exactly as F3 Phase 5 requires:
            // a same-group descendant that legitimately finishes writing
            // to the inherited pipe after confirming root has exited must
            // never be preempted by an eager kill (an earlier version of
            // this fix called `ProcessTree.reap(observed)` immediately on
            // detecting root's exit and reproduced exactly that flake —
            // `ProcessSupervisorOutputCompletenessTests
            // .descendantSentinelWrittenAfterRootExitIsCapturedComplete`
            // failed 1 of 3 runs). Unlike a single, uninterruptible
            // `drainGroup.wait(timeout:)` call, `waitForDrain` below polls
            // in short slices so a cancellation arriving mid-wait (F3
            // zero-base review Finding 3) breaks out immediately into
            // ownership close-out below, rather than silently waiting out
            // the rest of `drainGracePeriodSeconds` the way the previous
            // implementation measurably did (~5s, confirmed by
            // `ProcessSupervisorZeroBaseReviewFindingsTests
            // .cancellationAfterRootExitEscalatesPromptlyRatherThanWaitingOutTheDrain`).
            drainOutcome = waitForDrain(
                drainGroup, timeoutSeconds: policy.drainGracePeriodSeconds, cancellationFlag: policy.cancellationFlag
            )
        }

        // Ownership close-out: TERM -> bounded grace -> KILL if still
        // alive, on the original process group and every individually
        // tracked identity — unconditional, run every time, regardless of
        // `detected.rootExitedOnItsOwn` or of whether the drain above
        // already succeeded. For a same-group descendant that neither
        // writes to nor holds the monitored pipe at all (e.g. one that
        // redirects its own stdio elsewhere), the drain already reached
        // EOF with nothing left to interrupt, and this is a pure,
        // unconditional cleanup pass — proven directly by
        // `ProcessSupervisorResidueTests.promptExitReapsAChildInTheSameGroup`'s
        // own fixture, a hard `RED` the one time this was gated on the
        // drain's own outcome instead. Safe regardless of *when* it runs
        // relative to the drain above because `pid` has still not been
        // reaped either way — see this function's own comment above.
        let cleanup = closeOutOwnedGroup(pid: pid, observed: &observed, policy: policy, pollIntervalMicroseconds: &pollIntervalMicroseconds)

        // Only now — strictly after every signal above — does root's pid
        // become reusable.
        let exit = reapRoot(pid: pid, cleanup: cleanup, policy: policy)

        let timedOut = !detected.rootExitedOnItsOwn
        let stalled = detected.stalled

        // The drain did not already get (or did not survive) its own fair
        // chance above — either root never exited on its own (a real
        // timeout/cancellation while it was still running) or it did but
        // the wait above ran out. A short, bounded second check now that
        // ownership close-out has actually run is what lets the EOF a
        // forced KILL should now produce actually be observed; if nothing
        // reachable this way was actually holding the pipe (e.g.
        // `ForcedIncompleteOutputFixture`'s deliberately non-descendant,
        // group-escaped holder nothing here can ever reach), this second
        // wait still times out and `outputComplete` correctly stays
        // `false` below — a documented, deliberate F3 scope boundary (see
        // `ProcessSupervisorResidueTests
        // .promptExitReapsAChildThatEscapedItsProcessGroup`'s own doc
        // comment), not something this silently papers over.
        if drainOutcome != .success {
            drainOutcome = drainGroup.wait(timeout: .now() + 2)
        }
        // Reader ownership ends with this call: each reader stops within one
        // poll slice and closes its own descriptor, so a writer an escaped
        // process still holds cannot keep a descriptor, thread or buffer
        // alive past the result. Bytes are read only after they have stopped.
        outBox.stop()
        errBox.stop()
        let readersClosed = drainGroup.wait(timeout: .now() + 2) == .success

        var terminatingSignal: Int32?
        var exitCode: Int32 = -1
        var cleanupVerified = cleanup.verified
        var cleanupDiagnosis = cleanup.diagnosis
        switch exit {
        case let .exited(code):
            exitCode = code
        case let .signaled(signal):
            terminatingSignal = signal
            // Mirror the shell convention so a signalled process still reads as failure.
            exitCode = 128 + signal
        case let .unavailable(reason):
            cleanupVerified = false
            cleanupDiagnosis = [cleanupDiagnosis, "exit status of pid \(pid) unavailable: \(reason)"]
                .compactMap { $0 }.joined(separator: "; ")
        }
        if !readersClosed {
            cleanupVerified = false
            cleanupDiagnosis = [cleanupDiagnosis, "output readers for pid \(pid) did not release their descriptors"]
                .compactMap { $0 }.joined(separator: "; ")
        }

        return ProcessResult(
            exitCode: exitCode,
            standardOutput: outBox.value,
            standardError: errBox.value,
            durationSeconds: Date().timeIntervalSince(started),
            timedOut: timedOut,
            terminatingSignal: terminatingSignal, stalled: stalled,
            outputComplete: drainOutcome == .success && outBox.reachedEOF && errBox.reachedEOF
                && !outBox.truncated && !errBox.truncated,
            cleanupVerified: cleanupVerified, cleanupDiagnosis: cleanupDiagnosis,
            exitStatusAvailable: exit.shellExitCode != nil
        )
    }

    /// The three ways a single `read()` call on a drained pipe fd can end
    /// this stream's drain loop, classified from just the syscall's own
    /// return value and errno — split out from `drain`'s loop below purely
    /// so the exact EOF-vs-error distinction `ProcessResult.outputComplete`
    /// depends on can be pinned by a direct, timing-free, no-real-fd unit
    /// test (`ProcessSupervisorDrainClassificationTests`), rather than only
    /// inferred from `ForcedIncompleteOutputFixture`'s real-fd, real-timing
    /// integration test, which cannot force a genuine `read()` error at all
    /// (only a real EOF, which is the one outcome that was never in
    /// question).
    enum DrainReadOutcome: Equatable {
        /// More bytes arrived; the loop keeps reading.
        case data(Int)
        /// `read()` returned `0`: real EOF, every writer of this fd has
        /// closed it. The only outcome that proves the bytes read so far
        /// are the whole story.
        case eof
        /// `read()` was interrupted by a signal — retried, never treated as
        /// any kind of completion.
        case retry
        /// A genuine read error (`errno != EINTR`, rare on a real pipe, but
        /// real). The loop must stop, but this proves nothing about whether
        /// the writer was actually done — must never be reported the same
        /// way `.eof` is.
        case error
    }

    static func classify(readResult count: Int, errno currentErrno: Int32) -> DrainReadOutcome {
        if count > 0 { return .data(count) }
        if count == 0 { return .eof }
        return currentErrno == EINTR ? .retry : .error
    }
}

// Support types (`PipeDrain`, `CStringArray`) live in ProcessSupervisorSupport.swift.
