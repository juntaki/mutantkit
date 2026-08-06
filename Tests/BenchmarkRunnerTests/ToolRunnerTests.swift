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
}
