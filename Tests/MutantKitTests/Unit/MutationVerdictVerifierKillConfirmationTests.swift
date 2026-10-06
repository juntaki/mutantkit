// swiftlint:disable line_length
// Moved verbatim from MutationVerdictVerifierTests, where these lines were baselined.

import Foundation
import MutationModel
import Testing

/// The kill-confirmation rows of the verifier's decision table, and who authors
/// `assertionKillConfirmation`. Split from `MutationVerdictVerifierTests` to keep
/// that suite within its size baseline.
@Suite("Mutation verdict verifier kill confirmation")
struct MutationVerdictVerifierKillConfirmationTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"

    private func ref(for point: MutationPoint) -> PlannedMutationRef {
        PlannedMutationRef.forPoint(point, planID: Self.planID, workUnitID: Self.workUnitID)
    }

    private func verify(
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = .permissive,
        _ obs: (PlannedMutationRef) -> MutationObservations
    ) throws -> VerifiedMutationRecord {
        let point = try makeAnchoredPoint()
        return MutationVerdictVerifier.verify(obs(ref(for: point)), policy: policy)
    }

    private func run(status: TestRunStatus, summary: TestOutcomeSummary? = nil, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status, summary: summary,
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag:\(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }

    private var provenIsolated: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }
    private var unprovenIsolated: ActivationEvidence { .buildProductIdenticalToBaseline(hash: "h0") }

    // MARK: - Confirmation: kill

    @Test("confirmKill: confirmed, exact failing-test-set match")
    func confirmKillConfirmed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    applicationEvidence: .isolated(provenIsolated),
                    execution: wholeSuiteExecution
                ),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    originalFailingTests: ["ExampleTests/testSomething()"], baselineControl: makePassingBaselineControl()
                )]
            )
        }
        #expect(record.outcome == .killedByAssertion)
        let confirmation = try #require(record.proof.evidence?.assertionKillConfirmation)
        #expect(confirmation.disposition == .confirmed)
        #expect(confirmation.method == .retestOfBuiltMutant)
        #expect(confirmation.confirmingStatus == "failed")
    }

    /// `ConfirmationObservation.originalFailingTests` is a caller-supplied
    /// duplicate of the primary run's own facts and `MutationObservations`
    /// decodes it as untrusted — a corrupted or hand-edited entry could set
    /// it to whatever it wants without the primary run agreeing. The
    /// verifier must compare against the primary run's *own* recorded
    /// failing-test set, not this field, so a forged value here cannot
    /// manufacture a confirmed kill.
    @Test("confirmKill: a forged originalFailingTests field is ignored — the primary run's own summary decides")
    func confirmKillIgnoresForgedOriginalFailingTests() throws {
        let primaryFailure = TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["RealTests/testReal()"], durationSeconds: nil)
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed, summary: primaryFailure),
                    applicationEvidence: .isolated(provenIsolated),
                    execution: wholeSuiteExecution
                ),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: primaryFailure),
                    // Forged: claims a completely different test than the
                    // primary run's own summary actually recorded.
                    originalFailingTests: ["ForgedTests/testForged()"], baselineControl: makePassingBaselineControl()
                )]
            )
        }
        #expect(record.outcome == .killedByAssertion)
        // Recorded from the primary run's own summary, never the forged field.
        #expect(record.proof.evidence?.assertionKillConfirmation?.primaryFailingTests == ["RealTests/testReal()"])
        #expect(record.proof.evidence?.assertionKillConfirmation?.disposition == .confirmed)
    }

    @Test("confirmKill: confirmation's originalFailingTests matches, but the real primary run failed a different test — flaky, not confirmed")
    func confirmKillRealPrimaryDisagreesWithForgedField() throws {
        let primaryFailure = TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["RealTests/testReal()"], durationSeconds: nil)
        let confirmingFailure = TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["OtherTests/testOther()"], durationSeconds: nil)
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed, summary: primaryFailure),
                    applicationEvidence: .isolated(provenIsolated),
                    execution: wholeSuiteExecution
                ),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: confirmingFailure),
                    // Matches the confirming run's own failing test, but not
                    // what the primary run actually recorded — must not be
                    // trusted over the real primary summary.
                    originalFailingTests: ["OtherTests/testOther()"]
                )]
            )
        }
        #expect(record.outcome == .flaky)
        #expect(record.proof.evidence?.assertionKillConfirmation?.disposition == .failingSetDiffers)
        #expect(record.proof.evidence?.assertionKillConfirmation?.primaryFailingTests == ["RealTests/testReal()"])
        #expect(record.proof.evidence?.assertionKillConfirmation?.confirmingFailingTests == ["OtherTests/testOther()"])
    }

    @Test("confirmKill: retest passed instead — flaky")
    func confirmKillRetestPassed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed), applicationEvidence: .isolated(provenIsolated), execution: wholeSuiteExecution
                ),
                confirmations: [ConfirmationObservation(kind: .kill, run: run(status: .passed), originalFailingTests: ["A"])]
            )
        }
        #expect(record.outcome == .flaky)
        #expect(record.proof.evidence?.assertionKillConfirmation?.disposition == .retestNotFailed)
        #expect(record.proof.evidence?.assertionKillConfirmation?.confirmingStatus == "passed")
        // Unknown lists stay nil, never [].
        #expect(record.proof.evidence?.assertionKillConfirmation?.primaryFailingTests == nil)
    }

    @Test("confirmKill: retest failed a different test — flaky")
    func confirmKillDifferentTest() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed), applicationEvidence: .isolated(provenIsolated), execution: wholeSuiteExecution
                ),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["B"], durationSeconds: nil)),
                    originalFailingTests: ["A"]
                )]
            )
        }
        #expect(record.outcome == .flaky)
        // The primary run recorded no per-test breakdown, so the sets cannot be compared.
        #expect(record.proof.evidence?.assertionKillConfirmation?.disposition == .perTestBreakdownMissing)
        #expect(record.proof.evidence?.assertionKillConfirmation?.primaryFailingTests == nil)
        #expect(record.proof.evidence?.assertionKillConfirmation?.confirmingFailingTests == ["B"])
    }

    @Test("confirmKill: no per-test breakdown on either side — flaky, not trusted")
    func confirmKillNoBreakdown() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed), applicationEvidence: .isolated(provenIsolated), execution: wholeSuiteExecution
                ),
                confirmations: [ConfirmationObservation(kind: .kill, run: run(status: .failed), originalFailingTests: nil)]
            )
        }
        #expect(record.outcome == .flaky)
        #expect(record.proof.evidence?.assertionKillConfirmation?.disposition == .perTestBreakdownMissing)
        #expect(record.proof.evidence?.assertionKillConfirmation?.confirmingFailingTests == nil)
    }

    @Test("confirmKill: attached to a primary run that was never a kill — rejected, not promoted")
    func confirmKillOnWrongPrimaryOutcome() throws {
        // Primary run passed but activation was unproven, so the primary
        // classification is .infrastructureFailure, not .killedByAssertion.
        // A hand-edited or corrupted `.kill` confirmation must not be able
        // to promote that to a kill just by matching the failing-test set.
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h0", activation: unprovenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h0", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(unprovenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    originalFailingTests: ["ExampleTests/testSomething()"]
                )]
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(record.proof.evidence?.assertionKillConfirmation == nil)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    // MARK: - assertionKillConfirmation authorship

    @Test("assertionKillConfirmation: a kill with no confirmation recorded carries nil, never a confirmed record")
    func killWithoutConfirmationHasNoRecord() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    applicationEvidence: .isolated(provenIsolated),
                    execution: wholeSuiteExecution
                )
            )
        }
        #expect(record.outcome == .killedByAssertion)
        #expect(record.proof.evidence?.assertionKillConfirmation == nil)
    }

    @Test("assertionKillConfirmation: a value smuggled in on stored source evidence is discarded, not trusted")
    func storedAssertionKillConfirmationIsDiscarded() throws {
        let forged = AssertionKillConfirmation(disposition: .confirmed, primaryFailingTests: ["X"], confirmingFailingTests: ["X"], confirmingStatus: "failed")
        let base = makeEvidence(buildProductHash: "h1", activation: provenIsolated)
        let withForged = MutationEvidence(
            sourceBeforeHash: base.sourceBeforeHash, sourceAfterHash: base.sourceAfterHash, sourceDiff: base.sourceDiff,
            buildProductHash: base.buildProductHash, applicationEvidence: base.applicationEvidence,
            assertionKillConfirmation: forged
        )
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(withForged),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    applicationEvidence: .isolated(provenIsolated),
                    execution: wholeSuiteExecution
                )
            )
        }
        #expect(record.proof.evidence?.assertionKillConfirmation == nil)
    }
}

// swiftlint:enable line_length
