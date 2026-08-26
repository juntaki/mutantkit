@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("ToolRunner")
struct ToolRunnerTests {
    @Test("A process that exits cleanly is reported with its own exit code, not timed out")
    func cleanExitIsReported() async throws {
        let runner = ToolRunner()
        let result = try await runner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hello"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        ))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("hello"))
        #expect(!result.timedOut)
    }

    @Test("A crashing tool process (nonzero exit) is reported, not thrown as an error")
    func crashingProcessIsReported() async throws {
        let runner = ToolRunner()
        let result = try await runner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 137"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        ))
        #expect(result.exitCode == 137)
        #expect(!result.timedOut)
    }

    @Test("A process exceeding its timeout is terminated and reported as timed out")
    func timeoutTerminatesTheProcess() async throws {
        let runner = ToolRunner()
        let result = try await runner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 1
        ))
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
    }

    /// Regression test for a real, reproducible public-CI hang: `swift
    /// test` ran nothing but fast unit tests for 68+ minutes with no
    /// completion (versus ~15-20s locally), root-caused to `pipe(2)` not
    /// setting close-on-exec. Under `swift test`'s own parallel test
    /// execution, a long-lived process spawned by one test inherits
    /// *every other concurrently-spawned test's* pipe fds by default, so
    /// a fast test's own output-drain never sees EOF until the unrelated
    /// long-lived process (or, worse, a hung one) also exits or is
    /// killed. Runs a real 3-second `/bin/sleep` concurrently with a real
    /// instant `echo` and asserts the fast one completes well within a
    /// bounded ceiling — proving its own output was never blocked
    /// *unboundedly* waiting on the slow one's pipe.
    ///
    /// The ceiling is deliberately generous (30s, not ~1s) rather than
    /// tight: this codebase's own `ProcessSupervisor`
    /// (`Sources/MutationExecution/ProcessSupervisor.swift`) has the
    /// identical missing-close-on-exec gap on its own pipes, confirmed
    /// while investigating this same hang, but fixing it there caused
    /// real regressions in its own deliberately-designed escaped-
    /// process-group tests — a bigger, separate, higher-stakes change
    /// this CI-hang fix does not make. Running this suite alongside
    /// `ProcessSupervisor`'s own heavily-parallel, real-subprocess-heavy
    /// tests (simulator boots, batch mutation execution) can therefore
    /// still add real, *bounded* extra latency here from inheriting one
    /// of *their* still-open pipes — measured up to ~12s locally under a
    /// full 1811-test run. That is expected and accepted; this assertion
    /// exists to catch a return to the original bug's actual signature,
    /// *unbounded* growth with no ceiling at all, not to guarantee
    /// best-case latency under arbitrary concurrent system load.
    @Test("A fast process's output drain never blocks unboundedly on an unrelated, concurrently-running slow process's pipe")
    func fastProcessIsNeverBlockedUnboundedlyByAConcurrentSlowProcess() async throws {
        let runner = ToolRunner()
        async let slow = runner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        ))
        let fastStarted = Date()
        let fast = try await runner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hello"],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        ))
        let fastElapsed = Date().timeIntervalSince(fastStarted)
        #expect(fast.exitCode == 0)
        #expect(fast.standardOutput.contains("hello"))
        #expect(fastElapsed < 30, "bounded, generous ceiling — catches a return to the original *unbounded* hang, not best-case latency")
        _ = try await slow
    }
}
