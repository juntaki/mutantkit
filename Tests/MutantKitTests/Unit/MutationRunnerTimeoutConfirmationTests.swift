import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.confirmTimedOutMutants`:
/// does the runner rebuild a `.timedOut` mutant from scratch, in an
/// independent sandbox and under the same timeout limit, before trusting the
/// verdict — and only for a timeout, never for an assertion kill, a crash, or
/// a survivor. Mirrors `MutationRunnerCrashConfirmationTests` exactly; a
/// mutant's crash-vs-hang manifestation was found, empirically, to be
/// unstable across execution context even when whether it was caught at all
/// was not, which is the whole reason this exists as `confirmCrashKills`'s
/// twin rather than a one-off.
@Suite("Mutation runner: timeout confirmation")
struct MutationRunnerTimeoutConfirmationTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-timeout-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-timeout-scratch")
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

    /// `confirmCrashKills` defaults on; every test here disables it so a
    /// `.crashed` scripted response (used only in the "not triggered for a
    /// crash" case) cannot also trigger crash confirmation and consume a
    /// response this suite never queued.
    ///
    /// `isFirstTimeoutBatchAttributed` defaults `true`: most of this suite
    /// tests the batch-wide-timeout shape (see the tests below). The
    /// "individually observed" tests further down pass `false` explicitly.
    private func run(
        confirmTimedOutMutants: Bool,
        mutantSequence: [TestRunStatus],
        isFirstTimeoutBatchAttributed: Bool = true
    ) async throws -> RunReport {
        try writeSingleMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(confirmCrashKills: false, confirmTimedOutMutants: confirmTimedOutMutants)
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
            test: ScriptedTestAdapter(
                mutantSequence: mutantSequence, isFirstTimeoutBatchAttributed: isFirstTimeoutBatchAttributed
            ),
            workspaces: workspaces
        )
        return try await runner.run()
    }

    // MARK: - Off

    /// With the flag off, a timeout is reported from a single run. The
    /// scripted adapter is given exactly one response; a second call the
    /// runner should not be making would exhaust it and trap.
    @Test("confirmTimedOutMutants off: a timeout is reported from a single run")
    func confirmOffReportsSingleRunTimeout() async throws {
        let report = try await run(confirmTimedOutMutants: false, mutantSequence: [.timedOut])

        let result = try #require(report.results.first)
        #expect(result.outcome == .timedOut)
        #expect(result.evidence?.timeoutConfirmation == nil)
        // Unconfirmed, so excluded — not yet proven a kill.
        #expect(!result.outcome.isScorable)
    }

    // MARK: - On, and consistent

    /// With the flag on, a mutant that times out twice in a row — the second
    /// time from an independent rebuild under the same limit — becomes
    /// `.verifiedTimeout` and counts as killed.
    @Test("confirmTimedOutMutants on: two timeouts in a row become verifiedTimeout")
    func confirmOnConsistentTimeoutIsVerified() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.timedOut, .timedOut])

        let result = try #require(report.results.first)
        #expect(result.outcome == .verifiedTimeout)
        #expect(result.outcome.detection == .detected)
        #expect(result.outcome.isKilled)
        let confirmation = try #require(result.evidence?.timeoutConfirmation)
        #expect(confirmation.timedOutAgain)
        #expect(confirmation.confirmingBuildCommand != nil)
        #expect(confirmation.confirmingTestCommand != nil)
    }

    // MARK: - On, and inconsistent — batch-attributed original timeout

    //
    // The exact shape found investigating the arithmetic batch-timeout
    // cluster (`investigation/arithmetic-batch-timeout-cluster`): a
    // batch-wide timeout attributes `.timedOut` to every mutant in the
    // batch, whether or not each one individually hung — of 9 mutants a
    // real batch timeout attributed `.timedOut` to, only 2 hung again in
    // an independent rebuild; the other 7 built and tested in seconds,
    // deterministically. The confirming rebuild is therefore the first
    // real, trustworthy observation of the mutant, not a second opinion to
    // weigh against a first — so its actual result (survived/killed/
    // crashed) is what gets reported, not `.flaky`. These tests use the
    // default `isFirstTimeoutBatchAttributed: true`.

    /// A mutant that times out once and then passes cleanly on an
    /// independently rebuilt copy: the timeout was never a fact about this
    /// mutant, so the passing rebuild is trusted as `.survived`, the same as
    /// any other passing run with proven activation.
    @Test("confirmTimedOutMutants on, batch-attributed: a timeout followed by a clean rebuild trusts the rebuild as survived")
    func confirmOnTimeoutThenPassIsSurvived() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.timedOut, .passed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .survived)
        let confirmation = try #require(result.evidence?.timeoutConfirmation)
        #expect(!confirmation.timedOutAgain)
        #expect(result.outcome.isScorable)
    }

    /// A mutant that times out once and then fails an assertion on an
    /// independently rebuilt copy: trusted as `.killedByAssertion`, not
    /// `.flaky` — the rebuild is a real, deterministic kill.
    @Test("confirmTimedOutMutants on, batch-attributed: a timeout followed by a failing rebuild trusts the rebuild as killed")
    func confirmOnTimeoutThenFailIsKilled() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.timedOut, .failed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        let confirmation = try #require(result.evidence?.timeoutConfirmation)
        #expect(!confirmation.timedOutAgain)
        #expect(result.outcome.isKilled)
    }

    /// A confirmation rebuild that crashes instead of hanging: trusted as
    /// `.killedByCrash`, the same outcome a first-run crash would get. This
    /// suite runs with `confirmCrashKills: false`, so nothing gates this
    /// result further here — see the "kill discovered via timeout
    /// confirmation" tests below for what happens when `confirmCrashKills`
    /// is also on.
    @Test("confirmTimedOutMutants on, batch-attributed: a timeout followed by a crash trusts the rebuild as killed by crash")
    func confirmOnTimeoutThenCrashIsKilledByCrash() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.timedOut, .crashed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByCrash)
        let confirmation = try #require(result.evidence?.timeoutConfirmation)
        #expect(!confirmation.timedOutAgain)
        #expect(result.outcome.isKilled)
    }

    // MARK: - On, and inconsistent — individually observed original timeout

    //
    // No batching (or a batch of one): the original `.timedOut` is a real,
    // specific observation of this exact mutant — a codex review of the
    // batch-attribution fix caught that trusting *every* disagreeing
    // confirmation, regardless of provenance, would misclassify a genuinely
    // intermittent single-mutant hang the same way a batch-attributed one
    // is handled. These tests pass `isFirstTimeoutBatchAttributed: false`
    // and confirm the original, conservative `.flaky` behavior still
    // applies here.

    @Test("confirmTimedOutMutants on, individually observed: a timeout followed by a clean rebuild is flaky, not survived")
    func confirmOnIndividuallyObservedTimeoutThenPassIsFlaky() async throws {
        let report = try await run(
            confirmTimedOutMutants: true, mutantSequence: [.timedOut, .passed], isFirstTimeoutBatchAttributed: false
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
        #expect(!result.outcome.isScorable)
    }

    @Test("confirmTimedOutMutants on, individually observed: a timeout followed by a failing rebuild is flaky, not killed")
    func confirmOnIndividuallyObservedTimeoutThenFailIsFlaky() async throws {
        let report = try await run(
            confirmTimedOutMutants: true, mutantSequence: [.timedOut, .failed], isFirstTimeoutBatchAttributed: false
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
    }

    @Test("confirmTimedOutMutants on, individually observed: a timeout followed by a crash is flaky, not killed by crash")
    func confirmOnIndividuallyObservedTimeoutThenCrashIsFlaky() async throws {
        let report = try await run(
            confirmTimedOutMutants: true, mutantSequence: [.timedOut, .crashed], isFirstTimeoutBatchAttributed: false
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
    }

    // MARK: - A kill discovered via timeout confirmation still clears its

    // own confirmation gate
    //
    // `retestKilledMutants`/`confirmCrashKills` each check the mutant's
    // classification *before* `confirmTimeout` runs, so a kill that only
    // surfaces from the timeout-confirmation rebuild would otherwise skip
    // them entirely — reported with strictly weaker evidence than any other
    // kill. These tests turn the relevant flag on (only `run` above defaults
    // it off) and confirm the chained confirmation actually runs.

    private func runWithChainedConfirmation(
        confirmCrashKills: Bool = false,
        retestKilledMutants: Bool = false,
        mutantSequence: [TestRunStatus]
    ) async throws -> RunReport {
        try writeSingleMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(
                retestKilledMutants: retestKilledMutants,
                confirmCrashKills: confirmCrashKills,
                confirmTimedOutMutants: true
            )
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

    /// `retestKilledMutants: true`: a kill discovered via timeout
    /// confirmation gets its own same-artifact retest, exactly like any
    /// other assertion kill — the scripted sequence needs a *third*
    /// response (timeout, then the confirming rebuild's failure, then the
    /// retest) for the run to complete at all, which is itself part of what
    /// this test proves.
    @Test("retestKilledMutants on: a kill discovered via timeout confirmation is retested")
    func killDiscoveredViaTimeoutConfirmationIsRetested() async throws {
        let report = try await runWithChainedConfirmation(
            retestKilledMutants: true, mutantSequence: [.timedOut, .failed, .failed]
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        #expect(result.outcome.isKilled)
    }

    /// The chained retest can still downgrade to `.flaky` — a kill
    /// discovered via timeout confirmation is not exempt from disagreeing
    /// with its own retest, the same as any other assertion kill.
    @Test("retestKilledMutants on: a kill discovered via timeout confirmation that fails its own retest is flaky")
    func killDiscoveredViaTimeoutConfirmationCanStillBeFlaky() async throws {
        let report = try await runWithChainedConfirmation(
            retestKilledMutants: true, mutantSequence: [.timedOut, .failed, .passed]
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
        #expect(!result.outcome.isScorable)
    }

    /// `confirmCrashKills: true`: a crash discovered via timeout
    /// confirmation gets its own independent-rebuild crash confirmation —
    /// the scripted sequence needs a third response (timeout, then the
    /// confirming rebuild's crash, then the crash-confirmation rebuild) for
    /// the run to complete, and `evidence.crashConfirmation` is populated
    /// exactly as it would be for a first-observed crash.
    @Test("confirmCrashKills on: a crash discovered via timeout confirmation is independently reconfirmed")
    func crashDiscoveredViaTimeoutConfirmationIsReconfirmed() async throws {
        let report = try await runWithChainedConfirmation(
            confirmCrashKills: true, mutantSequence: [.timedOut, .crashed, .crashed]
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByCrash)
        let crashConfirmation = try #require(result.evidence?.crashConfirmation)
        #expect(crashConfirmation.crashedAgain)
    }

    /// The chained crash confirmation can still downgrade to `.flaky` — an
    /// independent rebuild that does not crash the same way a second time
    /// is the pipeline disagreeing with itself, the same as any other
    /// unconfirmed crash.
    @Test("confirmCrashKills on: a crash discovered via timeout confirmation that fails reconfirmation is flaky")
    func crashDiscoveredViaTimeoutConfirmationCanStillBeFlaky() async throws {
        let report = try await runWithChainedConfirmation(
            confirmCrashKills: true, mutantSequence: [.timedOut, .crashed, .passed]
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .flaky)
        let crashConfirmation = try #require(result.evidence?.crashConfirmation)
        #expect(!crashConfirmation.crashedAgain)
    }

    // MARK: - Never triggered for anything but a timeout

    /// The confirmation only ever guards a `.timedOut` verdict.
    /// `confirmTimedOutMutants` being on must not trigger a rebuild for an
    /// assertion kill — the scripted adapter has only one response queued,
    /// so an unwanted confirmation call would trap.
    @Test("confirmTimedOutMutants on: an assertion kill is not confirmed")
    func confirmOnDoesNotAffectAssertionKills() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.failed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        #expect(result.evidence?.timeoutConfirmation == nil)
    }

    /// Nor a crash (`confirmCrashKills` is off in this suite's harness, so a
    /// second scripted response would trap if either confirmation fired).
    @Test("confirmTimedOutMutants on: a crash is not confirmed by this mechanism")
    func confirmOnDoesNotAffectCrashes() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.crashed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByCrash)
        #expect(result.evidence?.timeoutConfirmation == nil)
        #expect(result.evidence?.crashConfirmation == nil)
    }

    /// Nor a survivor.
    @Test("confirmTimedOutMutants on: a survivor is not confirmed")
    func confirmOnDoesNotAffectSurvivors() async throws {
        let report = try await run(confirmTimedOutMutants: true, mutantSequence: [.passed])

        let result = try #require(report.results.first)
        #expect(result.outcome == .survived)
        #expect(result.evidence?.timeoutConfirmation == nil)
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
///
/// The *first* response, if it is `.timedOut`, is tagged
/// `isBatchAttributedTimeout` per `isFirstTimeoutBatchAttributed` (default
/// `true`, matching the shape most of this suite tests) — every later
/// response is a confirmation/retest rebuild's own result, never itself a
/// first-run batch placeholder, so it is never tagged.
private actor ScriptedTestAdapter: TestAdapter {
    private var remaining: [TestRunStatus]
    private var isFirstResponse = true
    private let isFirstTimeoutBatchAttributed: Bool

    init(mutantSequence: [TestRunStatus], isFirstTimeoutBatchAttributed: Bool = true) {
        remaining = mutantSequence
        self.isFirstTimeoutBatchAttributed = isFirstTimeoutBatchAttributed
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
        let status = remaining.removeFirst()
        let isBatchAttributed = isFirstResponse && status == .timedOut && isFirstTimeoutBatchAttributed
        isFirstResponse = false
        return Self.result(status, isBatchAttributedTimeout: isBatchAttributed)
    }

    private static func result(_ status: TestRunStatus, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }
}
