@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Real `swift test` runs against a package whose one test target mixes an
/// XCTest case with Swift Testing tests, pinning where each framework's
/// failure is recorded under the default `tests.parallel: false`.
///
/// SwiftPM writes the XCTest half of `--xunit-output` only in parallel mode.
/// Without it, a failing XCTest left only the Swift Testing report, recording
/// zero failures, so a genuine kill read as the "exit 1, 0 failed"
/// contradiction; and a test process that ended early left no report at all,
/// which used to be credited as an assertion kill.
@Suite("Acceptance: SwiftPM XCTest failures are recorded in xunit", .enabled(if: Acceptance.isEnabled))
struct SwiftPackageMacOSXCTestXUnitAcceptanceTests {
    private struct Staged {
        let workspace: URL
        let adapter: SwiftPackageMacOSAdapter
    }

    private static let staged = Task { () throws -> Staged in
        let workspace = try Acceptance.stageFixture("SwiftPackageMacOSMixedFrameworks")
        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        _ = try await adapter.buildBaseline(in: workspace)
        return Staged(workspace: workspace, adapter: adapter)
    }

    private func staged() async throws -> Staged {
        try await Self.staged.value
    }

    @Test("An unbroken mixed run passes and counts both frameworks' tests")
    func passingRunCountsBothFrameworks() async throws {
        let staged = try await staged()
        let run = try await staged.adapter.runTests(in: staged.workspace, timeoutSeconds: 120)

        #expect(run.status == .passed, "\(run.diagnosis)")
        #expect(run.summary?.total == 3, "\(String(describing: run.summary))")
        #expect(run.command.arguments.contains("--num-workers"))
    }

    @Test("A failing XCTest is named in the xunit report and is an assertion kill")
    func failingXCTestIsNamedKill() async throws {
        let staged = try await staged()
        let run = try await staged.adapter.runTests(
            in: staged.workspace, timeoutSeconds: 120, extraEnvironment: ["FIXTURE_BREAK_XCTEST": "1"]
        )

        #expect(run.status == .failed, "\(run.diagnosis)")
        #expect(run.summary?.failingTests == ["GateTests.GateXCTests/testAnswer"], "\(String(describing: run.summary))")
        // The Swift Testing tests in the same run passed; their report alone
        // would have read "0 failed".
        #expect(run.summary?.failed == 1)
    }

    @Test("A test process that ends without writing a report is not an assertion kill")
    func earlyExitWithoutReportIsInfrastructureFailure() async throws {
        let staged = try await staged()
        let run = try await staged.adapter.runTests(
            in: staged.workspace, timeoutSeconds: 120, extraEnvironment: ["FIXTURE_EXIT": "1"],
            testFilters: ["GateTests.GateSwiftTests/endsProcessOnRequest"]
        )

        #expect(run.status == .infrastructureFailure, "\(run.diagnosis)")
        #expect(run.diagnosis.contains("names any test"), "\(run.diagnosis)")
    }

    @Test("A coverage run does not ask for parallel mode")
    func coverageRunHasNoParallelFlag() async throws {
        let staged = try await staged()
        let run = try await staged.adapter.runTests(
            in: staged.workspace, timeoutSeconds: 300, enableCoverage: true,
            testFilters: ["GateTests.GateSwiftTests/answerIsPositive"]
        )

        #expect(run.command.arguments.contains("--enable-code-coverage"))
        #expect(!run.command.arguments.contains("--parallel"), "\(run.command.arguments)")
        #expect(!run.command.arguments.contains("--num-workers"), "\(run.command.arguments)")
    }
}
