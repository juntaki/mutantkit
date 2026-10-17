@testable import CLI
import Foundation
@testable import MutationModel
@testable import Reporting
import Testing

/// Killing-test tally, suspect-test warnings and the Tier A / Tier B
/// completeness fields. Synthetic reports only.
@Suite("Killing tests and evidence semantics")
struct KillingTestsReportTests {
    private var proven: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }

    private func kill(file: String, failing: [String]) throws -> MutationResult {
        let point = try makeAnchoredPoint(file: file)
        let evidence = makeEvidence(activation: proven).withAssertionKillAttribution(
            .evaluate(execution: nil, failingTests: failing)
        )
        return makeResult(point: point, outcome: .killedByAssertion, evidence: evidence)
    }

    @Test("Counts mutants and files per failing test, top-N ordered")
    func tally() throws {
        let results = try [
            kill(file: "Sources/A.swift", failing: ["T/a", "T/b"]),
            kill(file: "Sources/B.swift", failing: ["T/a"])
        ]
        let rows = try #require(TrustReport.killingTests(for: results)).top
        #expect(rows.map(\.test) == ["T/a", "T/b"])
        #expect(rows[0].mutantCount == 2)
        #expect(rows[0].fileCount == 2)
        #expect(rows[0].soleFailingCount == 1)
        #expect(rows[0].shareOfKills == 1.0)
        #expect(rows[1].mutantCount == 1)
    }

    @Test("A broad-failing test gets the diagnostic warning and no verdict changes")
    func suspectIsDiagnosticOnly() throws {
        let count = TrustReport.KillingTestThresholds.suspectMinMutants
        var results: [MutationResult] = []
        for i in 0 ..< max(count, TrustReport.KillingTestThresholds.suspectMinFiles) {
            results.append(try kill(file: "Sources/F\(i).swift", failing: ["Broad/test", "Narrow/t\(i)"]))
        }
        let plan = makePlan(mutations: results.map(\.point))
        let report = makeReport(plan: plan, results: results)
        let section = try #require(TrustReport.build(from: report).killEvidence)
        let suspects = try #require(section.suspectTests)
        #expect(suspects.map(\.test.test) == ["Broad/test"])
        #expect(suspects[0].warning == "broad-failing/suspect test — confirm with the baseline control")
        #expect(results.allSatisfy { $0.outcome == .killedByAssertion })
        #expect(section.assertionKills == results.count)
    }

    @Test("Few kills produce no suspect and an old killEvidence JSON still decodes")
    func belowThresholdAndOldJSON() throws {
        let results = try [kill(file: "Sources/A.swift", failing: ["T/a"])]
        let section = try #require(TrustReport.killEvidenceSection(for: results))
        #expect(section.suspectTests == nil)

        let old = """
        {"assertionKills":1,"withinSelection":1,"wholeSuiteRan":0,"failingTestsUnnamed":0,\
        "attributionNotRecorded":0,"batchAttributed":0,"cascadeConfirmations":0}
        """
        let decoded = try JSONDecoder().decode(TrustReport.KillEvidenceSection.self, from: Data(old.utf8))
        #expect(decoded.killingTests == nil)
        #expect(decoded.suspectTests == nil)
    }

    @Test("verify-run: tierAComplete mirrors complete, fullEvidenceReverified is separate, strategy is carried")
    func completenessFields() throws {
        let checks = [
            ReverificationCheck(name: "a", status: .pass, detail: ""),
            ReverificationCheck(name: "b", status: .notVerifiable, detail: "")
        ]
        let strategy = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 0, fallbackCount: 3, plannerFallbackReasonCounts: ["unsupportedOperand": 3]
        )
        let result = VerifyRunResult(
            planID: "p", resultCount: 1, planSupplied: true, verifierVersion: 1, checks: checks, executionStrategy: strategy
        )
        #expect(result.passed)
        #expect(!result.complete)
        #expect(result.tierAComplete == false)
        #expect(result.fullEvidenceReverified == false)
        #expect(result.executionStrategy?.plannerFallbackReasonCounts == ["unsupportedOperand": 3])

        let tierB = TierBSummary(
            runID: "r", reverifiedCount: 1, matchedCount: 1, mismatchedCount: 0, notVerifiableCount: 0,
            archiveProblemCount: 0, recordedVerifierVersion: 1, currentVerifierVersion: 1,
            policy: .init(retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false)
        )
        let full = VerifyRunResult(
            planID: "p", resultCount: 1, planSupplied: true, verifierVersion: 1, checks: checks, tierB: tierB
        )
        #expect(full.complete == false)
        #expect(full.tierAComplete == false)
        #expect(full.fullEvidenceReverified == true)
    }

    /// The review finding: with an evidence archive the Tier B checks join `checks`, and `complete` covers
    /// them. `tierAComplete` must not: it is the report-only checks alone.
    @Test("tierAComplete ignores the archive-derived (Tier B) checks that complete includes")
    func tierAIsIndependentOfTierBChecks() {
        let tierA = [
            ReverificationCheck(name: "plan.identity", status: .pass, detail: ""),
            ReverificationCheck(name: "score.recompute", status: .pass, detail: "")
        ]
        let tierBNotVerifiable = ReverificationCheck(name: "tierB.reverified", status: .notVerifiable, detail: "")
        let withArchive = ReportReverification(checks: tierA + [tierBNotVerifiable], tierACheckCount: tierA.count)
        #expect(withArchive.tierAComplete)
        #expect(!withArchive.complete)

        let tierANotVerifiable = ReverificationCheck(name: "evidence.activation", status: .notVerifiable, detail: "")
        let partialA = ReportReverification(
            checks: tierA + [tierANotVerifiable] + [ReverificationCheck(name: "tierB.x", status: .pass, detail: "")],
            tierACheckCount: tierA.count + 1
        )
        #expect(!partialA.tierAComplete)

        // Callers that never ran Tier B keep the old meaning: every check is Tier A.
        #expect(ReportReverification(checks: tierA + [tierANotVerifiable]).tierAComplete == false)
        #expect(ReportReverification(checks: tierA).tierAComplete)
    }
}
