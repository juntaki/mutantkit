import Foundation
import MutationModel
import Testing

/// The integrity checker is the only thing between a plausible-looking report
/// and a wrong one. Every test here describes a way a run can be broken while
/// still looking finished, and asserts that the tool refuses to publish a score
/// for it.
@Suite("Integrity checker")
struct IntegrityCheckerTests {
    // MARK: - Phantom mutants

    /// ADR-0006 Stage 1: "a result with no/hollow evidence is a phantom" used
    /// to be a runtime check here. It is now a compile-time impossibility
    /// instead: `MutationVerdictVerifier` is the only place a
    /// `VerifiedMutationRecord` is built, `ExecutedMutationProof` requires
    /// real, non-optional evidence, and the only caller of `.applied(...)`
    /// is the real `MutationApplication.apply` — there is no path left that
    /// reaches a `.survived`/`.killed*` outcome with no, or hollow, evidence.
    /// See `IntegrityChecker.check`'s own doc comment.

    /// `notApplied` means the anchor did not match and no edit was made. It is
    /// the outcome that must never be laundered into `survived`, so it is loud by
    /// construction: always flagged, never scored.
    @Test("A notApplied result is always flagged and never scored as survived")
    func notAppliedIsAlwaysFlagged() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [
            makeResult(
                point: point,
                outcome: .notApplied,
                evidence: nil,
                testSummary: nil,
                diagnosis: "Anchor rejected: the file changed since planning."
            )
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.violations.kinds == [.phantomMutant])
        #expect(!report.passed)
        #expect(makeReport(plan: plan, results: results).score == nil)

