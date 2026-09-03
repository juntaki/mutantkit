import Darwin
import Foundation
import MutationModel

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
    /// either — see `drain`'s own `DataBox.reachedEOF`. This is a fact
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

    public var succeeded: Bool { exitCode == 0 && !timedOut && terminatingSignal == nil }

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        durationSeconds: Double,
        timedOut: Bool,
        terminatingSignal: Int32?,
        stalled: Bool = false,
        outputComplete: Bool
    ) {
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
    case pipeCreationFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(executable, code):
            "Could not launch \(executable): \(String(cString: strerror(code))) (errno \(code))"
        case let .pipeCreationFailed(code):
            "Could not create a pipe: \(String(cString: strerror(code))) (errno \(code))"
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
    private static let drainGracePeriodSeconds: Double = 5

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
        lifecycleEventHook: (@Sendable (LifecycleEvent) -> Void)?
    ) async throws -> ProcessResult {
        let cancellationFlag = CancellationFlag()
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    // A dedicated thread: the supervision loop blocks, and we must not
                    // occupy a cooperative-pool thread while a build runs for minutes.
                    let thread = Thread {
                        do {
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
                                    lifecycleEventHook: lifecycleEventHook
                                )
                            )
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
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        policy: SupervisionPolicy
    ) throws -> ProcessResult {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw ProcessSupervisorError.pipeCreationFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ProcessSupervisorError.pipeCreationFailed(errno: errno)
        }
        // A real file-descriptor inheritance bug discovered while
        // investigating a public-CI hang (a `swift test` run of nothing
        // but fast unit tests stalling for 68+ minutes). A deterministic
        // regression test — `ProcessSupervisorFileDescriptorLeakTests`,
        // written before this fix specifically to pin down the boundary
        // below — proves that unrelated, concurrently-spawned execs
        // could inherit copies of this function's own raw pipe
        // descriptors. Subsequent CI evidence (the same hang recurring
        // on the exact commit containing this fix) showed this was not,
        // by itself, the root cause of the full-suite stall — that
        // investigation continued separately. The bug fixed here is
        // real and worth fixing regardless: `pipe(2)` does not set
        // close-on-exec, so *any*
        // concurrently-running `posix_spawn` on another thread — not just
        // this one's own — inherits copies of these fds into its own
        // child by default. A long-lived, completely unrelated process
        // spawned while this pipe is still open (the real window between
        // this line and this same function's own post-spawn
        // `close(outPipe[1])`/`close(errPipe[1])` below) can hold this
        // pipe's write end open for its own entire lifetime, blocking
        // `drain`'s own read loop long after the intended child has
        // already exited.
        //
        // This does NOT affect the intended child's own `dup2`'d
        // `STDOUT_FILENO`/`STDERR_FILENO` below: POSIX `dup2` always
        // clears close-on-exec on the *new* descriptor it creates,
        // regardless of the source descriptor's own flag, so the
        // dup'd copies the intended child actually uses as its real
        // stdout/stderr are never affected by marking the *original*
        // fd numbers here close-on-exec —
        // `ProcessSupervisorFileDescriptorLeakTests
        // .directChildsOwnStandardOutputStillWorksNormally` locks this in
        // explicitly. It also does not affect a supervised child's own
        // legitimate escape (forking a background grandchild that leaves
        // the process group): that grandchild inherits the child's own
        // *already-dup'd* fd 1/2 via a real `fork()`, which is a
        // completely different, unaffected descriptor from the ones
        // marked here — `ProcessSupervisorResidueTests`'s own escape/reap
        // tests continue to pass after this change.
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            let flags = fcntl(fd, F_GETFD)
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        // The child must not inherit the read ends: if it did, EOF would never
        // arrive on our side and the drain threads would hang forever.
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // POSIX_SPAWN_SETPGROUP with group 0 makes the child its own group
        // leader, so its pgid equals its pid. This is the entire basis for
        // being able to kill the whole subtree later.
        //
        // POSIX_SPAWN_SETSIGMASK / POSIX_SPAWN_SETSIGDEF, F3 zero-base
        // review: `posix_spawn` otherwise inherits the *calling thread's*
        // signal mask into the new process — and the dedicated `Thread`
        // `run(...)` spawns this blocking work onto has `SIGTERM` blocked
        // on *that thread* (confirmed directly: `pthread_sigmask` reports
        // it blocked there — apparently held blocked by this test binary's
        // own GCD/Swift-Testing signal-handling infrastructure on its own
        // worker threads, not something this codebase set deliberately,
        // and not necessarily true of every thread in the process). A
        // blocked signal is queued pending, never delivered, until the
        // receiving thread unblocks it — so every process this spawns, and
        // everything it in turn forks (inheriting the same mask), silently
        // never actually acted on a SIGTERM this code sent, no matter how
        // many times: only SIGKILL (which cannot be blocked) ever took
        // effect, which is exactly what made `closeOutOwnedGroup`'s
        // TERM-first escalation measurably indistinguishable from "wait
        // out the full grace period, then KILL" for *every* prompt-exit
        // descendant that needed it — a real, confirmed root cause, not a
        // hypothesis (a C-language reproduction outside Swift with an
        // unblocked mask reliably kills such a descendant; the identical
        // scenario run *inside* this test binary, mask uninspected, did
        // not, and matched exactly once this fix's own mask/disposition
        // reset was added — see
        // `ProcessSupervisorSpawnedProcessSignalStateTests` for the
        // regression this pins directly).
        //
        // Deliberately narrower than "start with an empty mask entirely":
        // only `SIGTERM` — the one signal this codebase's own escalation
        // contract (`TERM -> grace -> KILL`) depends on actually being
        // deliverable — is forced into a known-good state; every other
        // signal's mask bit is left exactly as the calling thread already
        // had it, so this does not silently change behavior this fix was
        // never asked to touch. `POSIX_SPAWN_SETSIGDEF` covers the other
        // half of the same hazard `SETSIGMASK` alone cannot: an *ignored*
        // (`SIG_IGN`, not merely blocked) `SIGTERM` disposition is also
        // inherited across `exec`, and a masked-but-not-ignored signal
        // becoming unmasked would still do nothing if its disposition was
        // `SIG_IGN` — resetting it to `SIG_DFL` here guarantees the
        // spawned process starts able to be terminated by `SIGTERM` the
        // ordinary way, independent of whatever this test binary's own
        // process-wide disposition happens to be for unrelated reasons.
        // The spawned program remains completely free to install its own
        // handler or re-block/re-ignore `SIGTERM` after it starts (Mode D,
        // `runIgnoringSIGTERM`, exercises exactly that) — grace-then-KILL
        // is what covers that case, unaffected by any of this.
        var spawnSignalMask = sigset_t()
        pthread_sigmask(0, nil, &spawnSignalMask)
        sigdelset(&spawnSignalMask, SIGTERM)
        var sigtermOnly = sigset_t()
        sigemptyset(&sigtermOnly); sigaddset(&sigtermOnly, SIGTERM)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setsigmask(&attributes, &spawnSignalMask)
        posix_spawnattr_setsigdefault(&attributes, &sigtermOnly)

        var pid: pid_t = 0
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })

        let started = Date()
        let spawnResult = withExtendedLifetime((argv, envp)) {
            posix_spawn(&pid, executable, &fileActions, &attributes, argv.pointers, envp.pointers)
        }

        // Our copies of the write ends must go now, for the same EOF reason.
        close(outPipe[1])
        close(errPipe[1])

        guard spawnResult == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessSupervisorError.spawnFailed(executable: executable, errno: spawnResult)
        }

        // Drain concurrently with waiting. A build easily exceeds the 64 KiB pipe
        // buffer, and a full pipe blocks the child — waiting first and reading
        // afterwards would deadlock on exactly the noisy builds we care about.
        let outBox = DataBox()
        let errBox = DataBox()
        let drainGroup = DispatchGroup()
        drain(outPipe[0], into: outBox, group: drainGroup)
        drain(errPipe[0], into: errBox, group: drainGroup)

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
                drainGroup, timeoutSeconds: drainGracePeriodSeconds, cancellationFlag: policy.cancellationFlag
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
        closeOutOwnedGroup(pid: pid, observed: &observed, policy: policy, pollIntervalMicroseconds: &pollIntervalMicroseconds)

        // Only now — strictly after every signal above — does root's pid
        // become reusable.
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        policy.lifecycleEventHook?(.finalReap(pid: pid))

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

        let terminatingSignal: Int32? = status & 0x7F == 0 ? nil : status & 0x7F
        // Mirror the shell convention so a signalled process still reads as failure.
        let exitCode: Int32 = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)

        return ProcessResult(
            exitCode: exitCode,
            standardOutput: outBox.value,
            standardError: errBox.value,
            durationSeconds: Date().timeIntervalSince(started),
            timedOut: timedOut,
            terminatingSignal: terminatingSignal,
            stalled: stalled,
            outputComplete: drainOutcome == .success && outBox.reachedEOF && errBox.reachedEOF
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

    private static func drain(_ fd: Int32, into box: DataBox, group: DispatchGroup) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            readLoop: while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                switch classify(readResult: count, errno: errno) {
                case .data:
                    box.append(Data(buffer[0 ..< count]))
                case .eof:
                    // See `DrainReadOutcome.eof`'s own doc comment: the only
                    // branch that proves the bytes above are the whole story.
                    box.markEOF()
                    break readLoop
                case .retry:
                    continue readLoop
                case .error:
                    // Not EOF — `reachedEOF` stays false and `outputComplete`
                    // must reflect that.
                    break readLoop
                }
            }
            close(fd)
        }
    }
}

// Support types (`DataBox`, `CStringArray`) live in ProcessSupervisorSupport.swift.
