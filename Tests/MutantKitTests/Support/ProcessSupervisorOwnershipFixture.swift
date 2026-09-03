import Darwin
import Foundation
@testable import MutationExecution

/// Deterministic ownership-race fixtures for F3 (`ProcessSupervisor`
/// descendant ownership). Every scenario here synchronizes with real
/// process/file-descriptor state (a `readyPath` file a child creates the
/// moment it is alive and blocked, matching `ForcedIncompleteOutputFixture`'s
/// own established convention) — never a `sleep`/`usleep` guess at how long
/// a race "usually" takes. The one thing left genuinely non-deterministic on
/// purpose is exactly what F3 exists to characterize: whether
/// `ProcessSupervisor` actually owns a descendant that existed before its
/// root exited, regardless of how much (or little) wall-clock time elapsed
/// between the two.
enum ProcessSupervisorOwnershipFixture {
    struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    struct FastExitResult {
        let processResult: ProcessResult
        /// The descendant's PID, read back from `readyPath` — real process
        /// identity, not assumed from spawn order.
        let descendantPID: pid_t
        /// Set only by `runFastParentExitWithGrandchild` — `nil` for the
        /// plain child-only scenario.
        let grandchildPID: pid_t?
    }

    /// Mode A: `root` starts `child` and blocks on a **pipe read** (never a
    /// poll loop) for `child`'s own readiness signal — the tightest
    /// deterministic ordering achievable without a kernel event source: a
    /// blocking `read()` wakes the instant the writer's `write()` returns,
    /// with no polling-interval granularity on either side to pad the
    /// window between "child exists and is blocked" and "root proceeds to
    /// exit." `child` stays in `root`'s own process group (no
    /// `setsid`/`setpgid`), the ordinary, unescaped case, and blocks
    /// (`time.sleep`) long enough that it can only end via a real signal,
    /// never by outliving the fixture on its own.
    static func runFastParentExit(timeoutSeconds: Double = 30) async throws -> FastExitResult {
        let readyPath = uniquePath("ready")
        defer { try? FileManager.default.removeItem(atPath: readyPath) }

        let script = """
        import os, sys, time
        ready_path = \(pythonLiteral(readyPath))
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            with open(ready_path + ".tmp", "w") as f:
                f.write(str(os.getpid()))
            os.rename(ready_path + ".tmp", ready_path)
            os.write(w, b"x")
            os.close(w)
            time.sleep(300)
            os._exit(0)
        else:
            os.close(w)
            # Blocking read -- wakes the instant the child's write() lands,
            # no polling interval of root's own choosing to pad the window.
            os.read(r, 1)
            os.close(r)
            sys.exit(0)
        """

        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: timeoutSeconds
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw SetupFailure(description: "root did not exit promptly and successfully: \(result)")
        }
        let descendantPID = try readPID(at: readyPath)
        return FastExitResult(processResult: result, descendantPID: descendantPID, grandchildPID: nil)
    }

    /// Mode B: `root` -> `child` -> `grandchild`, all in the same process
    /// group. `root` blocks on the identical pipe-read handshake as
    /// `runFastParentExit`, this time waiting on the *grandchild's* own
    /// readiness signal (relayed through `child`), so both intermediate
    /// levels are guaranteed alive and blocked at the moment root exits.
    static func runFastParentExitWithGrandchild(timeoutSeconds: Double = 30) async throws -> FastExitResult {
        let childReadyPath = uniquePath("child-ready")
        let grandchildReadyPath = uniquePath("grandchild-ready")
        defer {
            try? FileManager.default.removeItem(atPath: childReadyPath)
            try? FileManager.default.removeItem(atPath: grandchildReadyPath)
        }

        let script = """
        import os, sys, time
        child_ready_path = \(pythonLiteral(childReadyPath))
        grandchild_ready_path = \(pythonLiteral(grandchildReadyPath))
        r, w = os.pipe()
        child_pid = os.fork()
        if child_pid == 0:
            os.close(r)
            gr, gw = os.pipe()
            grandchild_pid = os.fork()
            if grandchild_pid == 0:
                os.close(gr)
                with open(grandchild_ready_path + ".tmp", "w") as f:
                    f.write(str(os.getpid()))
                os.rename(grandchild_ready_path + ".tmp", grandchild_ready_path)
                os.write(gw, b"x")
                os.close(gw)
                time.sleep(300)
                os._exit(0)
            else:
                os.close(gw)
                os.read(gr, 1)
                os.close(gr)
                with open(child_ready_path + ".tmp", "w") as f:
                    f.write(str(os.getpid()))
                os.rename(child_ready_path + ".tmp", child_ready_path)
                os.write(w, b"x")
                os.close(w)
                os.waitpid(grandchild_pid, 0)
                os._exit(0)
        else:
            os.close(w)
            os.read(r, 1)
            os.close(r)
            sys.exit(0)
        """

        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: timeoutSeconds
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw SetupFailure(description: "root did not exit promptly and successfully: \(result)")
        }
        let childPID = try readPID(at: childReadyPath)
        let grandchildPID = try readPID(at: grandchildReadyPath)
        return FastExitResult(processResult: result, descendantPID: childPID, grandchildPID: grandchildPID)
    }

    /// Mode E: launches a process with the *same* executable/arguments
    /// shape `runFastParentExit`'s own descendant uses, but entirely
    /// outside anything `ProcessSupervisor` ever supervises — a real
    /// process this fixture's own cleanup (and any correct implementation)
    /// must never touch, regardless of how name/argument-similar it looks
    /// to a real supervised descendant. `release()` must be called by the
    /// test to terminate it; nothing here ever signals it automatically.
    static func spawnUnrelatedBystander() throws -> (pid: pid_t, release: () -> Void) {
        let readyPath = uniquePath("bystander-ready")
        let script = """
        import os, time
        ready_path = \(pythonLiteral(readyPath))
        with open(ready_path + ".tmp", "w") as f:
            f.write(str(os.getpid()))
        os.rename(ready_path + ".tmp", ready_path)
        time.sleep(300)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < deadline {
            usleep(1000)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            process.terminate()
            throw SetupFailure(description: "bystander process never became ready")
        }
        let pid = try readPID(at: readyPath)
        try? FileManager.default.removeItem(atPath: readyPath)

        return (pid, {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            BoundedProcessWait.wait(process, timeoutSeconds: 10)
        })
    }

    /// Mode D: a child that installs a real `SIGTERM` handler that does
    /// nothing (`signal.signal(signal.SIGTERM, lambda *_: None)`), so a
    /// polite termination attempt provably cannot end it — only escalation
    /// to `SIGKILL` after the grace period can. Announces readiness the
    /// same way every other fixture here does.
    static func runIgnoringSIGTERM(
        timeoutSeconds: Double, terminationGracePeriodSeconds: Double,
        lifecycleEventHook: (@Sendable (ProcessSupervisor.LifecycleEvent) -> Void)? = nil
    ) async throws -> FastExitResult {
        let readyPath = uniquePath("sigterm-ignoring-ready")
        defer { try? FileManager.default.removeItem(atPath: readyPath) }

        let script = """
        import os, signal, time
        signal.signal(signal.SIGTERM, lambda *_: None)
        ready_path = \(pythonLiteral(readyPath))
        with open(ready_path + ".tmp", "w") as f:
            f.write(str(os.getpid()))
        os.rename(ready_path + ".tmp", ready_path)
        while True:
            time.sleep(0.05)
        """

        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: timeoutSeconds, terminationGracePeriodSeconds: terminationGracePeriodSeconds,
            stallDetection: nil, lifecycleEventHook: lifecycleEventHook
        )
        let descendantPID = try readPID(at: readyPath)
        return FastExitResult(processResult: result, descendantPID: descendantPID, grandchildPID: nil)
    }

    /// Runs a long-lived root (blocks for `rootSleepSeconds`, well past any
    /// realistic test duration) that forks a child staying in the same
    /// process group, through the real `ProcessSupervisor.run`, inside a
    /// caller-cancellable `Task`. Returns the `Task` itself (still running)
    /// and `readyPath` — poll `readyPath` for the child's real PID before
    /// cancelling the task, exactly as every other fixture's own readiness
    /// handshake works, never a sleep guessing when the fork has happened.
    static func runLongRunningWithChild(rootSleepSeconds: Double = 300) -> (task: Task<ProcessResult, Error>, readyPath: String) {
        let readyPath = uniquePath("cancel-ready")
        let script = """
        import os, time
        ready_path = \(pythonLiteral(readyPath))
        pid = os.fork()
        if pid == 0:
            with open(ready_path + ".tmp", "w") as f:
                f.write(str(os.getpid()))
            os.rename(ready_path + ".tmp", ready_path)
            time.sleep(\(rootSleepSeconds))
            os._exit(0)
        else:
            time.sleep(\(rootSleepSeconds))
        """
        let task = Task<ProcessResult, Error> {
            try await ProcessSupervisor.run(
                executable: "/usr/bin/python3", arguments: ["-c", script],
                workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: rootSleepSeconds
            )
        }
        return (task, readyPath)
    }

    /// Polls `path` for existence, bounded by `timeoutSeconds` — a real
    /// readiness handshake (the file only exists once a real process wrote
    /// it), not a guess at how long forking "usually" takes.
    static func waitForReadyFile(at path: String, timeoutSeconds: Double = 10) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            usleep(1000)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw SetupFailure(description: "\(path) never appeared")
        }
        return try readPID(at: path)
    }

    // MARK: - Support

    private static func uniquePath(_ label: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mkit-ownership-\(label)-\(UUID().uuidString)").path
    }

    private static func readPID(at path: String) throws -> pid_t {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw SetupFailure(description: "could not read a PID from \(path)")
        }
        return pid
    }

    private static func pythonLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