        // And it never reaches a denominator even if a score were computed.
        let score = MutationScore.tally([.notApplied])
        #expect(score.survived == 0)
        #expect(score.killed == 0)
        #expect(score.excluded["notApplied"] == 1)
        #expect(score.tested == nil)
    }

    @Test("notApplied is flagged even when the run otherwise looks healthy")
    func notAppliedIsFlaggedAmongPassingResults() throws {
        let good = try makeAnchoredPoint(file: "Sources/A.swift")
        let bad = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [good, bad])
        let results = [
            makeResult(point: good, outcome: .killedByAssertion),
            makeResult(point: bad, outcome: .notApplied, evidence: nil, testSummary: nil)
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.violations.kinds == [.phantomMutant])
        #expect(report.violations.first?.mutationID == bad.id)
        #expect(makeReport(plan: plan, results: results).score == nil)
    }

    // MARK: - Baseline

    /// If the unmutated suite is not green, "survived" means nothing: the tests
    /// were not passing to begin with, so their failure to catch a mutant is not
    /// information about the mutant.
    @Test("A failed baseline blocks the score")
    func failedBaselineBlocksTheScore() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [makeResult(point: point, outcome: .killedByAssertion)]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: false)

        #expect(report.violations.kinds == [.baselineMismatch])
        #expect(!report.passed)
        #expect(makeReport(plan: plan, results: results, baselinePassed: false).score == nil)

        // The same run with a green baseline is clean — proving the baseline is
        // what made the difference.
        #expect(IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true).passed)
    }

    // MARK: - Activation

    /// ADR-0006 Stage 1: `.mutationNotActivated` used to be a runtime check
    /// here (an unproven-activation result would still reach `check` and
    /// get flagged after the fact). `MutationVerdictVerifier.classify`'s own
    /// `unprovenActivation` gate now refuses to produce a scorable outcome
    /// from unproven activation evidence in the first place — see
    /// `IntegrityChecker.check`'s doc comment on why this is no longer
    /// re-checked here.

    /// ADR-0005 PR D: `.noCoverage` is `isScorable`, but by design it is
    /// reached without ever building — this is the real shape the coverage
    /// fast path (`MutationRunner.prepare`) actually produces:
    /// `applicationEvidence: nil` because no build ever ran, not because
    /// activation was disproven. Before this stage, this exact shape was
    /// flagged as `.mutationNotActivated` on *every* `.noCoverage` result,
    /// which is why `SwiftPackageMacOSCoverageAcceptanceTests`'s "Integrity
    /// reconciles across the coverage fast path" and "Effective score is
    /// stable" acceptance tests failed until now.
    @Test("A noCoverage result with no activation evidence is not flagged — it never built by design")
    func noCoverageWithoutActivationEvidenceIsNotFlagged() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [
            makeResult(
                point: point,
                outcome: .noCoverage,
                evidence: makeEvidence(buildProductHash: nil, activation: nil),
                testSummary: nil
            )
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.violations.isEmpty)
        #expect(makeReport(plan: plan, results: results).score != nil)
    }

    @Test("A mutant whose binary differs from the baseline is scorable")
    func activatedMutationIsClean() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [
            makeResult(
                point: point,
                outcome: .survived,
                evidence: makeEvidence(activation: .buildProductDiffersFromBaseline(
                    mutantHash: ContentHash.of("mutant"),
                    baselineHash: ContentHash.of("baseline")
                ))
            )
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.passed)
        #expect(makeReport(plan: plan, results: results).score?.survived == 1)
    }

    @Test("Activation evidence knows what it does and does not prove")
    func activationEvidenceSemantics() {
        #expect(ActivationEvidence.buildProductDiffersFromBaseline(mutantHash: "a", baselineHash: "b")
            .provesActivation)
        #expect(!ActivationEvidence.buildProductIdenticalToBaseline(hash: "a").provesActivation)
    }

    /// `.buildProductDiffersFromBaseline` is decoded as untrusted input by
    /// the cache/checkpoint reverify path — a hand-edited entry could claim
    /// "differs from baseline" while supplying hashes that don't actually
    /// differ (or are empty). The case tag alone must not be trusted.
    @Test("A self-contradictory buildProductDiffersFromBaseline does not prove activation")
    func selfContradictoryActivationDoesNotProve() {
        #expect(!ActivationEvidence.buildProductDiffersFromBaseline(mutantHash: "same", baselineHash: "same").provesActivation)
        #expect(!ActivationEvidence.buildProductDiffersFromBaseline(mutantHash: "", baselineHash: "b").provesActivation)
        #expect(!ActivationEvidence.buildProductDiffersFromBaseline(mutantHash: "a", baselineHash: "").provesActivation)
    }

    // MARK: - Reconciliation

    /// A planned mutation that silently vanished is the failure this tool refuses
    /// to tolerate: the report would simply be missing a mutant, and nothing in
    /// the numbers would say so.
    @Test("A planned mutation with no result is flagged")
    func plannedMutationWithoutResultIsFlagged() throws {
        let ran = try makeAnchoredPoint(file: "Sources/A.swift")
        let vanished = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [ran, vanished])
        let results = [makeResult(point: ran, outcome: .killedByAssertion)]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.violations.kinds == [.plannedMutationWithoutResult])
        #expect(report.violations.first?.mutationID == vanished.id)
        #expect(makeReport(plan: plan, results: results).score == nil)
    }

    @Test("A result for a mutation that was never planned is flagged")
    func resultWithoutPlannedMutationIsFlagged() throws {
        let planned = try makeAnchoredPoint(file: "Sources/A.swift")
        let stranger = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [planned])
        let results = [
            makeResult(point: planned, outcome: .killedByAssertion),
            makeResult(point: stranger, outcome: .survived)
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.violations.kinds == [.resultWithoutPlannedMutation])
        #expect(report.violations.first?.mutationID == stranger.id)
        #expect(makeReport(plan: plan, results: results).score == nil)
    }

    @Test("Duplicate IDs in a plan are flagged")
    func duplicateIDsAreFlagged() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point, point])

        let violations = IntegrityChecker.validatePlan(plan)

        #expect(violations.kinds == [.duplicateMutationID])
        #expect(violations.first?.mutationID == point.id)
    }

    @Test("A skipped mutation accounts for itself instead of vanishing")
    func skippedMutationsReconcile() throws {
        let ran = try makeAnchoredPoint(file: "Sources/A.swift")
        let skipped = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(
            mutations: [ran],
            skipped: [SkippedMutation(id: skipped.id, file: skipped.file, reason: .budgetExceeded)]
        )
        let results = [makeResult(point: ran, outcome: .killedByAssertion)]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.passed)
        #expect(report.planned == 1)
        #expect(report.explicitlySkipped == 1)
        #expect(report.discovered == 2)
    }

    // MARK: - Counts

    @Test("The report counts every stage of the pipeline")
    func stageCountsAreReconciled() throws {
        let killed = try makeAnchoredPoint(file: "Sources/A.swift")
        let survived = try makeAnchoredPoint(file: "Sources/B.swift")
        let unviable = try makeAnchoredPoint(file: "Sources/C.swift")
        let plan = makePlan(mutations: [killed, survived, unviable])
        let results = [
            makeResult(point: killed, outcome: .killedByAssertion),
            makeResult(point: survived, outcome: .survived),
            // A mutant that did not compile has a source diff but no binary and
            // no test run.
            makeResult(
                point: unviable,
                outcome: .unviable,
                evidence: makeEvidence(buildProductHash: nil),
                testSummary: nil
            )
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.passed)
        #expect(report.planned == 3)
        #expect(report.discovered == 3)
        #expect(report.classified == 3)
        #expect(report.sourceApplied == 3)
        #expect(report.buildObserved == 2)
        #expect(report.buildFailures == 1)
        #expect(report.executed == 2)
        #expect(report.reported == 3)
    }

    /// Serial SwiftPM test execution can reach a real, test-backed outcome
    /// without producing a per-test summary — `executed` must still count it,
    /// or a mutant that genuinely ran would be reported as if it never did.
    @Test("A test-backed outcome with no testSummary still counts as executed")
    func outcomeWithoutSummaryStillCountsAsExecuted() throws {
        let killedNoSummary = try makeAnchoredPoint(file: "Sources/A.swift")
        let noCoverage = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [killedNoSummary, noCoverage])
        let results = [
            makeResult(point: killedNoSummary, outcome: .killedByAssertion, testSummary: nil),
            // No coverage means no test ran at all — must NOT count as executed
            // just because the outcome check runs after the summary check.
            makeResult(point: noCoverage, outcome: .noCoverage, testSummary: nil)
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.executed == 1)
    }

    /// A flat `explicitlySkipped` count cannot distinguish "budget cut this
    /// sampled run off deliberately" from "an operator was disabled" — a
    /// stratified 50-out-of-890 run has to be able to show that every one of
    /// its skips was the budget doing its job, not something silently wrong.
    @Test("Skipped mutations are tallied by reason")
    func skippedMutationsAreTalliedByReason() throws {
        let ran = try makeAnchoredPoint(file: "Sources/A.swift")
        let budgetSkipped1 = try makeAnchoredPoint(file: "Sources/B.swift")
        let budgetSkipped2 = try makeAnchoredPoint(file: "Sources/C.swift")
        let disabledSkipped = try makeAnchoredPoint(file: "Sources/D.swift")
        let plan = makePlan(
            mutations: [ran],
            skipped: [
                SkippedMutation(id: budgetSkipped1.id, file: budgetSkipped1.file, reason: .budgetExceeded),
                SkippedMutation(id: budgetSkipped2.id, file: budgetSkipped2.file, reason: .budgetExceeded),
                SkippedMutation(id: disabledSkipped.id, file: disabledSkipped.file, reason: .operatorDisabled)
            ]
        )
        let results = [makeResult(point: ran, outcome: .killedByAssertion)]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.explicitlySkipped == 3)
        #expect(report.skippedByReason == [
            SkipReasonCount(reason: .budgetExceeded, count: 2),
            SkipReasonCount(reason: .operatorDisabled, count: 1)
        ])
        // Sums back to the flat count — the breakdown can never disagree
        // with the total it's a breakdown of.
        #expect(report.skippedByReason.map(\.count).reduce(0, +) == report.explicitlySkipped)
    }

    @Test("A clean run passes and produces a score")
    func cleanRunIsScored() throws {
        let killed = try makeAnchoredPoint(file: "Sources/A.swift")
        let survived = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [killed, survived])
        let results = [
            makeResult(point: killed, outcome: .killedByAssertion),
            makeResult(point: survived, outcome: .survived)
        ]

        let report = makeReport(plan: plan, results: results)

        #expect(report.integrity.passed)
        #expect(report.score?.killed == 1)
        #expect(report.score?.survived == 1)
        #expect(report.score?.tested == 0.5)
    }

    @Test("Results are reported in a deterministic order")
    func resultsAreSortedByID() throws {
        let a = try makeAnchoredPoint(file: "Sources/A.swift")
        let b = try makeAnchoredPoint(file: "Sources/B.swift")
        let c = try makeAnchoredPoint(file: "Sources/C.swift")
        let plan = makePlan(mutations: [a, b, c])

        let forward = makeReport(plan: plan, results: [a, b, c].map { makeResult(point: $0, outcome: .survived) })
        let reversed = makeReport(plan: plan, results: [c, b, a].map { makeResult(point: $0, outcome: .survived) })

        #expect(forward.results.map(\.id) == reversed.results.map(\.id))
        #expect(forward.results.map(\.id) == forward.results.map(\.id).sorted())
    }
}
