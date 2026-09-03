import Darwin
import Foundation
@testable import MutationExecution

/// F3 Phase 5, the positive counterpart to `ForcedIncompleteOutputFixture`:
/// a same-process-group descendant that survives its root's prompt exit,
/// genuinely finishes writing to the (inherited) output pipe, then closes
/// it and exits on its own — root exiting must never, by itself, truncate
/// this legitimate case.
///
/// The child confirms the root has actually exited before writing, via a
/// real kernel-observable fact (`getppid()` changing once the kernel
/// reparents it — never a sleep guessing how long that "usually" takes),
/// polled the same bounded way `ProcessSupervisorOwnershipFixture
/// .waitForReadyFile` already does elsewhere in this suite.
enum DescendantSentinelAfterRootExitFixture {
    struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    static let sentinel = "AFTER_ROOT_EXIT"

    static func run(timeoutSeconds: Double = 30) async throws -> ProcessResult {
        let readyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkit-sentinel-ready-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: readyPath) }

        let script = """
        import os, sys, time
        ready_path = \(pythonLiteral(readyPath))
        root_pid = os.getpid()
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            with open(ready_path + ".tmp", "w") as f:
                f.write(str(os.getpid()))
            os.rename(ready_path + ".tmp", ready_path)
            os.write(w, b"x")
            os.close(w)
            # Bounded poll on a real kernel fact (reparenting to launchd
            # happens the instant root actually exits) -- not a sleep
            # guessing at a duration.
            deadline = time.time() + 10
            while os.getppid() == root_pid and time.time() < deadline:
                time.sleep(0.001)
            sys.stdout.write(\(pythonLiteral(sentinel + "\n")))
            sys.stdout.flush()
            os.close(1)
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
        return result
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
