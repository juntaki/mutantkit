import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// One external-process invocation to make — either tool, always run as a
/// plain subprocess (never linked in-process), so the harness measures
/// exactly what a real command-line user experiences.
public struct ToolInvocation: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]
    public let timeoutSeconds: Double

    public init(
        executableURL: URL, arguments: [String], workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeoutSeconds: Double
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ToolExecutionResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let wallSeconds: Double
    /// `true` when the process was killed by `ToolRunner` itself for
    /// exceeding `timeoutSeconds` — `exitCode` in that case reflects the
    /// forced termination, not a real tool-reported exit status, and
    /// `ResultNormalizer` must never interpret it as a genuine result.
    public let timedOut: Bool
    /// The root process ID, for a caller (`MeasurementCollector`) that
    /// wants to have sampled the process tree while this ran — `ToolRunner`
    /// itself does not sample resource usage; that is a distinct concern
    /// with its own type.
    public let processID: pid_t

    public init(exitCode: Int32, standardOutput: String, standardError: String, wallSeconds: Double, timedOut: Bool, processID: pid_t) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.wallSeconds = wallSeconds
        self.timedOut = timedOut
        self.processID = processID
    }
}

public enum ToolRunnerError: Error, CustomStringConvertible {
    case launchFailed(String)
    case pipeCreationFailed(errno: Int32)
    case spawnFailed(executable: String, errno: Int32)

    public var description: String {
        switch self {
        case let .launchFailed(reason): "could not launch the tool process: \(reason)"
        case let .pipeCreationFailed(errno): "could not create a pipe for the tool process (errno \(errno))"
        case let .spawnFailed(executable, errno): "posix_spawn of \(executable) failed (errno \(errno))"
        }
    }
}

/// Runs one external tool invocation to completion (or to its timeout),
/// capturing everything a benchmark measurement needs about how the
/// process itself behaved — exit code, output, wall time. Deliberately
/// ignorant of what the tool *means* by its output; `ResultNormalizer`
/// interprets `standardOutput`/report files, this type never does.
///
/// A real, unbounded public-CI hang (a `swift test` run of nothing but
/// fast unit tests sat for 68+ minutes with no completion, versus ~15-20s
/// locally) was root-caused to this file's own earlier implementation,
/// which spawned via `Foundation.Process` and waited for exit via
/// `Process.terminationHandler` + `withCheckedContinuation`, reading
/// output via the pipe's blocking `readDataToEndOfFile()`. All three are
/// real problems: `terminationHandler`'s completion notification is not
/// something this code controls or can independently bound (if it is
/// ever not invoked — an environment-dependent Foundation behavior on
/// some platforms/sandboxes, not merely theoretical — the continuation
/// never resumes and the whole call hangs forever); a blocking pipe read
/// never returns until every holder of the pipe's write end closes it,
/// including any descendant a killed process left behind; and — found
/// while fixing the above — `Foundation.Process` also installs its own
/// internal reaping for the child the moment it is running, which races
/// a caller's own independent `waitpid` polling for the same PID (each
/// consumes the exit status at most once; whichever loses the race sees
/// `ECHILD` forever). `ProcessSupervisor` (`Sources/MutationExecution/
/// ProcessSupervisor.swift`, MutantKit's own execution engine) avoids all
/// three by never using `Foundation.Process` to begin with: it spawns via
/// raw `posix_spawn`, waits via a `waitpid(pid, WNOHANG)` polling loop
/// against a hard deadline (never a completion callback, and never
/// racing an internal Foundation reaper, since there isn't one), and
/// drains each pipe on a background thread bounded by a grace period
/// (never a blocking pipe read). This file reimplements the same
/// `posix_spawn`-based approach directly (not by depending on
/// `ProcessSupervisor`, per this type's own established decoupling from
/// MutantKit's execution engine) rather than the weaker approach that
/// caused the CI hang.
public struct ToolRunner: Sendable {
    public init() {}

