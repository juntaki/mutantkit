import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.retestKilledMutants`: does
/// the runner actually call the test adapter a second time when a mutant looks
/// killed, and only then? `ResultClassifierFlakyTests` pins what the retest
/// concludes; this pins when the runner asks for one at all. Build and test are
/// faked — no toolchain involved — but the sandboxing, mutation application and
/// classification wiring are all real, which is where a wiring bug would
/// actually live.
@Suite("Mutation runner: flaky retest")
struct MutationRunnerFlakyRetestTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-runner-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-runner-scratch")
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

    /// A single bool literal is the only mutation the two registered operators
    /// produce here, so the plan is guaranteed to hold exactly one mutant and
    /// the scripted adapter never has to disambiguate which point it was asked
    /// about.
    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    private func run(retestKilledMutants: Bool, mutantSequence: [TestRunStatus]) async throws -> RunReport {
        try writeSingleMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(retestKilledMutants: retestKilledMutants)
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: ScriptedTestAdapter(mutantSequence: mutantSequence),
            workspaces: workspaces
        )
        return try await runner.run()
    }

    // MARK: - Off by default

    /// With the flag off, a killed mutant is reported as-is from a single test
    /// run. The scripted adapter is given exactly one mutant response; a second
    /// call the runner should not be making would exhaust it and fail the test
    /// with an out-of-bounds trap rather than a quiet mismatch.
    @Test("retestKilledMutants off: a kill is reported from a single run")
    func retestOffReportsSingleRunKill() async throws {
        let report = try await run(retestKilledMutants: false, mutantSequence: [.failed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        // No confirmation retest ran, so there is no confirmation timing to
        // report — `nil`, not zero.
        #expect(result.confirmationDurationSeconds == nil)
    }

    // MARK: - On, and consistent

    /// With the flag on, a mutant that fails twice in a row stays killed — the
    /// second run confirms rather than overturns the first.
    @Test("retestKilledMutants on: two failures in a row stay killedByAssertion")
    func retestOnConsistentKillStaysKilled() async throws {
        let report = try await run(retestKilledMutants: true, mutantSequence: [.failed, .failed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        #expect(result.diagnosis.contains("Confirmed"))
        // The confirmation retest actually ran, so its wall time must be
        // recorded.
        let confirmationDuration = try #require(result.confirmationDurationSeconds)
        #expect(confirmationDuration >= 0)
    }

    // MARK: - On, and inconsistent

    /// With the flag on, a mutant that fails once and then passes on the
    /// identical, already-built artifact is the suite disagreeing with itself —
    /// reported `flaky`, not `killedByAssertion`.
    @Test("retestKilledMutants on: a failure followed by a pass is reported flaky")
    func retestOnInconsistentKillIsFlaky() async throws {
        let report = try await run(retestKilledMutants: true, mutantSequence: [.failed, .passed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
    }

    // MARK: - Survivors are never retested

    /// The retest only ever guards against a false kill, never a false
    /// survival. A mutant that passes on the first run must not trigger a
    /// second call — the scripted adapter here has only one response queued, so
    /// an unwanted retest call would trap instead of silently passing.
    @Test("retestKilledMutants on: a survivor is not retested")
    func retestOnSurvivorIsNotRetested() async throws {
        let report = try await run(retestKilledMutants: true, mutantSequence: [.passed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .survived)
    }
}

// MARK: - Fakes

/// Always succeeds, with a mutant product hash that differs from the
/// baseline's — activation evidence is proven, so classification reaches the
/// test-status branch this suite is actually exercising.
private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Returns baseline `.passed`, then walks through `mutantSequence` one status
/// per call to `runMutant` — exactly the shape a retest needs: call one is the
/// first run, call two (if it happens) is the confirmation.
private actor ScriptedTestAdapter: TestAdapter {
    private var remaining: [TestRunStatus]

    init(mutantSequence: [TestRunStatus]) {
        remaining = mutantSequence
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
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
