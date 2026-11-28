import Darwin
import Foundation

/// A launched child and the read ends of its stdout/stderr pipes. The caller
/// owns the descriptors (hand them to `PipeDrain`).
struct LaunchedProcess {
    let pid: pid_t
    let outputReadFD: Int32
    let errorReadFD: Int32
    let started: Date
}

/// Checked launch: every pipe, descriptor flag, file action and spawn
/// attribute is verified, and a failure of any of them means no child is
/// started and nothing leaks. The error names the failing operation and its
/// errno.
enum ProcessLaunch {
    /// Simulates a failing setup operation in tests: given the operation name
    /// (`"pipe(stdout)"`, `"posix_spawn_file_actions_addchdir_np"`, ...),
    /// returns the errno to fail it with, or `nil` to run it for real. The
    /// second argument lists the descriptors the launch owns at that point, so
    /// a test can assert each one is closed after the failure.
    typealias Fault = @Sendable (_ operation: String, _ ownedDescriptors: [Int32]) -> Int32?

    static func spawn(
        executable: String, arguments: [String], workingDirectory: URL, environment: [String: String],
        fault: Fault? = nil
    ) throws -> LaunchedProcess {
        var owned: [Int32] = []
        var succeeded = false
        defer { if !succeeded { owned.forEach { close($0) } } }

        // Evaluates one setup call; `rc` is only run when no fault is injected.
        func check(_ operation: String, _ call: () -> Int32) throws {
            if let injected = fault?(operation, owned) {
                throw ProcessSupervisorError.spawnSetupFailed(operation: operation, errno: injected)
            }
            let rc = call()
            // posix_spawn* return the errno; fcntl/pipe return -1 and set it.
            if rc != 0 {
                throw ProcessSupervisorError.spawnSetupFailed(operation: operation, errno: rc == -1 ? errno : rc)
            }
        }

        func makePipe(_ name: String) throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            try check("pipe(\(name))") { pipe(&fds) }
            owned += fds
            return (fds[0], fds[1])
        }
        let out = try makePipe("stdout")
        let err = try makePipe("stderr")

        // `pipe(2)` does not set close-on-exec, so a concurrent `posix_spawn`
        // elsewhere in the process would inherit these ends and hold a write
        // end open long after the intended child is gone. `dup2` clears the
        // flag on the child's own stdout/stderr copies, so this does not
        // affect them.
        for (name, fd) in [("stdout.read", out.read), ("stdout.write", out.write), ("stderr.read", err.read), ("stderr.write", err.write)] {
            try check("fcntl(F_SETFD,\(name))") {
                let flags = fcntl(fd, F_GETFD)
                guard flags != -1 else { return -1 }
                return fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        try check("posix_spawn_file_actions_init") { posix_spawn_file_actions_init(&fileActions) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check("posix_spawn_file_actions_adddup2(stdout)") { posix_spawn_file_actions_adddup2(&fileActions, out.write, STDOUT_FILENO) }
        try check("posix_spawn_file_actions_adddup2(stderr)") { posix_spawn_file_actions_adddup2(&fileActions, err.write, STDERR_FILENO) }
        // The child must not hold the read ends: EOF would never arrive on our side.
        try check("posix_spawn_file_actions_addclose(stdout.read)") { posix_spawn_file_actions_addclose(&fileActions, out.read) }
        try check("posix_spawn_file_actions_addclose(stderr.read)") { posix_spawn_file_actions_addclose(&fileActions, err.read) }
        try check("posix_spawn_file_actions_addchdir_np") { posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path) }

        var attributes: posix_spawnattr_t?
        try check("posix_spawnattr_init") { posix_spawnattr_init(&attributes) }
        defer { posix_spawnattr_destroy(&attributes) }

        // The child leads its own process group (pgid == pid): the basis for
        // killing its whole subtree. SIGTERM is forced deliverable and
        // default-disposition because the supervising thread may have it
        // blocked, and a blocked/ignored SIGTERM is inherited across exec,
        // silently defeating the TERM -> grace -> KILL escalation
        // (see ProcessSupervisorSpawnedProcessSignalStateTests).
        var signalMask = sigset_t()
        try check("pthread_sigmask(query)") { pthread_sigmask(0, nil, &signalMask) }
        sigdelset(&signalMask, SIGTERM)
        var sigtermOnly = sigset_t()
        sigemptyset(&sigtermOnly)
        sigaddset(&sigtermOnly, SIGTERM)
        try check("posix_spawnattr_setflags") {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        }
        try check("posix_spawnattr_setpgroup") { posix_spawnattr_setpgroup(&attributes, 0) }
        try check("posix_spawnattr_setsigmask") { posix_spawnattr_setsigmask(&attributes, &signalMask) }
        try check("posix_spawnattr_setsigdefault") { posix_spawnattr_setsigdefault(&attributes, &sigtermOnly) }

        var pid: pid_t = 0
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let started = Date()
        let spawnResult: Int32 = if let injected = fault?("posix_spawn", owned) {
            injected
        } else {
            withExtendedLifetime((argv, envp)) {
                posix_spawn(&pid, executable, &fileActions, &attributes, argv.pointers, envp.pointers)
            }
        }
        // Our copies of the write ends go now, for the same EOF reason.
        close(out.write)
        close(err.write)
        owned.removeAll { $0 == out.write || $0 == err.write }
        guard spawnResult == 0 else {
            throw ProcessSupervisorError.spawnFailed(executable: executable, errno: spawnResult)
        }
        succeeded = true
        return LaunchedProcess(pid: pid, outputReadFD: out.read, errorReadFD: err.read, started: started)
    }
}
