import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// The baseline control runs products compiled in the baseline sandbox,
/// whose `#filePath` values name it. That sandbox must still exist while the
/// control runs, and be gone once the run is over.
@Suite("Mutation runner: the baseline sandbox outlives the baseline control", .subprocessExclusive)
struct MutationRunnerBaselineControlOriginLifetimeTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-control-origin-project-\(UUID().uuidString)")
    private let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-control-origin-scratch-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    @Test("The sandbox the baseline was built in exists during the control run and is removed afterwards")
    func baselineSandboxExistsDuringControl() async throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var enabled = true }".utf8).write(to: url)

        let configuration = Configuration(execution: ExecutionSettings(retestKilledMutants: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let probe = Probe()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: ProbeBuild(probe: probe), test: ProbeTest(probe: probe), workspaces: workspaces
        )
        let report = try await runner.run()

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        let observed = await probe.snapshot()
        #expect(observed.runs == 3, "primary, confirmation and baseline control")
        let origin = try #require(observed.baselineWorkspace)
        #expect(observed.originExistedDuringControl == true, "the baseline sandbox was gone when the control ran")
        #expect(!FileManager.default.fileExists(atPath: origin.path), "the baseline sandbox leaked past the run")
    }
}

private struct Snapshot {
    let runs: Int
    let baselineWorkspace: URL?
    let originExistedDuringControl: Bool?
}

private actor Probe {
    private(set) var baselineWorkspace: URL?
    private var runs = 0
    private var originExistedDuringControl: Bool?

    func recordBaseline(_ workspace: URL) { baselineWorkspace = workspace }

    /// Returns the 1-based index of this run; the third is the control.
    func recordRun() -> Int {
        runs += 1
        if runs == 3, let baselineWorkspace {
            originExistedDuringControl = FileManager.default.fileExists(atPath: baselineWorkspace.path)
        }
        return runs
    }

    func snapshot() -> Snapshot {
        Snapshot(runs: runs, baselineWorkspace: baselineWorkspace, originExistedDuringControl: originExistedDuringControl)
    }
}

private struct ProbeBuild: BuildAdapter {
    let probe: Probe

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        await probe.recordBaseline(workspace)
        return artifact(workspace, hash: "baseline-hash")
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        artifact(workspace, hash: "mutant-hash")
    }

    private func artifact(_ workspace: URL, hash: String) -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: hash, xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Primary and confirmation fail; the unmutated control passes.
private struct ProbeTest: TestAdapter {
    let probe: Probe

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        result(await probe.recordRun() == 3 ? .passed : .failed)
    }

    private func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : TestOutcomeSummary(total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.01),
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)"
        )
    }
}
