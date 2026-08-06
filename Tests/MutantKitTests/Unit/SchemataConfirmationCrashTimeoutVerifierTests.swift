import Foundation
import MutationModel
import Testing

/// ADR-0006 Stage 3: the crash/timeout half of
/// `SchemataConfirmationVerifierTests` (split into its own file to keep
/// each suite under the type-body-length limit, not a difference in what
/// is being pinned) — schemata crash and timeout confirmations go through
/// the exact same `MutationVerdictVerifier.confirm` a real run would,
/// never a runner-side shortcut.
@Suite("Schemata confirmation: verifier-only chain validation (crash, timeout)")
struct SchemataConfirmationCrashTimeoutVerifierTests {
    private static let enabledPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: true, confirmCrashKills: true, confirmTimedOutMutants: true
    )

    private func run(status: TestRunStatus, summary: TestOutcomeSummary? = nil, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status, summary: summary,
            command: CommandRecord(executable: "/usr/bin/xcrun", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag:\(status.rawValue)", isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }

    private func verify(
        primary: SchemataExecutionObservation, primaryStatus: TestRunStatus, primarySummary: TestOutcomeSummary? = nil,
        confirmations: [ConfirmationObservation], policy: MutationVerdictVerifier.VerdictVerificationPolicy = enabledPolicy
    ) throws -> VerifiedMutationRecord {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "plan-confirm", workUnitID: "unit-confirm")
        let evidence = MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a\n+++ b\n", buildProductHash: "h1", applicationEvidence: .schemata(primary)
        )
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(run: run(status: primaryStatus, summary: primarySummary), applicationEvidence: .schemata(primary)),
            confirmations: confirmations
        )
        return MutationVerdictVerifier.verify(observations, policy: policy)
    }

    // MARK: - Crash confirmation

    @Test("crash kill + valid crash confirmation: killedByCrash")
    func crashWithValidConfirmation() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation()
        let record = try verify(
            primary: primary, primaryStatus: .crashed,
            confirmations: [ConfirmationObservation(
                kind: .crash, run: run(status: .crashed), schemataObservation: confirmation, originalDiagnosis: "diag:crashed"
            )]
        )
        #expect(record.outcome == .killedByCrash)
    }

    @Test("crash kill + confirmation pass: not killedByCrash")
    func crashWithPassingConfirmation() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation()
        let record = try verify(
            primary: primary, primaryStatus: .crashed,
            confirmations: [ConfirmationObservation(
                kind: .crash, run: run(status: .passed), schemataObservation: confirmation, originalDiagnosis: "diag:crashed"
            )]
        )
        #expect(record.outcome == .flaky)
    }

    @Test("crash kill + confirmation without HIT: not killedByCrash")
    func crashWithoutHit() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(includeHit: false)
        let record = try verify(
            primary: primary, primaryStatus: .crashed,
            confirmations: [ConfirmationObservation(
                kind: .crash, run: run(status: .crashed), schemataObservation: confirmation, originalDiagnosis: "diag:crashed"
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("crash kill + confirmation from the wrong process: not killedByCrash")
    func crashWithWrongProcess() throws {
        let primary = makeConsistentSchemataObservation()
        let runID = RunID()
        let startup = RuntimeStartupEvent(
            runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 1111, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        )
        let hit = RuntimeHitEvent(
            runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 9999, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        )
        let confirmation = SchemataExecutionObservation(
            expectation: SchemataRunExpectation(
                mutationID: schemataFixtureMutationID, compilationUnitID: schemataFixtureCompilationUnitID,
                sourceEmbeddingID: schemataFixtureSourceEmbeddingID, selectorToken: schemataFixtureToken, runID: runID
            ),
            buildReceipt: makeSchemataFixtureReceipt(),
            transcript: RuntimeTranscript(protocolVersion: 3, records: [.startup(startup), .hit(hit)])
        )
        let record = try verify(
            primary: primary, primaryStatus: .crashed,
            confirmations: [ConfirmationObservation(
                kind: .crash, run: run(status: .crashed), schemataObservation: confirmation, originalDiagnosis: "diag:crashed"
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    // MARK: - Timeout confirmation

    @Test("timeout + valid timeout confirmation: verifiedTimeout")
    func timeoutWithValidConfirmation() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation()
        let record = try verify(
            primary: primary, primaryStatus: .timedOut,
            confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .timedOut), schemataObservation: confirmation)]
        )
        #expect(record.outcome == .verifiedTimeout)
    }

    @Test("timeout + confirmation chain missing: not verifiedTimeout")
    func timeoutWithMissingChain() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(includeHit: false)
        let record = try verify(
            primary: primary, primaryStatus: .timedOut,
            confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .timedOut), schemataObservation: confirmation)]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("timeout + confirmation reuses the initial RunID: not verifiedTimeout")
    func timeoutWithReusedRunID() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(runID: schemataFixtureRunID)
        let record = try verify(
            primary: primary, primaryStatus: .timedOut,
            confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .timedOut), schemataObservation: confirmation)]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    /// Isolated mode's own cascade (a batch-attributed timeout's
    /// confirming rebuild turning out to be a real kill/crash, which then
    /// needs *its own* confirmation — `MutationRunner.confirmTimeout`'s
    /// nested `retestKilledMutants`/`confirmCrashKills` calls) is gated on
    /// `TestRunResult.isBatchAttributedTimeout`, which only `runBatch`
    /// (batch testing) ever sets `true`. `SchemataMutationRunner` never
    /// batches at all — "one fresh test process per embedded mutation," no
    /// exception — so a schemata timeout confirmation's own
    /// `isBatchAttributedTimeout` is always `false`, structurally. This
    /// pins that a schemata timeout confirmation whose confirming run
    /// finishes normally (not timed out again) becomes `.flaky`, exactly
    /// like isolated mode's own non-batch-attributed case, never promoted
    /// to a kill/crash — so there is no cascade for `SchemataMutationRunner`
    /// to gather in the first place, not a gap in what it gathers.
    @Test("timeout + confirmation finishes normally (not batch-attributed): flaky, never promoted to a kill — no cascade to gather")
    func timeoutConfirmationFinishingNormallyIsFlakyNotCascaded() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation()
        let record = try verify(
            primary: primary, primaryStatus: .timedOut,
            confirmations: [ConfirmationObservation(
                kind: .timeout, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1), isBatchAttributedTimeout: false),
                schemataObservation: confirmation
            )]
        )
        #expect(
            record.outcome == .flaky, "a non-batch-attributed timeout confirmation must never be promoted to a kill, for either backend"
        )
    }
}
