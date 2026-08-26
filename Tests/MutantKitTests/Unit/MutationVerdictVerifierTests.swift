import Foundation
import MutationModel
import Testing

/// ADR-0006 Stage 1: `MutationVerdictVerifier.verify(_:MutationObservations)`
/// is now the sole place a mutation's outcome is decided — this pins its
/// full decision table, covering every distinct branch the verifier's
/// logic takes (ported from `ResultClassifier`/`SchemataResultClassifier`,
/// which this suite replaces). Not a literal combinatorial matrix of every
/// field × every field, but every branch a reader of the verifier's source
/// would need to trust is correct.
@Suite("Mutation verdict verifier decision table (ADR-0006 Stage 1)")
struct MutationVerdictVerifierTests {
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

    // MARK: - Source application

    @Test("notApplied when the anchor was rejected")
    func notApplied() throws {
        let record = try verify { ref in MutationObservations(plannedMutation: ref, sourceApplication: .notApplied(diagnosis: "anchor moved")) }
        #expect(record.outcome == .notApplied)
        guard case .excluded = record.proof else { Issue.record("expected .excluded"); return }
    }

    @Test("infrastructureFailure when nothing was even attempted")
    func nothingAttempted() throws {
        let record = try verify { ref in MutationObservations(plannedMutation: ref, infrastructureFailureDiagnosis: "sandbox could not be created") }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("Hollow source evidence (no real diff) cannot produce a scorable outcome")
    func hollowSourceEvidenceIsRejected() throws {
        let hollowEvidence = MutationEvidence(
            sourceBeforeHash: "same", sourceAfterHash: "same", sourceDiff: "",
            buildProductHash: "h1", applicationEvidence: .isolated(provenIsolated)
        )
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(hollowEvidence),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    /// `MutationEvidence.applicationEvidence` (attached to the final proof)
    /// and `SingleTestObservation.applicationEvidence` (what the verifier
    /// actually classifies from) are independent `Codable` fields. A
    /// hand-edited or corrupted cache/checkpoint entry could carry forged,
    /// proven-looking activation evidence on the test side while the source
    /// side stays whatever it was — this must not be classifiable as a real
    /// outcome just because the test-side evidence looks proven.
    @Test("Conflicting source and test activation evidence is rejected")
    func conflictingActivationEvidenceIsRejected() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(makeEvidence(buildProductHash: "h0", activation: unprovenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h0", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .passed),
                    applicationEvidence: .isolated(.buildProductDiffersFromBaseline(mutantHash: "forged", baselineHash: "h0"))
                )
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    @Test("Activation evidence whose embedded hash disagrees with the observed build is rejected")
    func activationEvidenceHashDisagreesWithBuild() throws {
        // Both copies of applicationEvidence agree with each other (so the
        // cross-copy check alone would not catch this), but the mutant hash
        // they both claim does not match what the build actually produced.
        let forgedActivation: ActivationEvidence = .buildProductDiffersFromBaseline(mutantHash: "forged", baselineHash: "h0")
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: forgedActivation)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(forgedActivation))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    /// `.buildProductDiffersFromBaseline` with an identical (or empty)
    /// mutant/baseline hash pair is self-contradictory — the case claims
    /// the build differs from baseline while its own payload says
    /// otherwise. Both copies of applicationEvidence and the build hash all
    /// agree with each other here (so none of the cross-copy checks alone
    /// catch it); only `ActivationEvidence.provesActivation` itself
    /// validating the hash pair closes this.
    @Test("A self-contradictory activation hash pair (same-hash claiming 'differs') is rejected")
    func selfContradictoryActivationHashIsRejected() throws {
        let forged: ActivationEvidence = .buildProductDiffersFromBaseline(mutantHash: "same-hash", baselineHash: "same-hash")
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(makeEvidence(buildProductHash: "same-hash", activation: forged)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "same-hash", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(forged))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    // MARK: - Coverage fast path

    @Test("noCoverage fast path: applied, no build, coverage says uncovered")
    func noCoverageFastPath() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: nil, activation: nil)),
                coverage: CoverageObservation(mutatedLineWasExecuted: false, source: "swift-package-codecov")
            )
        }
        #expect(record.outcome == .noCoverage)
        guard case let .noCoverage(proof) = record.proof else { Issue.record("expected .noCoverage"); return }
        #expect(proof.coverageSource == "swift-package-codecov")
    }

    // MARK: - Build outcomes

    @Test("unviable when the build fails to compile")
    func buildCompileFailure() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .failed(kind: .compilationError, diagnosis: "syntax error", command: nil))
            )
        }
        #expect(record.outcome == .unviable)
    }

    @Test("infrastructureFailure when the build fails for infrastructure reasons")
    func buildInfrastructureFailureKind() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .failed(kind: .infrastructure, diagnosis: "disk full", command: nil))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("timedOut when the build itself times out")
    func buildFailureTimedOut() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .failed(kind: .timedOut, diagnosis: "build hung", command: nil))
            )
        }
        #expect(record.outcome == .timedOut)
    }

    @Test("infrastructureFailure when the build could not even run")
    func buildInfrastructureFailureOutcome() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .infrastructureFailure(diagnosis: "launch failed"))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("infrastructureFailure when the build succeeded but no test observation exists")
    func buildSucceededNoTest() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    // MARK: - Isolated mode: failed/crashed/timedOut

    @Test("killedByAssertion: failed with proven activation")
    func isolatedKilledByAssertion() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("infrastructureFailure: failed but activation unproven")
    func isolatedFailedUnproven() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h0", activation: unprovenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h0", command: nil)),
                test: SingleTestObservation(run: run(status: .failed), applicationEvidence: .isolated(unprovenIsolated))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("infrastructureFailure: failed with no application evidence at all")
    func isolatedFailedNoEvidence() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: nil, activation: nil)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: nil, command: nil)),
                test: SingleTestObservation(run: run(status: .failed), applicationEvidence: nil)
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("killedByCrash: crashed with proven activation")
    func isolatedKilledByCrash() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .killedByCrash)
    }

    @Test("timedOut: initial timeout, unconfirmed")
    func isolatedTimedOutUnconfirmed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .timedOut)
    }

    /// Round-2 review M1: unlike `.failed`/`.crashed`/`.passed` (see
    /// `isolatedFailedUnproven` above), `.timedOut` is never routed through
    /// `unprovenActivation` — `classify` reports a hang as `.timedOut`
    /// regardless of whether activation is proven. This is the fact
    /// `MutationRunner.prepare`'s short-circuit comment now describes: had
    /// the short-circuit not existed, a hash-identical (unproven-activation)
    /// mutant whose tests hung would have surfaced here as `.timedOut`, not
    /// `.infrastructureFailure` — a materially different verdict from every
    /// other unproven-activation test outcome.
    @Test("timedOut is NOT downgraded to infrastructureFailure when activation is unproven, unlike failed/crashed/passed")
    func isolatedTimedOutUnprovenIsNotDowngraded() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h0", activation: unprovenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h0", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(unprovenIsolated))
            )
        }
        #expect(record.outcome == .timedOut)
    }

    @Test("infrastructureFailure: the test run itself could not produce a verdict")
    func isolatedTestInfrastructureFailure() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .infrastructureFailure), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    // MARK: - Isolated mode: passing

    @Test("noCoverage: passed but coverage says the line was never executed")
    func isolatedNoCoverage() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                coverage: CoverageObservation(mutatedLineWasExecuted: false, source: "xccov"),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .noCoverage)
    }

    @Test("infrastructureFailure: passed with no product hash at all")
    func isolatedPassedNoProductHash() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: nil)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: nil, command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: nil)
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("infrastructureFailure: passed, activation unproven (build identical to baseline) — not scored, not cached")
    func isolatedPassedUnprovenIsInfrastructureFailure() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h0", activation: unprovenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h0", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(unprovenIsolated))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    @Test("survived: passed with proven activation")
    func isolatedSurvivedProven() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .survived)
    }

    // MARK: - Confirmation: kill

    @Test("confirmKill: confirmed, exact failing-test-set match")
    func confirmKillConfirmed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed, summary: makeTestSummary(failed: 1)), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    originalFailingTests: ["ExampleTests/testSomething()"]
                )]
            )
        }
        #expect(record.outcome == .killedByAssertion)
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
                test: SingleTestObservation(run: run(status: .failed, summary: primaryFailure), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: primaryFailure),
                    // Forged: claims a completely different test than the
                    // primary run's own summary actually recorded.
                    originalFailingTests: ["ForgedTests/testForged()"]
                )]
            )
        }
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("confirmKill: confirmation's originalFailingTests matches, but the real primary run failed a different test — flaky, not confirmed")
    func confirmKillRealPrimaryDisagreesWithForgedField() throws {
        let primaryFailure = TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["RealTests/testReal()"], durationSeconds: nil)
        let confirmingFailure = TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["OtherTests/testOther()"], durationSeconds: nil)
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed, summary: primaryFailure), applicationEvidence: .isolated(provenIsolated)),
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
    }

    @Test("confirmKill: retest passed instead — flaky")
    func confirmKillRetestPassed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .kill, run: run(status: .passed), originalFailingTests: ["A"])]
            )
        }
        #expect(record.outcome == .flaky)
    }

    @Test("confirmKill: retest failed a different test — flaky")
    func confirmKillDifferentTest() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: TestOutcomeSummary(total: 4, passed: 3, failed: 1, failingTests: ["B"], durationSeconds: nil)),
                    originalFailingTests: ["A"]
                )]
            )
        }
        #expect(record.outcome == .flaky)
    }

    @Test("confirmKill: no per-test breakdown on either side — flaky, not trusted")
    func confirmKillNoBreakdown() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .kill, run: run(status: .failed), originalFailingTests: nil)]
            )
        }
        #expect(record.outcome == .flaky)
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
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    // MARK: - Confirmation: crash

    @Test("confirmCrash: confirmed, identical diagnosis")
    func confirmCrashConfirmed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .crash, run: run(status: .crashed), originalDiagnosis: "diag:crashed")]
            )
        }
        #expect(record.outcome == .killedByCrash)
    }

    /// `ConfirmationObservation.originalDiagnosis` is a caller-supplied
    /// duplicate of the primary run's own diagnosis, decoded as untrusted —
    /// see `confirmKillIgnoresForgedOriginalFailingTests`'s doc comment for
    /// the same reasoning applied to crash confirmation.
    @Test("confirmCrash: a forged originalDiagnosis field is ignored — the primary run's own diagnosis decides")
    func confirmCrashIgnoresForgedOriginalDiagnosis() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                // The real primary run's diagnosis is "diag:crashed" (see run(status:)).
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .crash, run: run(status: .crashed),
                    // Forged: does not match the primary run's real diagnosis.
                    originalDiagnosis: "a completely fabricated crash reason"
                )]
            )
        }
        #expect(record.outcome == .killedByCrash)
    }

    @Test("confirmCrash: different diagnosis — flaky")
    func confirmCrashDifferentDiagnosis() throws {
        let differentCrash = TestRunResult(
            status: .crashed, summary: nil,
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "a totally different crash", isBatchAttributedTimeout: false
        )
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .crash, run: differentCrash, originalDiagnosis: "diag:crashed")]
            )
        }
        #expect(record.outcome == .flaky)
    }

    @Test("confirmCrash: rebuild did not crash at all — flaky")
    func confirmCrashDidNotReproduce() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .crash, run: run(status: .passed), originalDiagnosis: "diag:crashed")]
            )
        }
        #expect(record.outcome == .flaky)
    }

    /// Unlike the primary path's `SingleTestObservation.applicationEvidence`
    /// (cross-checked against an independently-observed `BuildObservation`
    /// by `executionEvidenceProblem`), a timeout confirmation's `activation`
    /// had no equivalent tie to a build the confirmation's own rebuild
    /// actually produced — only its own internal hash consistency
    /// (non-empty, distinct) was checked. A forged `activation` naming a
    /// self-consistent hash pair that never came from any real build must
    /// still be rejected.
    @Test("confirmTimeout: activation naming hashes that never came from the confirming rebuild's own build is rejected")
    func confirmTimeoutActivationNotTiedToConfirmingBuildIsRejected() throws {
        let forgedActivation: ActivationEvidence = .buildProductDiffersFromBaseline(mutantHash: "forged-mutant", baselineHash: "forged-baseline")
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .timeout, run: run(status: .timedOut), activation: forgedActivation,
                    // The confirming rebuild's real product hash disagrees
                    // with what the forged activation claims.
                    confirmingBuildProductHash: "h1"
                )]
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    // MARK: - Confirmation: timeout

    /// `ConfirmationObservation.wasBatchAttributed` is a caller-supplied
    /// duplicate of the primary run's own `isBatchAttributedTimeout`,
    /// decoded as untrusted — see `confirmTimeout`'s doc comment. A forged
    /// `true` on an individually-observed (not batch-attributed) timeout
    /// must not be able to trust a plain failed retest as a kill; it must
    /// fall back to the individually-observed disagreement path, which is
    /// always `.flaky`.
    @Test("confirmTimeout: a forged batch-attribution flag cannot promote an individually-observed timeout")
    func forgedBatchAttributionIsIgnored() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut, isBatchAttributedTimeout: false), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .timeout, run: run(status: .failed), activation: provenIsolated, confirmingBuildProductHash: "h1",
                    // Forged: the primary run above was not batch-attributed.
                    wasBatchAttributed: true
                )]
            )
        }
        #expect(record.outcome == .flaky)
        #expect(!record.outcome.isScorable)
    }

    @Test("confirmTimeout: confirmed with proven activation")
    func confirmTimeoutConfirmed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .timedOut), activation: provenIsolated, confirmingBuildProductHash: "h1")]
            )
        }
        #expect(record.outcome == .verifiedTimeout)
    }

    @Test("confirmTimeout: confirmed but activation unproven")
    func confirmTimeoutConfirmedUnproven() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .timedOut), activation: unprovenIsolated, confirmingBuildProductHash: "h0")]
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("confirmTimeout: rebuild itself could not execute")
    func confirmTimeoutRebuildInfrastructureFailure() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .infrastructureFailure))]
            )
        }
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("confirmTimeout: not batch-attributed, rebuild passed instead — flaky")
    func confirmTimeoutIndividualNotConfirmed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .passed), activation: provenIsolated, confirmingBuildProductHash: "h1", wasBatchAttributed: false)]
            )
        }
        #expect(record.outcome == .flaky)
    }

    @Test("confirmTimeout: batch-attributed, rebuild passed — trusted as survived")
    func confirmTimeoutBatchAttributedPassed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut, isBatchAttributedTimeout: true), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .passed), activation: provenIsolated, confirmingBuildProductHash: "h1", wasBatchAttributed: true)]
            )
        }
        #expect(record.outcome == .survived)
    }

    @Test("confirmTimeout: batch-attributed, rebuild failed — trusted as killedByAssertion")
    func confirmTimeoutBatchAttributedFailed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut, isBatchAttributedTimeout: true), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .failed), activation: provenIsolated, confirmingBuildProductHash: "h1", wasBatchAttributed: true)]
            )
        }
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("confirmTimeout: batch-attributed, rebuild crashed — trusted as killedByCrash")
    func confirmTimeoutBatchAttributedCrashed() throws {
        let record = try verify { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .timedOut, isBatchAttributedTimeout: true), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .timeout, run: run(status: .crashed), activation: provenIsolated, confirmingBuildProductHash: "h1", wasBatchAttributed: true)]
            )
        }
        #expect(record.outcome == .killedByCrash)
    }

    // MARK: - Confirmation policy

    /// `verify(_:)` alone cannot distinguish "this run's own configuration
    /// never required a confirmation" from "an untrusted envelope had its
    /// confirmations stripped" — both leave `obs.confirmations` empty. The
    /// caller-supplied policy is what lets the verifier tell them apart: a
    /// primary kill/crash reached while the matching policy flag is on, but
    /// carrying none of the confirmation it promises, must not be trusted.
    @Test("A primary killedByAssertion with retestKilledMutants on but no .kill confirmation is rejected")
    func primaryKillWithoutRequiredConfirmationIsRejected() throws {
        let record = try verify(policy: .init(retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false)) { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed, summary: makeTestSummary(failed: 1)), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    @Test("A primary killedByAssertion with retestKilledMutants on and a real .kill confirmation is accepted")
    func primaryKillWithRequiredConfirmationIsAccepted() throws {
        let record = try verify(policy: .init(retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false)) { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed, summary: makeTestSummary(failed: 1)), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(
                    kind: .kill, run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    originalFailingTests: ["ExampleTests/testSomething()"]
                )]
            )
        }
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("retestKilledMutants off does not require a .kill confirmation")
    func retestKilledMutantsOffDoesNotRequireConfirmation() throws {
        let record = try verify(policy: .init(retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false)) { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .failed, summary: makeTestSummary(failed: 1)), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("A primary killedByCrash with confirmCrashKills on but no .crash confirmation is rejected")
    func primaryCrashWithoutRequiredConfirmationIsRejected() throws {
        let record = try verify(policy: .init(retestKilledMutants: false, confirmCrashKills: true, confirmTimedOutMutants: false)) { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated))
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    @Test("A primary killedByCrash with confirmCrashKills on and a real .crash confirmation is accepted")
    func primaryCrashWithRequiredConfirmationIsAccepted() throws {
        let record = try verify(policy: .init(retestKilledMutants: false, confirmCrashKills: true, confirmTimedOutMutants: false)) { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed), applicationEvidence: .isolated(provenIsolated)),
                confirmations: [ConfirmationObservation(kind: .crash, run: run(status: .crashed), originalDiagnosis: "diag:crashed")]
            )
        }
        #expect(record.outcome == .killedByCrash)
    }

    /// The cascade case: a batch-attributed timeout confirmed as a kill
    /// (via `trustedTimeoutOutcome`) still needs its own `.kill`
    /// confirmation when `retestKilledMutants` is on — the same as any
    /// other first-observed kill. `MutationRunner.confirmTimeout` appends
    /// this second confirmation itself; stripping it from an untrusted
    /// envelope must not let the cascade's kill through unconfirmed.
    @Test("A batch-timeout-cascaded kill with retestKilledMutants on but no second .kill confirmation is rejected")
    func cascadedKillWithoutRequiredSecondConfirmationIsRejected() throws {
        let record = try verify(policy: .init(retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: true)) { ref in
            MutationObservations(
                plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(
                    run: run(status: .timedOut, isBatchAttributedTimeout: true), applicationEvidence: .isolated(provenIsolated)
                ),
                confirmations: [ConfirmationObservation(
                    kind: .timeout, run: run(status: .failed, summary: makeTestSummary(failed: 1)),
                    activation: provenIsolated, confirmingBuildProductHash: "h1", wasBatchAttributed: true
                )]
            )
        }
        #expect(record.outcome == .infrastructureFailure)
        #expect(!record.outcome.isScorable)
        #expect(!record.outcome.isCacheableResult)
    }

    // MARK: - mutationRef / verificationVersion

    @Test("The verified record's mutationRef is the observation's plannedMutation, unchanged")
    func mutationRefPassesThrough() throws {
        let point = try makeAnchoredPoint()
        let expectedRef = ref(for: point)
        let record = MutationVerdictVerifier.verify(
            MutationObservations(
                plannedMutation: expectedRef, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: provenIsolated)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .passed), applicationEvidence: .isolated(provenIsolated))
            ),
            policy: .permissive
        )
        #expect(record.mutationRef == expectedRef)
        #expect(record.verificationVersion == MutationVerdictVerifier.currentVersion)
    }
}
