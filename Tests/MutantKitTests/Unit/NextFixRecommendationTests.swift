import Foundation
import MutationModel
import Reporting
import Testing

@Suite("NextFixRecommendation")
struct NextFixRecommendationTests {
    /// A fixture entry with every ranking-relevant field overridable and
    /// everything else defaulted to a plausible, self-consistent value —
    /// so each test can vary exactly the one criterion it is about.
    private func makeEntry(
        mutantID: String = "mut_0000000000000001",
        outcome: MutationOutcome = .survived,
        confidence: TestObligation.Confidence = .high,
        testsRun: Int? = 10,
        clusterSize: Int = 1
    ) -> MutantFixPlanEntry {
        MutantFixPlanEntry(
            facts: MutantFixPlanEntry.Facts(
                mutantID: mutantID,
                operatorID: "swift.core.relational-operator-replacement",
                file: "Sources/Example.swift",
                line: 1,
                column: 1,
                declaration: "Example.check(x:)",
                original: ">",
                replacement: ">=",
                outcome: outcome,
                diagnosis: "test diagnosis",
                testsRun: testsRun,
                testsPassed: testsRun,
                testsFailed: 0,
                knownCoveringTests: nil,
                testScope: outcome == .noCoverage ? nil : .unknown,
                clusterSize: clusterSize,
                clusterMutantIDs: [mutantID]
            ),
            inference: MutantFixPlanEntry.Inference(kind: .relationalBoundary, confidence: confidence, rationale: "test rationale"),
            obligation: MutantFixPlanEntry.Obligation(description: "test obligation"),
            reproduceCommand: "mutantkit reproduce \(mutantID)"
        )
    }

    @Test("coveredButNotCaught (survived) ranks above noCoverage, regardless of every other factor")
    func survivedRanksAboveNoCoverage() {
        // The noCoverage entry is otherwise strictly "better" on every
        // later criterion (higher confidence is impossible to construct
        // here since noCoverage's own obligation is always .high per
        // TestObligationAnalyzer, so this alone isolates the first
        // criterion): fewer tests recorded and a larger cluster. It must
        // still rank second.
        let survived = makeEntry(mutantID: "mut_a", outcome: .survived, confidence: .medium, testsRun: 100, clusterSize: 1)
        let noCoverage = makeEntry(mutantID: "mut_b", outcome: .noCoverage, confidence: .high, testsRun: nil, clusterSize: 10)

        let ranked = NextFixRecommendation.rank([noCoverage, survived])
        #expect(ranked.map(\.facts.mutantID) == ["mut_a", "mut_b"])
    }

    @Test("Higher inference confidence ranks above lower, among entries with the same outcome")
    func higherConfidenceRanksFirst() {
        let high = makeEntry(mutantID: "mut_high", confidence: .high)
        let medium = makeEntry(mutantID: "mut_medium", confidence: .medium)
        let low = makeEntry(mutantID: "mut_low", confidence: .low)

        let ranked = NextFixRecommendation.rank([medium, low, high])
        #expect(ranked.map(\.facts.mutantID) == ["mut_high", "mut_medium", "mut_low"])
    }

    @Test("Fewer tests recorded in the deciding attempt ranks above more, and no recorded count ranks last")
    func fewerTestsRankFirst() {
        let few = makeEntry(mutantID: "mut_few", testsRun: 2)
        let many = makeEntry(mutantID: "mut_many", testsRun: 40)
        let unrecorded = makeEntry(mutantID: "mut_unrecorded", testsRun: nil)

        let ranked = NextFixRecommendation.rank([many, unrecorded, few])
        #expect(ranked.map(\.facts.mutantID) == ["mut_few", "mut_many", "mut_unrecorded"])
    }

    @Test("A larger cluster ranks above a smaller one, once outcome/confidence/scope tie")
    func largerClusterRanksFirst() {
        let small = makeEntry(mutantID: "mut_small", clusterSize: 1)
        let large = makeEntry(mutantID: "mut_large", clusterSize: 5)

        let ranked = NextFixRecommendation.rank([small, large])
        #expect(ranked.map(\.facts.mutantID) == ["mut_large", "mut_small"])
    }

    @Test("Ties break on mutant ID for a deterministic ordering")
    func tiesBreakOnMutantID() {
        let a = makeEntry(mutantID: "mut_aaaa")
        let b = makeEntry(mutantID: "mut_bbbb")

        let forward = NextFixRecommendation.rank([b, a])
        let reversed = NextFixRecommendation.rank([a, b])
        #expect(forward.map(\.facts.mutantID) == ["mut_aaaa", "mut_bbbb"])
        #expect(forward.map(\.facts.mutantID) == reversed.map(\.facts.mutantID))
    }

    @Test("build(from:) recommends nil with candidateCount 0 when there is nothing to fix")
    func noCandidatesProducesNilRecommendation() throws {
        let points = try discover("struct Example { func isReady() -> Bool { true } }", using: Operators.boolLiteral)
        let killed = points.map { makeResult(point: $0, outcome: .killedByAssertion) }
        let report = makeReport(plan: makePlan(mutations: points), results: killed)

        let next = NextFixRecommendation.build(from: report)
        #expect(next.candidateCount == 0)
        #expect(next.recommendation == nil)
        #expect(next.schemaVersion == SchemaVersion.nextFixRecommendation)
    }

    @Test("build(from:) recommends the single survivor when there is exactly one")
    func singleCandidateIsRecommended() throws {
        let point = try makeAnchoredPoint()
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .survived)])

        let next = NextFixRecommendation.build(from: report)
        #expect(next.candidateCount == 1)
        #expect(next.recommendation?.facts.mutantID == point.id.rawValue)
        #expect(next.rankingCriteria == NextFixRecommendation.rankingCriteria)
        #expect(!next.rankingCriteria.isEmpty)
    }

    @Test("build(from:) picks the survived mutant over a noCoverage one from the same report")
    func buildPrefersSurvivedOverNoCoverage() throws {
        let points = try discover(
            """
            struct Example {
                func flags() -> (Bool, Bool) { return (true, false) }
            }
            """, using: Operators.boolLiteral
        )
        #expect(points.count == 2)
        let survived = makeResult(point: points[0], outcome: .survived)
        let uncovered = makeResult(point: points[1], outcome: .noCoverage)
        let report = makeReport(plan: makePlan(mutations: points), results: [uncovered, survived])

        let next = NextFixRecommendation.build(from: report)
        #expect(next.candidateCount == 2)
        #expect(next.recommendation?.facts.mutantID == points[0].id.rawValue)
        #expect(next.recommendation?.facts.outcome == .survived)
    }
}
