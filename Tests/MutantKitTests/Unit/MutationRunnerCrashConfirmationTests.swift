import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.confirmCrashKills`: does
/// the runner rebuild a `killedByCrash` mutant from scratch, in an
/// independent sandbox, before trusting the verdict — and only for a crash,
/// never for an assertion kill or a survivor. Build and test are faked, but
/// the sandboxing, mutation re-application and classification wiring are all
/// real, which is where the false positive this feature exists to catch
/// actually lived: a same-sandbox retest could not have ruled it out.
@Suite("Mutation runner: crash confirmation")
struct MutationRunnerCrashConfirmationTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-crash-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-crash-scratch")
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

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    private func run(confirmCrashKills: Bool, mutantSequence: [TestRunStatus]) async throws -> RunReport {
        try writeSingleMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(confirmCrashKills: confirmCrashKills)
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

    // MARK: - Off

    /// With the flag off, a crash is reported from a single run. The
    /// scripted adapter is given exactly one response; a second call the
    /// runner should not be making would exhaust it and trap.
    @Test("confirmCrashKills off: a crash is reported from a single run")
    func confirmOffReportsSingleRunCrash() async throws {
        let report = try await run(confirmCrashKills: false, mutantSequence: [.crashed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByCrash)
        #expect(result.evidence?.crashConfirmation == nil)
    }

    // MARK: - On, and consistent

    /// With the flag on, a mutant that crashes twice in a row — the second
    /// time from an independent rebuild — stays killed, and the evidence
    /// records that the confirmation reproduced it.
    @Test("confirmCrashKills on: two crashes in a row stay killedByCrash")
    func confirmOnConsistentCrashStaysKilled() async throws {
        let report = try await run(confirmCrashKills: true, mutantSequence: [.crashed, .crashed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByCrash)
        let confirmation = try #require(result.evidence?.crashConfirmation)
        #expect(confirmation.crashedAgain)
        #expect(confirmation.confirmingBuildCommand != nil)
        #expect(confirmation.confirmingTestCommand != nil)
    }

    // MARK: - On, and inconsistent — the exact shape of the false positive found

    /// With the flag on, a mutant that crashes once and then passes on an
    /// independently rebuilt copy is the pipeline disagreeing with itself —
    /// reported `flaky`, not `killedByCrash`. This is the precise scenario a
    /// same-sandbox retest cannot catch: the "crash" was never reproducible
    /// to begin with.
    @Test("confirmCrashKills on: a crash followed by a clean rebuild is reclassified flaky")
    func confirmOnInconsistentCrashIsFlaky() async throws {
        let report = try await run(confirmCrashKills: true, mutantSequence: [.crashed, .passed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
        let confirmation = try #require(result.evidence?.crashConfirmation)
        #expect(!confirmation.crashedAgain)
        // Flaky is excluded from both scoring denominators.
        #expect(!result.outcome.isScorable)
    }

    // MARK: - Never triggered for anything but a crash

    /// The confirmation only ever guards a `killedByCrash` verdict.
    /// `confirmCrashKills` being on must not trigger a rebuild for an
    /// assertion kill — the scripted adapter has only one response queued,
    /// so an unwanted confirmation call would trap.
    @Test("confirmCrashKills on: an assertion kill is not confirmed")
    func confirmOnDoesNotAffectAssertionKills() async throws {
        let report = try await run(confirmCrashKills: true, mutantSequence: [.failed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        #expect(result.evidence?.crashConfirmation == nil)
    }

    /// Nor a survivor.
    @Test("confirmCrashKills on: a survivor is not confirmed")
    func confirmOnDoesNotAffectSurvivors() async throws {
        let report = try await run(confirmCrashKills: true, mutantSequence: [.passed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .survived)
        #expect(result.evidence?.crashConfirmation == nil)
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
/// per call to `runMutant` — call one is the first run, call two (if it
/// happens) is the confirmation rebuild's test.
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
