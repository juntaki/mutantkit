import Foundation
@testable import MutationExecution
import Testing

/// Gate 3 Phase H10: `ProcessSupervisor`'s stall watchdog — an additional
/// kill condition layered *underneath* the existing absolute `timeoutSeconds`
/// deadline, never a replacement for it. Real subprocesses throughout
/// (`/bin/sh -c`), the same discipline `ProcessSupervisorResidueTests` uses —
/// the mechanism under test is a real polling loop watching a real file's
/// real size on disk, not something a fake clock can stand in for.
@Suite("ProcessSupervisor: stall watchdog (Gate 3 Phase H10)", .subprocessExclusive)
struct ProcessSupervisorStallDetectionTests {
    private func progressFilePath(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-stall-\(label)-\(UUID().uuidString)")
    }

    // MARK: - Ordinary caller (stallDetection: nil, the default) is unaffected

    @Test("A caller that does not opt into stallDetection behaves exactly as before — no new parameter, no change")
    func ordinaryCallerWithoutStallDetectionIsUnaffected() async throws {
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "exit 0"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 5
        )
        #expect(result.succeeded)
        #expect(!result.timedOut)
    }

    // MARK: - Regular progress resets the stall timer

    @Test("A process that keeps writing to its progress file never stalls, even though it runs longer than stallTimeoutSeconds")
    func regularProgressResetsTheTimer() async throws {
        let path = progressFilePath("regular-progress")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: path) }

        // Appends every 0.1s for 30 iterations (~3s total) — each append is
        // real progress. stallTimeoutSeconds (1.5s) is half the total
        // runtime, so this only stays alive if progress genuinely keeps
        // resetting the stall clock, not merely because the absolute
        // timeout (20s) hasn't been reached yet.
        //
        // The gap between one append and the next (0.1s) is deliberately
        // 15x under the stall timeout. It was 0.3s against the same 0.1s
        // interval — a 3x margin — and that flaked for real on a public CI
        // runner: `sleep 0.1` in a shell only bounds how long the process
        // sleeps, not how long until it is scheduled again, and on a
        // 3-vCPU runner saturated by this target's ~2400 other, fully
        // concurrent tests, a single gap stretching past 0.3s is ordinary.
        // The watchdog then fired correctly, the process came back
        // SIGTERM'd (exit 143, stalled), and the test read that as a
        // product failure. `.subprocessExclusive` does not help here: it
        // serialises this suite against the other real-subprocess suites,
        // not against the rest of the target, which is where the load
        // actually comes from. Widening the margin is the fix that keeps
        // what the test proves intact — the alternative, relaxing the
        // assertion to accept a stall, would delete the proof entirely.
        let script = """
        for i in $(seq 1 30); do
            echo "progress $i" >> '\(path.path)'
            sleep 0.1
        done
        exit 0
        """
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 20,
            stallDetection: StallDetection(progressFilePath: path, stallTimeoutSeconds: 1.5, checkIntervalSeconds: 0.1)
        )
        #expect(result.succeeded, "diagnosis: exitCode=\(result.exitCode) timedOut=\(result.timedOut) signal=\(String(describing: result.terminatingSignal))")
        #expect(!result.timedOut)
    }

    // MARK: - Silence fires the stall, independent of the absolute timeout

    @Test("A process whose progress file never grows is killed by the stall watchdog, well before the absolute timeout")
    func silenceFiresTheStall() async throws {
        let path = progressFilePath("silence")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: path) }

        let started = Date()
        // timeoutSeconds (60s) is deliberately generous — if this test ever
        // takes anywhere near that long, the stall watchdog did not fire and
        // the absolute timeout caught it instead, which is not what this
        // test means to prove. Raised from 30 to 60 (and the assertion
        // below from 20 to 40, preserving the same ~2/3 margin) after a
        // real, repeated public-CI failure: a confirmed 3-vCPU runner, even
        // after both a cross-suite subprocess-exclusion fix and a CI-only
        // Swift Testing concurrency cap, still occasionally took ~24-25s
        // here under real load -- uncomfortably close to the old 30s
        // ceiling. Treat CI slowness as expected and tolerable by design,
        // not something to precisely engineer away.
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60,
            // Small on purpose — this test isolates stall *detection* speed
            // from termination *grace-period* timing (its own dedicated
            // test below), not the default 5s a caller who cares about the
            // grace period itself would use.
            terminationGracePeriodSeconds: 0.2,
            stallDetection: StallDetection(progressFilePath: path, stallTimeoutSeconds: 0.3, checkIntervalSeconds: 0.05)
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.timedOut)
        // Generous relative to the 0.3s stall/0.2s grace configured above —
        // the real property under test is "well under the 60s absolute
        // timeout", not sub-second precision, which real subprocess
        // scheduling/signal delivery cannot guarantee under full-suite
        // concurrent test execution or real CI contention.
        #expect(elapsed < 40, "expected the stall watchdog to fire well before the 60s absolute timeout, took \(elapsed)s")
    }

    @Test("A stall-killed result reports timedOut the same way an absolute-deadline kill does — no new status for callers to branch on")
    func stallKillReportsTheSameShapeAsAnAbsoluteTimeoutKill() async throws {
        let path = progressFilePath("same-shape")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: path) }

        let stalled = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60,
            terminationGracePeriodSeconds: 0.2,
            stallDetection: StallDetection(progressFilePath: path, stallTimeoutSeconds: 0.2, checkIntervalSeconds: 0.05)
        )
        let absoluteTimeout = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 0.2,
            terminationGracePeriodSeconds: 0.2
        )
        #expect(stalled.timedOut == absoluteTimeout.timedOut)
        #expect(!stalled.succeeded)
        #expect(!absoluteTimeout.succeeded)
    }

    // MARK: - The absolute timeout remains independent of a larger stallTimeoutSeconds

    @Test("A short absolute timeoutSeconds still fires on schedule even when stallTimeoutSeconds is much larger")
    func absoluteTimeoutRemainsIndependent() async throws {
        let path = progressFilePath("absolute-independent")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: path) }

        let started = Date()
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 0.3,
            terminationGracePeriodSeconds: 0.2,
            // Larger than timeoutSeconds — if this ever became the
            // controlling deadline instead of timeoutSeconds, this test
            // would run for ~100s instead of ~0.3s.
            stallDetection: StallDetection(progressFilePath: path, stallTimeoutSeconds: 100, checkIntervalSeconds: 0.05)
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.timedOut)
        // Generous for the same full-suite/real-CI-contention reason as
        // above — the property under test is "well under 100s", not
        // sub-second precision.
        #expect(elapsed < 40, "expected the absolute timeout (0.3s) to fire, not stallTimeoutSeconds (100s); took \(elapsed)s")
    }

    // MARK: - Termination grace period is unchanged for a stall-triggered kill

    @Test("A stalled process that ignores SIGTERM is still escalated to SIGKILL after the configured grace period")
    func stallKillEscalatesThroughTheSameGracePeriod() async throws {
        let path = progressFilePath("grace-period")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: path) }

        // Traps and ignores SIGTERM, so only SIGKILL (after the grace
        // period) can actually end it.
        let script = "trap '' TERM; sleep 30"
        let started = Date()
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60,
            terminationGracePeriodSeconds: 1,
            stallDetection: StallDetection(progressFilePath: path, stallTimeoutSeconds: 0.2, checkIntervalSeconds: 0.05)
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.timedOut)
        // ~0.2s to detect the stall + ~1s grace period before SIGKILL —
        // comfortably under the 60s absolute timeout, and long enough that
        // this could only have passed by actually waiting out the grace
        // period rather than killing immediately.
        #expect(elapsed >= 1, "expected the grace period to actually be waited out, took only \(elapsed)s")
        // Generous for the same full-suite/real-CI-contention reason as the
        // tests above.
        #expect(elapsed < 40, "expected escalation to SIGKILL well before the 60s absolute timeout, took \(elapsed)s")
    }
}