    /// While the process runs, `onProcessStarted` is invoked once with its
    /// PID — the hook `MeasurementCollector` uses to start sampling the
    /// process tree concurrently, since RSS/CPU time cannot be recovered
    /// after a process has already exited. Called back on an arbitrary
    /// background thread, same as `ProcessSupervisor`'s own equivalent
    /// hook.
    public func run(
        _ invocation: ToolInvocation, onProcessStarted: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> ToolExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            // A dedicated thread, not the cooperative pool: the
            // supervision loop below blocks (deliberately — `usleep`
            // polling, not `Task.sleep`, is what makes the final
            // `waitpid(pid, &status, 0)` after `SIGKILL` safe to call
            // synchronously), and a slow/misbehaving tool can hold this
            // for its own full `timeoutSeconds`. Mirrors
            // `ProcessSupervisor.run`'s own identical pattern.
            let thread = Thread {
                do {
                    let result = try Self.runBlocking(invocation, onProcessStarted: onProcessStarted)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: - Blocking implementation (runs on its own dedicated thread only)

    private static func runBlocking(
        _ invocation: ToolInvocation, onProcessStarted: (@Sendable (pid_t) -> Void)?
    ) throws -> ToolExecutionResult {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw ToolRunnerError.pipeCreationFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ToolRunnerError.pipeCreationFailed(errno: errno)
        }
        // A real, reproducible bug found while fixing the CI hang this
        // whole rewrite exists to remove: `pipe(2)` does not set
        // close-on-exec, so *every* concurrently-running `posix_spawn`
        // call on any thread of this process — not just this one's own —
        // inherits copies of these fds into its own child by default.
        // Under `swift test`'s own parallel test execution, a second
        // test's short-lived child (e.g. `echo hello`) can end up holding
        // an inherited copy of *this* invocation's write end open for as
        // long as that unrelated child (or, worse, a slow/hung one) stays
        // alive — and this function's own `read(2)` drain loop below
        // cannot see EOF until every such copy, including ones it has no
        // way to know exist, is closed. Marking all four fds
        // close-on-exec here means only `posix_spawn`'s own explicit
        // `adddup2` targets (below) survive into this specific child;
        // every other, concurrently-spawned child closes its inherited
        // copies automatically at `exec()`, before this function ever
        // starts waiting on them. Confirmed by reproducing the exact
        // symptom locally: three `ToolRunnerTests` running concurrently
        // (one spawning a real 30-second `/bin/sleep`) made the other
        // two's own near-instant `echo`/`exit` children's output drain
        // block for the sleep process's own full lifetime, before this
        // fix.
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            let flags = fcntl(fd, F_GETFD)
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        // The child must not inherit the read ends: if it did, EOF would
        // never arrive on our side and the drain threads would hang forever.
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addchdir_np(&fileActions, invocation.workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // POSIX_SPAWN_SETPGROUP with group 0 makes the child its own group
        // leader, so its pgid equals its pid — the entire basis for being
        // able to kill a well-behaved tool's own child processes too on
        // timeout, exactly as `ProcessSupervisor` does for MutantKit's own
        // isolated-mode execution.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let executable = invocation.executableURL.path
        let argv = CStringArray([executable] + invocation.arguments)
        let envp = CStringArray(invocation.environment.map { "\($0.key)=\($0.value)" })

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
            throw ToolRunnerError.spawnFailed(executable: executable, errno: spawnResult)
        }
        onProcessStarted?(pid)

        // Draining starts immediately, concurrently with the wait below —
        // not after it — since a chatty tool can otherwise fill its pipe's
        // kernel buffer and block on its own write() call, which would
        // make the wait for exit hang on a tool that is not actually
        // stuck, just waiting on a full pipe nobody is reading yet.
        let outBox = DrainBox()
        let errBox = DrainBox()
        let drainGroup = DispatchGroup()
        drain(outPipe[0], into: outBox, group: drainGroup)
        drain(errPipe[0], into: errBox, group: drainGroup)

        let (status, timedOut) = waitWithTimeout(pid: pid, timeoutSeconds: invocation.timeoutSeconds)

        // Bounded, never an unbounded wait — the drain ends when every
        // writer closes the pipe, and a process that escaped the kill
        // still holds one, so waiting on it forever makes a single
        // surviving grandchild hang this function permanently (the exact
        // failure class this whole rewrite exists to remove). Anything
        // not drained by now is output from a process that outlived a
        // SIGKILL, and is not worth waiting on.
        _ = drainGroup.wait(timeout: .now() + 5)

        let exitCode: Int32
        if status & 0x7F == 0 {
            exitCode = (status >> 8) & 0xFF
        } else {
            // Mirror the shell convention so a signalled process still reads as failure.
            exitCode = 128 + (status & 0x7F)
        }

        return ToolExecutionResult(
            exitCode: exitCode,
            standardOutput: String(decoding: outBox.value, as: UTF8.self),
            standardError: String(decoding: errBox.value, as: UTF8.self),
            wallSeconds: Date().timeIntervalSince(started),
            timedOut: timedOut,
            processID: pid
        )
    }

    /// Races the process's own termination against a timeout, purely via
    /// a `waitpid(pid, WNOHANG)` polling loop against real deadlines. This
    /// is only safe because this file spawns via raw `posix_spawn`, never
    /// `Foundation.Process` — a `waitpid` call racing `Process`'s own
    /// internal reaping for the same PID is exactly the second bug this
    /// file's own doc comment describes; with no such internal reaper to
    /// race, this loop is this code's only, authoritative source of truth
    /// about whether the child has exited. On timeout, `SIGTERM` to the
    /// whole process group first (letting a well-behaved tool clean up
    /// its own child processes), then `SIGKILL` after a short grace
    /// period if it is still alive — the same two-stage discipline
    /// `ProcessSupervisor` uses. The final, blocking `waitpid` after
    /// `SIGKILL` is safe — unlike an unbounded wait anywhere else in this
    /// function — because `SIGKILL` cannot be caught, blocked, or
    /// ignored, so the kernel guarantees this call returns. Blocking
    /// (`usleep`, not `Task.sleep`) because this only ever runs on the
    /// dedicated thread `run(_:onProcessStarted:)` spins up for exactly
    /// this purpose, never the cooperative pool.
    private static func waitWithTimeout(pid: pid_t, timeoutSeconds: Double) -> (status: Int32, timedOut: Bool) {
        var status: Int32 = 0
        let pollIntervalMicroseconds: UInt32 = 5000 // 5 ms

        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0))
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return (status, false) }
            usleep(pollIntervalMicroseconds)
        }

        Foundation.kill(-pid, SIGTERM)
        let graceDeadline = Date().addingTimeInterval(5)
        while Date() < graceDeadline {
            if waitpid(pid, &status, WNOHANG) == pid { return (status, true) }
            usleep(pollIntervalMicroseconds)
        }

        Foundation.kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
        return (status, true)
    }

    /// Reads a pipe's file descriptor to EOF on a background thread,
    /// exactly as `ProcessSupervisor`'s own equivalent drain does — a
    /// direct `read(2)` loop, not `FileHandle.readDataToEndOfFile()`,
    /// whose blocking call this function's own caller bounds with
    /// `DispatchGroup.wait(timeout:)` rather than waiting on it forever.
    private static func drain(_ fd: Int32, into box: DrainBox, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
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

/// Accumulates pipe output from a drain thread — the same role
/// `ProcessSupervisor`'s own private `DataBox` plays, reimplemented here
/// rather than shared, per this type's own decoupling from MutantKit's
/// execution engine.
private final class DrainBox: @unchecked Sendable {
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

/// Holds a NULL-terminated `char *[]` alive for the duration of a spawn —
/// the same role `ProcessSupervisor`'s own private `CStringArray` plays,
/// reimplemented here rather than shared, per this type's own decoupling
/// from MutantKit's execution engine. Heap-allocated rather than bridged
/// from a Swift `Array`: taking a pointer to an array's storage yields
/// one valid only for that expression, and `posix_spawn` needs it to
/// survive the whole call.
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
