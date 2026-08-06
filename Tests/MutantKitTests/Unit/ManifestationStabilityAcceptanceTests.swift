import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// The acceptance criterion this whole `detection`/`manifestation` split
/// exists to satisfy: a mutant found on a real project (`CatmullRomInterpolation.swift`
/// in a real-world app) whose confirmed manifestation varied — `killedByCrash` on
/// one machine, `.flaky` on a second attempt of the same machine, `.timedOut`
/// on a third, all under an identical plan, commit, and timeout — while
/// whether it was caught at all never once varied. This suite reproduces
/// that shape deterministically: the same mutant, evaluated independently
/// several times (each an isolated `MutationRunner.run()`, standing in for
/// "the same mutant, run again — possibly on a different machine, possibly
/// under different concurrency"), landing on a different *manifestation*
/// each time by construction, and asserts what must stay true regardless:
/// `detection`, `isKilled`, and the resulting score.
@Suite("Manifestation instability, detection stability")
struct ManifestationStabilityAcceptanceTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-manifestation-project")
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

    /// One independent evaluation of the identical mutant — a fresh
    /// `MutationRunner.run()` against a fresh scratch directory, exactly as
    /// two separate `mutantkit run` invocations (on the same machine, or two
    /// different ones) would each produce their own, isolated result.
    ///
    /// `isFirstTimeoutBatchAttributed` defaults `true` — most of this suite's
    /// timeout scenarios are the batch-attributed shape; the one test that
    /// isn't passes `false` explicitly.
    private func evaluate(
        mutantSequence: [TestRunStatus], isFirstTimeoutBatchAttributed: Bool = true
    ) async throws -> MutationResult {
        try writeSingleMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(confirmCrashKills: true, confirmTimedOutMutants: true)
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let scratchRoot = Self.makeTempDir(prefix: "mutantkit-manifestation-scratch")
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
        let report = try await runner.run()
        return try #require(report.results.first)
    }

    /// Three independent evaluations of the identical mutant, landing on
    /// three different manifestations by construction — a crash confirmed by
    /// an independent rebuild, a timeout confirmed the same way, and a plain
    /// assertion failure. This is the CatmullRom shape: nothing here says
    /// these came from the same mutant on the same commit, but that is
    /// exactly the point — `MutationRunner` cannot and does not know that
    /// either, which is why the guarantee has to hold structurally rather
    /// than by recognizing the mutant.
    @Test("Three manifestations of the same mutant all agree: detected, never survived")
    func threeManifestationsAllDetected() async throws {
        let crashConfirmed = try await evaluate(mutantSequence: [.crashed, .crashed])
        let timeoutConfirmed = try await evaluate(mutantSequence: [.timedOut, .timedOut])
        let assertion = try await evaluate(mutantSequence: [.failed])

        let results = [crashConfirmed, timeoutConfirmed, assertion]

        // Three different manifestations...
        #expect(Set(results.map(\.outcome)) == [.killedByCrash, .verifiedTimeout, .killedByAssertion])

        // ...one detection story.
        for result in results {
            #expect(result.outcome.detection == .detected, "\(result.outcome) was not .detected")
            #expect(result.outcome.isKilled, "\(result.outcome) was not isKilled")
            #expect(result.outcome != .survived)
        }
    }

    /// The score-level statement of the same guarantee: whichever
    /// manifestation a mutant happens to land on, it contributes identically
    /// to both the numerator and the denominator of both scores. A score
    /// that moved with manifestation would be measuring the environment a
    /// mutant happened to run in, not the test suite.
    @Test("Every manifestation contributes an identical score")
    func everyManifestationScoresIdentically() async throws {
        let crash = try await evaluate(mutantSequence: [.crashed, .crashed])
        let timeout = try await evaluate(mutantSequence: [.timedOut, .timedOut])
        let assertion = try await evaluate(mutantSequence: [.failed])

        let scores = [crash, timeout, assertion].map { MutationScore.tally([$0.outcome, .survived]) }

        for score in scores {
            #expect(score.killed == 1)
            #expect(score.survived == 1)
            #expect(score.tested == 0.5)
            #expect(score.excluded.isEmpty)
        }
    }

    /// An unreproduced crash — the confirming rebuild passes instead of
    /// crashing again — is the deliberate exception: unlike the three
    /// manifestations above, this one is *not* detected, because nothing
    /// independent ever confirmed it. `confirmCrash`'s rebuild is a genuine
    /// second opinion on the *same* observation (this mutant crashed once),
    /// so a disagreement really is the pipeline contradicting itself.
    @Test("An unconfirmed crash (flaky) is excluded, not silently detected")
    func unconfirmedCrashIsExcludedNotDetected() async throws {
        let result = try await evaluate(mutantSequence: [.crashed, .passed])

        #expect(result.outcome == .flaky)
        #expect(result.outcome.detection == .indeterminate)
        #expect(!result.outcome.isKilled)
        #expect(!result.outcome.isScorable)
    }

    /// An unreproduced timeout is different: unlike a crash, the first
    /// `.timedOut` classification is not necessarily a real observation of
    /// this mutant at all — a batch-wide timeout attributes `.timedOut` to
    /// every mutant sharing that batch, whether or not each one
    /// individually hung (see
    /// `Research/corpus-validation/yomu-2026-07-24/README.md`'s Run E and
    /// `investigation/arithmetic-batch-timeout-cluster`: 7 of 9
    /// batch-attributed timeouts turned out to be fast, deterministic
    /// kills/survivors on independent rebuild). So a confirming rebuild
    /// that passes cleanly is trusted as `.survived`, the mutant's real,
    /// first observation — not folded into `.flaky` the way a genuine
    /// crash disagreement is.
    @Test("An unconfirmed timeout is trusted as its rebuild's real outcome, not flaky")
    func unconfirmedTimeoutTrustsRebuildOutcome() async throws {
        let result = try await evaluate(mutantSequence: [.timedOut, .passed])

        #expect(result.outcome == .survived)
        #expect(result.outcome.detection == .survived)
        #expect(!result.outcome.isKilled)
        #expect(result.outcome.isScorable)
    }

    /// The individually observed twin of the test above: when the original
    /// `.timedOut` was a real, specific observation of this exact mutant
    /// (no batching), a confirming rebuild that disagrees goes back to
    /// `.flaky` — the same conservative call `confirmCrash` makes on its own
    /// disagreement above. A second codex review of the batch-attribution
    /// fix caught this distinction being missing entirely from the first
    /// version of it.
    @Test("An individually observed unconfirmed timeout stays flaky, not trusted as survived")
    func individuallyObservedUnconfirmedTimeoutStaysFlaky() async throws {
        let result = try await evaluate(mutantSequence: [.timedOut, .passed], isFirstTimeoutBatchAttributed: false)

        #expect(result.outcome == .flaky)
        #expect(result.outcome.detection == .indeterminate)
        #expect(!result.outcome.isKilled)
        #expect(!result.outcome.isScorable)
    }
}

// MARK: - Fakes

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

/// The first response, if it is `.timedOut`, is tagged
/// `isBatchAttributedTimeout` per `isFirstTimeoutBatchAttributed` — every
/// later response is a confirmation/retest rebuild's own result, never
/// itself a first-run batch placeholder, so it is never tagged.
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
