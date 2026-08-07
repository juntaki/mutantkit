import Foundation
import MutationModel
import Testing

/// The schemata counterpart to `IntegrityCheckerTests`'s activation-evidence
/// tests: `MutationEvidence.applicationEvidence` can also be a `.schemata`
/// case, and the same "no proof, no score" discipline must apply — enforced
/// by `MutationVerdictVerifier.verifySchemataChain` at classification time
/// (ADR-0006 Stage 2), not re-derived here. Split into its own file rather
/// than folded into `IntegrityCheckerTests` to keep that file under
/// SwiftLint's `type_body_length` cap.
@Suite("Integrity checker: schemata evidence")
struct SchemataIntegrityCheckerTests {
    /// ADR-0006 Stage 1: this used to be a runtime `IntegrityChecker` check
    /// (inconsistent schemata evidence on a scorable outcome, flagged after
    /// the fact). `MutationVerdictVerifier.classify`'s `unprovenActivation`
    /// gate now refuses to produce a scorable outcome from schemata
    /// evidence whose chain does not verify in the first place — see
    /// `IntegrityCheckerTests`'s equivalent isolated-mode note.

    @Test("A scorable result with a real, provable schemata observation is scorable")
    func consistentSchemataEvidenceIsClean() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [
            makeResult(
                point: point,
                outcome: .survived,
                evidence: MutationEvidence(
                    sourceBeforeHash: ContentHash.of("before"),
                    sourceAfterHash: ContentHash.of("after"),
                    sourceDiff: "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-true\n+false\n",
                    applicationEvidence: .schemata(makeConsistentSchemataObservation())
                )
            )
        ]

        let report = IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)

        #expect(report.passed)
        #expect(makeReport(plan: plan, results: results).score?.survived == 1)
    }
}
