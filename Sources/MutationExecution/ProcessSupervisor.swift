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
    /// built — `true` otherwise. This is a fact about *evidence*, orthogonal
    /// to `exitCode`/`timedOut`/`terminatingSignal`: a process can exit
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
        outputComplete: Bool = true
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
///    Necessary but not sufficient: a descendant may leave the group, and the one
///    that does is `swiftpm-testing-helper`, which runs the mutated tests. See
///    `wait(for:timeoutSeconds:gracePeriodSeconds:)` and `ProcessTree`.
///
/// 2. **No shell, ever.** Arguments are passed as an array straight to
///    `posix_spawn`. Nothing is concatenated into a command string, so no source
///    path, scheme name or destination can be interpreted as shell syntax.
///
/// The timeout is ours, not the runner's. `xcodebuild` and `swift test` cannot be
/// relied on to bound their own runtime, and the design requires that this tool
/// always terminates.
public enum ProcessSupervisor {
    /// How long to keep reading a killed process's output before giving up on it.
    ///
    /// Only ever reached when something survived a SIGKILL — normally the pipes
    /// close the moment the writers die and the drain ends immediately.
    private static let drainGracePeriodSeconds: Double = 5

    /// The descendant-tracking poll interval on an unloaded machine — see
    /// `wait(for:timeoutSeconds:gracePeriodSeconds:)`'s own doc comment for
    /// the measurements behind this specific number.
    private static let baselinePollIntervalMicroseconds: useconds_t = 1000
    /// The ceiling `wait(for:timeoutSeconds:gracePeriodSeconds:)`'s adaptive
    /// backoff will not exceed, however slow `sysctl(KERN_PROC_ALL)` itself
    /// gets under load — still an order of magnitude tighter than the
    /// original design's 100 ms fixed throttle, so even a fully backed-off
    /// poll remains meaningfully better than the gap this feature exists to
    /// close, never literally unbounded.
    private static let maxPollIntervalMicroseconds: useconds_t = 50000

    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double = 5,
        stallDetection: StallDetection? = nil
    ) async throws -> ProcessResult {
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
                        timeoutSeconds: timeoutSeconds,
                        terminationGracePeriodSeconds: terminationGracePeriodSeconds,
                        stallDetection: stallDetection
                    )
                    continuation.resume(returning: result)
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
    }

    // MARK: - Blocking implementation

    private static func runBlocking(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double,
        stallDetection: StallDetection? = nil
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

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

        let (status, timedOut, stalled) = wait(
            for: pid,
            timeoutSeconds: timeoutSeconds,
            gracePeriodSeconds: terminationGracePeriodSeconds,
            stallDetection: stallDetection
        )

        // Bounded, never `wait()`. The drain ends when every writer closes the
        // pipe, and a process that escaped the kill still holds one — so an
        // unbounded wait makes a single surviving grandchild hang the supervisor
        // permanently. That is the failure this type exists to prevent, so it must
        // not be reachable from inside it. Anything not drained by now is output
        // from a process that outlived a SIGKILL, and is not worth waiting on —
        // but whether that happened must never be discarded the way a bare
        // `_ = ...wait(...)` would: `.success` is the only outcome that proves
        // `outBox`/`errBox` below hold everything the process wrote: a
        // `.timedOut` outcome means some writer — the process itself or
        // something else still holding its pipe open — had not been drained to
        // EOF when this deadline passed, so whatever bytes were captured so far
        // must be treated as possibly truncated, not as the complete record.
        let drainOutcome = drainGroup.wait(timeout: .now() + drainGracePeriodSeconds)

        let exitCode: Int32
        var terminatingSignal: Int32?
        if status & 0x7F == 0 {
            exitCode = (status >> 8) & 0xFF
        } else {
            terminatingSignal = status & 0x7F
            // Mirror the shell convention so a signalled process still reads as failure.
            exitCode = 128 + (status & 0x7F)
        }

        return ProcessResult(
            exitCode: exitCode,
            standardOutput: outBox.value,
            standardError: errBox.value,
            durationSeconds: Date().timeIntervalSince(started),
            timedOut: timedOut,
            terminatingSignal: terminatingSignal,
            stalled: stalled,
            outputComplete: drainOutcome == .success
        )
    }

    /// Waits for the child, tracking its descendants continuously so any of
    /// them still running once the child itself is gone — whether it exited
    /// promptly on its own or had to be killed on a timeout — can be
    /// reclaimed either way, escalating SIGTERM → SIGKILL only for the
    /// child itself on a timeout.
    ///
    /// **Why continuous tracking, not a single snapshot.** The process group
    /// is the first defense but cannot be the only one: spawning the child as
    /// a group leader makes `kill(-pgid)` reach everything that stays in that
    /// group, and some things do not — SwiftPM's `swiftpm-testing-helper`
    /// puts *itself* into a new group, so the process actually running the
    /// mutated tests is unreachable that way. Measured: after killing the
    /// group of a mutant whose test loops forever, the helper survived with
    /// `PGID == PID` and `PPID == 1`, still burning half a core, and still
    /// holding the write end of our stdout pipe, so EOF never arrived and the
    /// supervisor itself blocked forever draining it. A *second*, independent
    /// gap sits beside that one: this same escape is reachable from a process
    /// that exits *promptly* too (a crash, not only a hang) — a snapshot
    /// taken only once, at the moment of a timeout, never fires at all on
    /// that path, so a descendant left behind by an otherwise-ordinary,
    /// on-time exit was previously never even looked for. Fixing that
    /// requires knowing the tree *before* the root is gone, since ancestry is
    /// the only proof a descendant is really ours, and it disappears the
    /// instant the root exits (reparented to launchd). **How fast that
    /// window closes was measured directly, not assumed, and the answer
    /// forced the polling interval below far tighter than the original
    /// `waitpid` loop's own 10 ms:** a script that forks a background child
    /// and then exits can complete that *entire* round trip — including a
    /// fresh `python3` interpreter's own startup — in under 10 ms often
    /// enough that 10 ms polling missed the descendant roughly 9 times out
    /// of 10 in repeated real trials; even 5 ms polling still missed it
    /// more often than not. 2 ms was the first interval that caught it
    /// reliably (10/10), so this polls at 1 ms — one safety margin below
    /// that measured threshold, not an arbitrarily "tight-sounding" number.
    /// This is not a throttle-vs-correctness judgment call left to
    /// intuition: an earlier version of this fix polled every 100 ms
    /// specifically to bound `sysctl(KERN_PROC_ALL)` overhead, reasoning
    /// that the *existing* 10 ms `waitpid` cadence already had "plenty of
    /// spare time" above it — measurement disproved that reasoning outright,
    /// not just the number chosen. The cost side was measured too, not just
    /// the correctness side: `sysctl(KERN_PROC_ALL)` on real hardware costs
    /// on the order of 0.1 ms per call, so 1 ms polling spends roughly a
    /// tenth of this function's own dedicated supervisor thread (already a
    /// separate `Thread`, never the cooperative pool) continuously polling
    /// — a real, bounded cost paid by one monitoring thread, not by the
    /// supervised build/test process itself, and not something that slows
    /// the actual work down on any machine with more than one core.
    /// Accumulating every identity `ProcessTree.descendantIdentities(of:)`
    /// observes across every poll (not just the latest snapshot) is what
    /// makes that ancestry proof available *after* the root is already
    /// gone: `ProcessTree.reap(_:)` re-verifies each one (PID *and*
    /// recorded start time, surviving PID reuse) against the live table
    /// before ever signalling it, so nothing here trades that safety away
    /// for the tighter window. The one gap this cannot close is a
    /// descendant spawned and the root exiting within the same ~1 ms tick —
    /// bounded, not eliminated, the same shape of limitation the original
    /// single-snapshot design already had (a descendant spawned between
    /// that snapshot and the kill call), just far smaller and covering the
    /// entire run now instead of a single instant.
    ///
    /// **Adaptive, not a fixed 1 ms forever.** Flagged in review: a fixed
    /// interval with no floor on the *cost* of a single poll has no circuit
    /// breaker if `sysctl(KERN_PROC_ALL)` itself becomes slow — a large
    /// process table under real system load, not the light table this
    /// interval was measured against. `pollDescendants` below times its own
    /// `descendantIdentities(of:)` call and backs the interval off
    /// (doubling, capped at `maxPollIntervalMicroseconds`) whenever a single
    /// poll's own cost meaningfully exceeds the current interval, and relaxes
    /// back toward the 1 ms baseline once polls are cheap again — so a
    /// contended machine degrades this loop's own overhead gracefully
    /// instead of hammering an already-slow `sysctl` at a fixed cadence
    /// regardless of what that cadence now actually costs.
    private static func wait(
        for pid: pid_t,
        timeoutSeconds: Double,
        gracePeriodSeconds: Double,
        stallDetection: StallDetection? = nil
    ) -> (status: Int32, timedOut: Bool, stalled: Bool) {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var observed: Set<ProcessTree.ProcessIdentity> = []
        var pollIntervalMicroseconds = baselinePollIntervalMicroseconds

        func pollDescendants() {
            let pollStarted = Date()
            observed.formUnion(ProcessTree.descendantIdentities(of: pid))
            let pollDurationMicroseconds = Date().timeIntervalSince(pollStarted) * 1_000_000
            if pollDurationMicroseconds > Double(pollIntervalMicroseconds) {
                pollIntervalMicroseconds = min(pollIntervalMicroseconds * 2, maxPollIntervalMicroseconds)
            } else if pollIntervalMicroseconds > baselinePollIntervalMicroseconds {
                pollIntervalMicroseconds = max(pollIntervalMicroseconds / 2, baselinePollIntervalMicroseconds)
            }
        }

        // Gate 3 Phase H10: tracks `stallDetection.progressFilePath`'s own
        // size — deliberately just a byte count, not any understanding of
        // what the file contains — resetting `lastProgressAt` whenever it
        // grows, checked no more often than `checkIntervalSeconds` so this
        // never adds meaningful overhead to the tight descendant-polling
        // loop above. `nil` `stallDetection` (every caller before this
        // phase, and every caller that does not opt in) makes this whole
        // block dead code — `lastStallCheckAt`/`lastProgressSize` never
        // read, `isStalled()` never called.
        func progressFileSize() -> Int64? {
            guard let stallDetection else { return nil }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: stallDetection.progressFilePath.path) else {
                return nil
            }
            return attributes[.size] as? Int64
        }

        var lastProgressSize = progressFileSize() ?? 0
        var lastProgressAt = Date()
        var lastStallCheckAt = Date()

        func isStalled() -> Bool {
            guard let stallDetection else { return false }
            let now = Date()
            guard now.timeIntervalSince(lastStallCheckAt) >= stallDetection.checkIntervalSeconds else { return false }
            lastStallCheckAt = now
            if let currentSize = progressFileSize(), currentSize > lastProgressSize {
                lastProgressSize = currentSize
                lastProgressAt = now
                return false
            }
            return now.timeIntervalSince(lastProgressAt) >= stallDetection.stallTimeoutSeconds
        }

        var stalledCause = false

        while true {
            pollDescendants()
            if waitpid(pid, &status, WNOHANG) == pid {
                // An on-time, non-timeout exit — the path a single
                // at-deadline snapshot could never reach at all.
                ProcessTree.reap(observed)
                return (status, false, false)
            }

            if Date() >= deadline { break }
            if isStalled() {
                stalledCause = true
                break
            }
            // 1 ms baseline, not the coarser granularity a build's own
            // timeout would suggest is "plenty" — see this function's own
            // doc comment for the measurements that ruled out every coarser
            // fixed interval tried, and for why this adapts upward under load.
            usleep(pollIntervalMicroseconds)
        }

        // Politely first, to the group and to anything that left it —
        // `reap(_:)` re-verifies provenance before this ever reaches a
        // stale/reused PID, so a SIGTERM is exactly as safe to send here as
        // the SIGKILL below.
        kill(-pid, SIGTERM)
        ProcessTree.signal(observed, SIGTERM)

        let graceDeadline = Date().addingTimeInterval(gracePeriodSeconds)
        while Date() < graceDeadline {
            pollDescendants()
            if waitpid(pid, &status, WNOHANG) == pid {
                // The process we launched is gone; its escapees need not be.
                ProcessTree.reap(observed)
                return (status, true, stalledCause)
            }
            usleep(pollIntervalMicroseconds)
        }

        kill(-pid, SIGKILL)
        ProcessTree.reap(observed)
        waitpid(pid, &status, 0)
        return (status, true, stalledCause)
    }

    private static func drain(_ fd: Int32, into box: DataBox, group: DispatchGroup) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    box.append(Data(buffer[0 ..< count]))
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            close(fd)
        }
    }
}

// MARK: - Support

/// Accumulates pipe output from a drain thread.
private final class DataBox: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Holds a NULL-terminated `char *[]` alive for the duration of a spawn.
///
/// The buffer is heap-allocated rather than bridged from a Swift `Array`:
/// taking a pointer to an array's storage yields one valid only for that
/// expression, and `posix_spawn` needs it to survive the whole call.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let capacity: Int

    init(_ strings: [String]) {
        capacity = strings.count + 1
        pointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: capacity)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[strings.count] = nil
    }

    deinit {
        for index in 0 ..< (capacity - 1) {
            free(pointers[index])
        }
        pointers.deallocate()
    }
}
