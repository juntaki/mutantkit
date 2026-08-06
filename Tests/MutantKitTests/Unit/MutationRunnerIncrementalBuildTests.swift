import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.incrementalBuild`: does
/// the runner actually reuse one sandbox per worker across the mutants it
/// evaluates, instead of a fresh one per mutant — and does a mutant's own
/// crash/timeout confirmation rerun still get its own independent sandbox
/// regardless, since that isolation guarantee (found necessary the hard way,
/// see `MutationRunnerCrashConfirmationTests`) must not weaken just because
/// the *first* attempt now reuses one.
///
/// `workers: 1` throughout: forcing everything onto a single worker makes
/// sandbox reuse (or its absence) deterministic to assert on, rather than a
/// property that only sometimes shows up depending on how the scheduler
/// happened to interleave two concurrent workers.
@Suite("Mutation runner: incremental build")
struct MutationRunnerIncrementalBuildTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-incremental-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-incremental-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// Two independent bool-literal mutation sites in one file — enough to
    /// prove a worker can process a second mutant, in the same file, after
    /// reverting the first, without the second's anchor being rejected by
    /// leftover state from the first.
    private func writeTwoMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true; var visible = false }".utf8).write(to: url)
    }

    private func run(
        incrementalBuild: Bool,
        confirmCrashKills: Bool = false,
        mutantSequence: [TestRunStatus]
    ) async throws -> (RunReport, SpyBuildAdapter, SpyTestAdapter) {
        try writeTwoMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(
                workers: 1,
                confirmCrashKills: confirmCrashKills,
                incrementalBuild: incrementalBuild
            )
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 2)

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let build = SpyBuildAdapter()
        let test = SpyTestAdapter(mutantSequence: mutantSequence)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: build,
            test: test,
            workspaces: workspaces
        )
        let report = try await runner.run()
        return (report, build, test)
    }

    @Test("incrementalBuild off: each mutant still gets its own fresh sandbox")
    func nonIncrementalUsesAFreshSandboxPerMutant() async throws {
        let (report, build, _) = try await run(incrementalBuild: false, mutantSequence: [.failed, .failed])

        #expect(report.results.count == 2)
        #expect(report.results.allSatisfy { $0.outcome == .killedByAssertion })

        let workspacesUsed = await build.buildMutantCalls.map(\.workspace)
        #expect(Set(workspacesUsed).count == 2, "expected two distinct sandboxes, got \(workspacesUsed)")

        // Every mutant here built and was tested successfully, so both
        // per-phase timings must be recorded — and batching was never
        // configured for this run, so there is no batch summary to report.
        for result in report.results {
            let buildDuration = try #require(result.buildDurationSeconds)
            let testDuration = try #require(result.testDurationSeconds)
            #expect(buildDuration >= 0)
            #expect(testDuration >= 0)
        }
        #expect(report.batchExecution == nil)
    }

    @Test("incrementalBuild on, one worker: both mutants build in the same reused sandbox")
    func incrementalBuildReusesOneSandboxAcrossMutants() async throws {
        let (report, build, _) = try await run(incrementalBuild: true, mutantSequence: [.failed, .failed])

        #expect(report.results.count == 2)
        // Both scored normally — not `.notApplied` — which is the outcome a
        // failed revert would produce: the second mutation's anchor would
        // no longer match a file still carrying the first one's edit.
        #expect(report.results.allSatisfy { $0.outcome == .killedByAssertion })

        let workspacesUsed = await build.buildMutantCalls.map(\.workspace)
        #expect(workspacesUsed.count == 2)
        #expect(Set(workspacesUsed).count == 1, "expected one shared sandbox, got \(workspacesUsed)")
    }

    @Test("incrementalBuild on: the baseline still builds in its own sandbox, not a worker's")
    func baselineSandboxIsNeverAWorkerSandbox() async throws {
        let (_, build, _) = try await run(incrementalBuild: true, mutantSequence: [.failed, .failed])

        let baselineWorkspace = try #require(await build.buildBaselineCalls.first)
        let mutantWorkspaces = Set(await build.buildMutantCalls.map(\.workspace))
        #expect(!mutantWorkspaces.contains(baselineWorkspace))
    }

    @Test("incrementalBuild on, confirmCrashKills on: the confirmation rebuild still gets its own independent sandbox")
    func confirmationStaysIndependentUnderIncrementalBuild() async throws {
        let (report, build, _) = try await run(
            incrementalBuild: true, confirmCrashKills: true, mutantSequence: [.crashed, .crashed, .crashed, .crashed]
        )

        #expect(report.results.count == 2)
        #expect(report.results.allSatisfy { $0.outcome == .killedByCrash })

        // Four builds total: two originals (the shared worker sandbox) and
        // two independent crash confirmations (their own, one-off sandboxes).
        #expect(await build.buildMutantCalls.count == 4)
        let workspaces = await build.buildMutantCalls.map(\.workspace)
        let sharedWorkerWorkspace = workspaces[0]
        // The two confirmation rebuilds must not land in the shared worker
        // sandbox, and must not share a sandbox with each other either —
        // each crash confirmation is its own fresh, independent rebuild.
        let confirmationWorkspaces = workspaces.filter { $0 != sharedWorkerWorkspace }
        #expect(confirmationWorkspaces.count == 2)
        #expect(Set(confirmationWorkspaces).count == 2, "each confirmation must be independently sandboxed")
    }
}

// MARK: - Fakes

private actor SpyBuildAdapter: BuildAdapter {
    private(set) var buildBaselineCalls: [URL] = []
    private(set) var buildMutantCalls: [(workspace: URL, mutationID: String)] = []

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        buildBaselineCalls.append(workspace)
        return BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        buildMutantCalls.append((workspace, mutation.point.id.rawValue))
        return BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash-\(mutation.point.id.rawValue)",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private actor SpyTestAdapter: TestAdapter {
    private var remaining: [TestRunStatus]

    init(mutantSequence: [TestRunStatus]) {
        remaining = mutantSequence
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        precondition(!remaining.isEmpty, "runMutant called more times than the test scripted")
        return Self.result(remaining.removeFirst())
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)"
        )
    }
}
