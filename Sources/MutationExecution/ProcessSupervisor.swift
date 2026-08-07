import Darwin
import Foundation
import MutationModel

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let durationSeconds: Double
    /// True when the supervisor, not the process, decided the run was over.
    public let timedOut: Bool
    /// Set when the process died from a signal rather than exiting normally.
    public let terminatingSignal: Int32?

    public var succeeded: Bool { exitCode == 0 && !timedOut && terminatingSignal == nil }

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        durationSeconds: Double,
        timedOut: Bool,
        terminatingSignal: Int32?
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.durationSeconds = durationSeconds
        self.timedOut = timedOut
        self.terminatingSignal = terminatingSignal
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

    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double = 5
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
                        terminationGracePeriodSeconds: terminationGracePeriodSeconds
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 512 * 1024
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
        terminationGracePeriodSeconds: Double
    ) throws -> ProcessResult {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw ProcessSupervisorError.pipeCreationFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ProcessSupervisorError.pipeCreationFailed(errno: errno)
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

        let (status, timedOut) = wait(
            for: pid,
            timeoutSeconds: timeoutSeconds,
            gracePeriodSeconds: terminationGracePeriodSeconds
        )

        // Bounded, never `wait()`. The drain ends when every writer closes the
        // pipe, and a process that escaped the kill still holds one — so an
        // unbounded wait makes a single surviving grandchild hang the supervisor
        // permanently. That is the failure this type exists to prevent, so it must
        // not be reachable from inside it. Anything not drained by now is output
        // from a process that outlived a SIGKILL, and is not worth waiting on.
        _ = drainGroup.wait(timeout: .now() + drainGracePeriodSeconds)

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
            terminatingSignal: terminatingSignal
        )
    }

    /// Waits for the child, escalating SIGTERM → SIGKILL on timeout.
    ///
    /// The process group is the first move but cannot be the only one. Spawning the
    /// child as a group leader makes `kill(-pgid)` reach everything that stays in
    /// that group — and some things do not. SwiftPM's `swiftpm-testing-helper`
    /// puts *itself* into a new group, so the process actually running the mutated
    /// tests is unreachable that way. Measured: after killing the group of a
    /// mutant whose test loops forever, the helper survived with `PGID == PID` and
    /// `PPID == 1`, still burning half a core. It also still held the write end of
    /// our stdout pipe, so EOF never arrived and the supervisor itself blocked
    /// forever draining it — one escaped grandchild was enough to hang the tool
    /// that exists to guarantee termination.
    ///
    /// So the descendants are enumerated first and killed by PID as well. The order
    /// matters: once the parent dies its children are reparented to launchd, and
    /// the ancestry that identifies them as ours is gone.
    private static func wait(
        for pid: pid_t,
        timeoutSeconds: Double,
        gracePeriodSeconds: Double
    ) -> (status: Int32, timedOut: Bool) {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while true {
            if waitpid(pid, &status, WNOHANG) == pid { return (status, false) }

            if Date() >= deadline { break }
            // 10 ms granularity is irrelevant against builds measured in seconds,
            // and polling avoids the signal-handler subtleties of the alternatives.
            usleep(10000)
        }

        // Snapshot the tree while the ancestry still exists.
        let descendants = ProcessTree.descendants(of: pid)

        // Politely first, to the group and to anything that left it.
        kill(-pid, SIGTERM)
        for descendant in descendants { kill(descendant, SIGTERM) }

        let graceDeadline = Date().addingTimeInterval(gracePeriodSeconds)
        while Date() < graceDeadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                // The process we launched is gone; its escapees need not be.
                ProcessTree.forceKill(descendants)
                return (status, true)
            }
            usleep(10000)
        }

        kill(-pid, SIGKILL)
        ProcessTree.forceKill(descendants)
        waitpid(pid, &status, 0)
        return (status, true)
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
