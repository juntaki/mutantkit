import Darwin
import Foundation
@testable import MutationExecution

/// F3 zero-base review, Finding 3: reproduces "root forks a child, the
/// child announces ready and keeps the (inherited) output FD open, root
/// exits, the supervisor enters its post-exit drain, *then* the caller
/// cancels the Task" — a window the existing cancellation regression tests
/// (`ProcessSupervisorOwnershipTests.taskCancellationTearsDownOwnedTree`
/// and its stress sibling) do not cover: those cancel while `root` is
/// still alive and blocked, landing inside `wait(for:policy:)`'s own poll
/// loop, which already checks `cancellationFlag`. This fixture cancels
/// only *after* root has already exited, landing in `runBlocking`'s
/// post-exit drain wait (`drainGroup.wait(timeout:)`), which today has no
/// cancellation check at all.
///
/// Ordering is established with real facts, never a sleep guess:
/// 1. `rootPidPath` is written by `root` before it does anything else, so
///    the caller can identify it immediately.
/// 2. `readyPath` is written by `child` once it is alive and about to
///    block holding the inherited stdout/stderr pipe open — `root` blocks
///    on a pipe *read* for `child`'s own write, the same zero-slack
///    handshake `ProcessSupervisorOwnershipFixture.runFastParentExit`
///    already establishes, so `root` cannot exit before `child` is
///    genuinely alive and holding the pipe.
/// 3. The caller then polls `ProcessTree.isAlive(rootPid)` — not a fixed
///    delay — until it is `false`. Because `isAlive` uses `kill(pid, 0)`,
///    this only turns `false` once the *supervisor's own* `wait(for:policy:)`
///    poll loop has actually reaped `root` via its `waitpid(...,WNOHANG)`
///    call, which is the exact moment control returns to `runBlocking` and
///    the post-exit drain begins — a real fact about the supervisor's own
///    internal state transition, not a timing guess about it.
enum CancellationAfterRootExitFixture {
    struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    struct Started {
        let task: Task<ProcessResult, Error>
        let rootPID: pid_t
        let childPID: pid_t
    }

    /// Launches the scenario and blocks (via real-fact polling, not a
    /// sleep) until `root` has genuinely already exited and been reaped by
    /// the supervisor's own `wait(for:policy:)` — i.e., until the
    /// supervisor is provably inside (or about to enter) the post-exit
    /// drain wait. The caller is then free to cancel `task` to land
    /// exactly in that window.
    static func startAndWaitUntilRootHasExited(
        timeoutSeconds: Double = 60,
        terminationGracePeriodSeconds: Double = 1,
        rootDeathTimeoutSeconds: Double = 10
    ) throws -> Started {
        let rootPidPath = uniquePath("root-pid")
        let readyPath = uniquePath("child-ready")
        defer {
            try? FileManager.default.removeItem(atPath: rootPidPath)
            try? FileManager.default.removeItem(atPath: readyPath)
        }

        let script = """
        import os, sys, time
        root_pid_path = \(pythonLiteral(rootPidPath))
        ready_path = \(pythonLiteral(readyPath))
        with open(root_pid_path + ".tmp", "w") as f:
            f.write(str(os.getpid()))
        os.rename(root_pid_path + ".tmp", root_pid_path)
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            with open(ready_path + ".tmp", "w") as f:
                f.write(str(os.getpid()))
            os.rename(ready_path + ".tmp", ready_path)
            os.write(w, b"x")
            os.close(w)
            # Holds the *inherited* stdout/stderr pipe open without ever
            # writing to or closing it -- root exiting alone must not let
            # the supervisor's drain reach EOF. Long enough that only a
            # real SIGTERM/SIGKILL from the supervisor can end it.
            time.sleep(120)
            os._exit(0)
        else:
            os.close(w)
            os.read(r, 1)
            os.close(r)
            sys.exit(0)
        """

        let task = Task<ProcessResult, Error> {
            try await ProcessSupervisor.run(
                executable: "/usr/bin/python3", arguments: ["-c", script],
                workingDirectory: FileManager.default.temporaryDirectory,
                timeoutSeconds: timeoutSeconds, terminationGracePeriodSeconds: terminationGracePeriodSeconds
            )
        }

        let rootPID = try waitForFile(at: rootPidPath, timeoutSeconds: 10)
        let childPID = try waitForFile(at: readyPath, timeoutSeconds: 10)

        // Real-fact polling: `ProcessTree.isAlive` (`kill(pid, 0)`) stays
        // true for a zombie regardless of whether it has been reaped, so
        // it cannot signal "root has exited" here -- F3's own production
        // fix (zero-base review Finding 2) deliberately defers the real,
        // consuming reap until *after* ownership close-out has already
        // run, so "reaped" no longer means "root just exited." `hasExited`
        // below peeks the same non-reaping way production's own
        // `ProcessSupervisor.hasExited` does (`waitid(..., WNOWAIT)`,
        // never consumed), so it turns `true` at the true moment root
        // exits, independent of whatever the supervisor does with that
        // fact afterward.
        let deadline = Date().addingTimeInterval(rootDeathTimeoutSeconds)
        while !hasExited(rootPID), Date() < deadline {
            usleep(500)
        }
        guard hasExited(rootPID) else {
            throw SetupFailure(description: "root (pid \(rootPID)) never exited within \(rootDeathTimeoutSeconds)s")
        }

        return Started(task: task, rootPID: rootPID, childPID: childPID)
    }

    /// Mirrors `ProcessSupervisor.hasExited` (a `private` production
    /// helper, inaccessible even via `@testable import`): a non-reaping
    /// peek at whether `pid` has exited, using `waitid(..., WNOWAIT)` so
    /// it never consumes the zombie itself and can safely be called
    /// alongside the supervisor's own repeated peeks of the same pid.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        info.si_pid = 0
        let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return rc == 0 && info.si_pid == pid
    }

    // MARK: - Support

    private static func uniquePath(_ label: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mkit-cancel-after-exit-\(label)-\(UUID().uuidString)").path
    }

    private static func waitForFile(at path: String, timeoutSeconds: Double) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            usleep(1000)
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw SetupFailure(description: "\(path) never appeared with a readable pid")
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
