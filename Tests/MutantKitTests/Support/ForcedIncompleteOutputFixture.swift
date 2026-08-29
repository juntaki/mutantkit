import Darwin
import Foundation
@testable import MutationExecution

/// Deterministically forces `ProcessSupervisor`'s bounded post-exit drain
/// wait to time out with output still incomplete — real evidence for
/// `ProcessResult.outputComplete`, not a hand-constructed fake value.
///
/// ## Why this needs real fd-passing, not just a slow/forked child
///
/// `ProcessSupervisor.wait(for:...)` already reaps (`ProcessTree.reap(_:)`,
/// unrelated and untouched here) every descendant it observed, the instant
/// the supervised process itself exits — including a background child that
/// forked off to hold a pipe open. That reaping is synchronous and happens
/// *before* the bounded drain wait even begins, so a plain
/// `subprocess.Popen(...)` descendant gets killed, its copy of the pipe's
/// write end closes with it, and the drain reaches EOF almost immediately
/// regardless of how long that descendant meant to sleep — which would make
/// the drain-timeout condition this fixture needs to force effectively
/// unreproducible without racing that reap, which is exactly the kind of
/// CI-timing flakiness the regression this fixture supports must not rely
/// on.
///
/// So the fd is instead handed, via `SCM_RIGHTS` over a Unix domain socket,
/// to a *second* process this fixture launches directly with
/// `Foundation.Process` — never as a descendant of the process
/// `ProcessSupervisor.run` below supervises, so `ProcessTree.descendantIdentities(of:)`
/// (an ancestry walk) never finds it, and `ProcessTree.reap(_:)` never signals
/// it. That holder process keeps its duplicate of the write end open for
/// `holderSleepSeconds` — comfortably longer than `ProcessSupervisor`'s own
/// 5-second bounded drain wait — while the supervised process itself exits
/// promptly and successfully. The result: a real, unmodified
/// `ProcessSupervisor.run` call whose exit is known and successful, and
/// whose `outputComplete` is `false` because the drain genuinely could not
/// reach EOF in time — the same shape as the real CI incident that
/// motivated this field (a non-zero `simctl uninstall` exit reaching its
/// caller with an empty detail, immediately contradicted by an identical,
/// fully-captured failure on the very next call).
///
/// Confirmed directly against a standalone Python reproduction (outside
/// this Swift test target) before being wired in here: a `select`-bounded
/// 5-second read against a pipe held open this way reliably observed no EOF
/// and a >5s elapsed time, on every trial.
enum ForcedIncompleteOutputFixture {
    struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs `/usr/bin/python3` through the real, unmodified
    /// `ProcessSupervisor.run`, forced into the `outputComplete == false`
    /// condition described above. `partialOutput` (written to the
    /// supervised process's stdout *before* it hands the fd away, so it is
    /// real bytes the drain does manage to capture) defaults to non-empty,
    /// mirroring "some real evidence was captured, but not provably all of
    /// it" — the exact shape that makes trusting a truncated capture
    /// dangerous.
    static func run(
        partialOutput: String = "partial-output-before-drain-timeout\n",
        timeoutSeconds: Double = 30,
        // Comfortably unbounded relative to `ProcessSupervisor`'s 5-second
        // drain grace period, not merely longer than it: an earlier version
        // of this fixture used 7s, which is only ~2s of margin over that
        // 5s deadline — a scheduling delay of that size in starting the
        // post-exit drain wait (plausible under real machine load) could let
        // the holder finish and close its fd copy before the deadline fires,
        // making the very condition this fixture exists to force
        // non-deterministic. 60s leaves the deadline no realistic way to be
        // outrun by scheduling jitter, and costs nothing in wall-clock time:
        // every caller's own assertions run once `ProcessSupervisor.run`
        // returns (bounded by its own 5s drain wait, not by this sleep), and
        // the `defer` below SIGKILLs the holder the moment the test is done
        // with it rather than letting it run out its sleep.
        holderSleepSeconds: Double = 60
    ) async throws -> ProcessResult {
        let workDirectory = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkit-fd-\(token).sock").path
        let readyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkit-fd-\(token).ready").path
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: readyPath)
        }

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", holderScript(socketPath: socketPath, readyPath: readyPath, sleepSeconds: holderSleepSeconds)]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            // The holder exits on its own after `holderSleepSeconds`, but
            // the assertions this fixture supports run well before that —
            // no reason to make every test wait out the full sleep just to
            // let the holder finish tidily on its own.
            if holder.isRunning { kill(holder.processIdentifier, SIGKILL) }
            BoundedProcessWait.wait(holder, timeoutSeconds: 10)
        }

        let readyDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            usleep(10000)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            throw SetupFailure(description: "the fd-holder process never became ready to receive the descriptor")
        }

        return try await ProcessSupervisor.run(
            executable: "/usr/bin/python3",
            arguments: ["-c", senderScript(socketPath: socketPath, partialOutput: partialOutput)],
            workingDirectory: workDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Binds a `SOCK_DGRAM` Unix domain socket, signals readiness by
    /// creating `readyPath`, receives one file descriptor over `SCM_RIGHTS`,
    /// and holds it open for `sleepSeconds` before closing it and exiting.
    private static func holderScript(socketPath: String, readyPath: String, sleepSeconds: Double) -> String {
        """
        import array, os, socket, time
        sock_path = \(pythonLiteral(socketPath))
        ready_path = \(pythonLiteral(readyPath))
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(sock_path)
        open(ready_path, "w").close()
        _msg, ancdata, _flags, _addr = sock.recvmsg(1, socket.CMSG_SPACE(4))
        fds = array.array("i")
        for level, kind, data in ancdata:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds.frombytes(data[:4])
        received_fd = fds[0]
        time.sleep(\(sleepSeconds))
        os.close(received_fd)
        """
    }

    /// Writes `partialOutput` to its own stdout (the pipe `ProcessSupervisor`
    /// dup'd this process's fd 1 to), hands a duplicate of that same fd 1 to
    /// the holder over `socketPath`, then exits `0` immediately — a prompt,
    /// successful exit with the pipe's write end still held open elsewhere.
    private static func senderScript(socketPath: String, partialOutput: String) -> String {
        """
        import array, socket, sys
        sock_path = \(pythonLiteral(socketPath))
        sys.stdout.write(\(pythonLiteral(partialOutput)))
        sys.stdout.flush()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        fds = array.array("i", [1])
        client.sendmsg([b"x"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds.tobytes())], 0, sock_path)
        """
    }

    /// A Python source literal for `value` — every path/string this fixture
    /// embeds is one it generated itself (a `UUID`-suffixed temp path, or a
    /// caller-supplied `partialOutput`), but quoting properly rather than
    /// interpolating raw keeps this correct even if `partialOutput` ever
    /// contains a quote or backslash.
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
