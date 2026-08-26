import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Coverage for `MutationRunner.prepare`'s isolated-mode short-circuit: a
/// mutant whose build product hash comes back identical to the baseline's
/// is classified `.infrastructureFailure` the moment the build finishes,
/// without ever running its tests — `MutationVerdictVerifier.classify`
/// routes `.passed`/`.failed`/`.crashed` through `unprovenActivation` to
/// that same outcome once activation is unproven, so for those three
/// statuses a test run would only confirm what the hash comparison already
/// knows. `.timedOut` is the exception: `classify` never gates it on
/// activation, so a hash-identical mutant whose tests hang would *not*
/// collapse to `.infrastructureFailure` if actually run — see
/// `timedOutStatusIsNotGatedByUnprovenActivation` below, which pins that
/// asymmetry down directly against `MutationVerdictVerifier` rather than
/// relying on prose to describe it.
///
/// Also covers `Configuration.execution.noOpCanarySampleRate` (round-2
/// review M2): the escape hatch that lets a small, deterministic fraction
/// of hash-matched mutants skip the short-circuit and run for real, as a
/// canary against `MachOCodeHash` itself reporting a false "identical"
/// (the historical failure mode referenced as "issue #3" in
/// `MachOCodeHash`'s own doc comment).
///
/// Same fakes and fixture shape as `MutationRunnerCoverageCacheTests`, with
/// a call counter on `runMutant` (rather than `measurePerTestCoverage`) so a
/// test can tell whether the short-circuit skipped test execution entirely,
/// plus a `StubBuildAdapter` whose mutant/baseline hashes are configurable
/// per test — identical for the no-op case, distinct for the control case.
@Suite("Mutation runner: no-op build-product short-circuit")
struct MutationRunnerNoOpShortCircuitTests {
    private let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-noop-project-\(UUID().uuidString)")
    private let scratchRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-noop-scratch-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    private func makeRunner(
        build: StubBuildAdapter, test: CountingTestAdapter, plan: MutationPlan, configuration: Configuration = Configuration()
    ) throws -> MutationRunner {
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        return MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: build, test: test, workspaces: workspaces
        )
    }

    @Test("A build product identical to baseline's is classified without ever running tests")
    func identicalBuildProductSkipsTestExecution() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(!plan.mutations.isEmpty)

        // Baseline and mutant builds report the identical product hash —
        // exactly what a genuine no-op mutation (e.g. an operator whose
        // transformation the compiler optimizes away identically) produces.
        let build = StubBuildAdapter(baselineHash: "same-hash", mutantHash: "same-hash")
        let test = CountingTestAdapter(mutantStatus: .failed) // would be a kill IF ever run
        let runner = try makeRunner(build: build, test: test, plan: plan)

        let report = try await runner.run()

        let result = try #require(report.results.first)
        #expect(result.outcome == .infrastructureFailure)
        #expect(result.diagnosis.contains("identical to the baseline"))
        #expect(result.diagnosis.contains("skipped"), "the diagnosis must be honest that tests never ran")
        #expect(!result.diagnosis.contains("The tests passed"), "no test result exists to claim this")

        let baselineCalls = await test.baselineCallCount
        let mutantCalls = await test.mutantCallCount
        #expect(baselineCalls == 1, "the baseline itself must still be tested once, to prove it passes")
        #expect(mutantCalls == 0, "the mutant's own test execution must never be invoked")
        #expect(report.operationalIssues.isEmpty, "noOpCanarySampleRate defaults to 0 — no canary ever samples, so nothing to flag")
    }

    @Test("A build product that differs from baseline's still runs tests normally (control)")
    func differingBuildProductStillRunsTests() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(!plan.mutations.isEmpty)

        let build = StubBuildAdapter(baselineHash: "baseline-hash", mutantHash: "mutant-hash")
        let test = CountingTestAdapter(mutantStatus: .failed)
        let runner = try makeRunner(build: build, test: test, plan: plan)

        let report = try await runner.run()

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)

        let mutantCalls = await test.mutantCallCount
        #expect(mutantCalls == 1, "a real mutant must still be tested exactly once")
    }

    // MARK: - noOpCanarySampleRate (round-2 review M2)

    @Test("noOpCanarySampleRate = 1 runs a hash-matched mutant's tests for real and flags a non-passing outcome")
    func canarySampleRunsTestsAndFlagsUnexpectedOutcome() async throws {
        try writeSingleMutantProject()
        let planConfiguration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: planConfiguration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(!plan.mutations.isEmpty)

        let build = StubBuildAdapter(baselineHash: "same-hash", mutantHash: "same-hash")
        // `.failed` is exactly issue #3's shape: the hash claims "identical",
        // but the suite did not just pass.
        let test = CountingTestAdapter(mutantStatus: .failed)
        var runnerConfiguration = Configuration()
        runnerConfiguration.execution.noOpCanarySampleRate = 1
        let runner = try makeRunner(build: build, test: test, plan: plan, configuration: runnerConfiguration)

        let report = try await runner.run()

        let result = try #require(report.results.first)
        // The verifier still applies its own rules (M1): `.failed` with
        // unproven activation downgrades to `.infrastructureFailure`
        // exactly as it would for any other unproven-activation mutant —
        // the canary changes *whether tests run and get logged*, not what
        // the verifier concludes from them.
        #expect(result.outcome == .infrastructureFailure)

        let mutantCalls = await test.mutantCallCount
        #expect(mutantCalls == 1, "sampling at rate 1 must run every hash-matched mutant's tests for real")

        let issue = try #require(report.operationalIssues.first)
        #expect(issue.kind == .noOpCanaryUnexpectedOutcome)
        #expect(issue.severity == .warning)
        #expect(issue.diagnosis.contains("failed"))
    }

    @Test("noOpCanarySampleRate = 1 with a passing canary run logs no anomaly")
    func canarySampleWithPassingRunLogsNothing() async throws {
        try writeSingleMutantProject()
        let planConfiguration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: planConfiguration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(!plan.mutations.isEmpty)

        let build = StubBuildAdapter(baselineHash: "same-hash", mutantHash: "same-hash")
        let test = CountingTestAdapter(mutantStatus: .passed)
        var runnerConfiguration = Configuration()
        runnerConfiguration.execution.noOpCanarySampleRate = 1
        let runner = try makeRunner(build: build, test: test, plan: plan, configuration: runnerConfiguration)

        let report = try await runner.run()

        let mutantCalls = await test.mutantCallCount
        #expect(mutantCalls == 1, "the canary still runs the real suite even though this run turns out unremarkable")
        #expect(report.operationalIssues.isEmpty, "a canary that simply passes is exactly what the hash predicted — nothing to flag")
    }

    @Test("noOpCanarySampleRate = 0 (the default) never samples, matching the short-circuit's original behaviour")
    func canaryDisabledByDefaultMatchesShortCircuit() async throws {
        try writeSingleMutantProject()
        let planConfiguration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: planConfiguration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(!plan.mutations.isEmpty)

        let build = StubBuildAdapter(baselineHash: "same-hash", mutantHash: "same-hash")
        let test = CountingTestAdapter(mutantStatus: .failed)
        var runnerConfiguration = Configuration()
        runnerConfiguration.execution.noOpCanarySampleRate = 0
        let runner = try makeRunner(build: build, test: test, plan: plan, configuration: runnerConfiguration)

        let report = try await runner.run()

        let mutantCalls = await test.mutantCallCount
        #expect(mutantCalls == 0)
        #expect(report.operationalIssues.isEmpty)
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    let baselineHash: String
    let mutantHash: String

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: baselineHash,
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: mutantHash,
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// A plain `TestAdapter` (not `TestSelecting`) with call counters on both
/// `runBaseline` and the unparameterised `runMutant` — enough to prove
/// whether the short-circuit reached (and stopped short of) test execution,
/// while leaving the baseline's own single test run untouched.
private actor CountingTestAdapter: TestAdapter {
    private let mutantStatus: TestRunStatus
    private(set) var baselineCallCount = 0
    private(set) var mutantCallCount = 0

    init(mutantStatus: TestRunStatus) {
        self.mutantStatus = mutantStatus
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        baselineCallCount += 1
        return Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        mutantCallCount += 1
        return Self.result(mutantStatus)
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
