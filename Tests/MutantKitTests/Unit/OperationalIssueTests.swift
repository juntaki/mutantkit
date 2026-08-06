import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// A checkpoint write failure must never change a mutant's verdict or the
/// run's integrity — checkpoints are best-effort by design — but it must
/// stop being silent: it belongs both on stderr (for a human watching the
/// run live) and in `RunReport.operationalIssues` (for a reader of
/// `report.json` afterward).
@Suite("Operational issues: checkpoint write failure visibility")
struct OperationalIssueTests {
    private let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-operational-issue-project-\(UUID().uuidString)")
    private let scratchRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-operational-issue-scratch-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil,
        swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    /// A checkpoint URL whose parent directory can never be created: the
    /// path component immediately above it is a plain file, not a
    /// directory, so `FileManager.createDirectory` fails every time —
    /// a real, reproducible I/O failure rather than a mocked error.
    private func makeUnwritableCheckpointURL() throws -> URL {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-operational-issue-blocker-\(UUID().uuidString)")
        try Data().write(to: blockingFile)
        return blockingFile.appendingPathComponent("sub").appendingPathComponent("checkpoint.jsonl")
    }

    @Test("checkpoint write failure is visible in the run report and does not change the verdict")
    func checkpointFailureIsReportedWithoutChangingTheVerdict() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let checkpoints = CheckpointStore(url: try makeUnwritableCheckpointURL(), policy: .permissive)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: StubBuildAdapter(), test: CountingTestAdapter(), workspaces: workspaces,
            checkpoints: checkpoints
        )

        let report = try await runner.run()

        #expect(report.integrity.passed)
        #expect(report.results.first(where: { $0.id == point.id })?.outcome == .killedByAssertion)
        #expect(report.operationalIssues.count == 1)
        #expect(report.operationalIssues.first?.kind == .checkpointWriteFailed)
        #expect(report.operationalIssues.first?.severity == .warning)
        #expect(report.operationalIssues.first?.mutationID == point.id)
    }

    @Test("a successful run reports no operational issues")
    func successfulRunReportsNoIssues() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: StubBuildAdapter(), test: CountingTestAdapter(), workspaces: workspaces
        )

        let report = try await runner.run()

        #expect(report.operationalIssues.isEmpty)
    }

    @Test("a pre-existing report JSON with no operationalIssues field decodes as an empty list")
    func legacyReportDecodesWithEmptyOperationalIssues() throws {
        // Same shape `RunReport` produced before `operationalIssues` existed
        // — the field is simply absent, not present-and-empty.
        let json = """
        {
            "schemaVersion": 1,
            "planID": "plan-1",
            "startedAt": "2026-01-01T00:00:00Z",
            "finishedAt": "2026-01-01T00:00:01Z",
            "projectRoot": "/tmp/project",
            "toolchain": {
                "toolVersion": "0.1.0", "toolCommitSHA": null, "swiftVersion": "6.3.3",
                "swiftSyntaxVersion": "603.0.2", "xcodeVersion": null
            },
            "baseline": {
                "passed": true, "testSummary": null, "durationSeconds": 0,
                "buildProductHash": null, "buildCommand": null, "testCommand": null
            },
            "results": [],
            "integrity": {
                "discovered": 0, "planned": 0, "sourceApplied": 0, "buildObserved": 0,
                "buildFailures": 0, "executed": 0, "classified": 0, "reported": 0,
                "explicitlySkipped": 0, "skippedByReason": [], "violations": []
            }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunReport.self, from: Data(json.utf8))
        #expect(decoded.operationalIssues.isEmpty)
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "baseline-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "mutant-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private actor CountingTestAdapter: TestAdapter {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        Self.result(.failed)
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)"
        )
    }
}
