import Foundation
import MutationModel
import Reporting
import Testing

/// `SurvivorPresentationBuilder` is the one place that
/// flattens `SurvivorActionabilityReport`'s grouped/clustered structure into
/// the shape every reporter actually iterates over — it does not decide
/// which survivors are duplicates, what a cluster's identity is, or how the
/// counts add up; that is `SurvivorActionabilityReport`'s own job (see
/// `SurvivorActionabilityReportTests`). These tests are about the
/// flattening/aggregate layer alone, plus the adversarial fixtures a
/// reporter built on top of it needs to hold up under.
@Suite("SurvivorPresentationBuilder")
struct SurvivorPresentationBuilderTests {
    private func evidenceWithNarrowedTests(_ tests: [String], diff: String = "diff") -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"),
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: diff,
            buildProductHash: ContentHash.of("mutant-binary"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
            )),
            testAttempts: [
                TestAttemptEvidence(
                    selectedTests: tests, status: "passed", summary: makeTestSummary(failed: 0),
                    command: nil, resultArtifact: nil, waveIndex: 0
                )
            ]
        )
    }

    /// Adversarial fixture: two genuinely duplicate survivors — same
    /// declaration, same narrowed test scope, nothing to distinguish them.
    @Test("Two genuinely duplicate survivors cluster into one row, with both members still inspectable")
    func clustersGenuineDuplicates() throws {
        let source = """
        struct Example {
            func flags() -> (Bool, Bool) { return (true, false) }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 2)

        let evidence = evidenceWithNarrowedTests(["ExampleTests/testFlags"])
        let results = points.map { makeResult(point: $0, outcome: .survived, evidence: evidence) }
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let presentation = SurvivorPresentationBuilder.build(from: report)
        #expect(presentation.rows.count == 1)
        let row = try #require(presentation.rows.first)
        #expect(row.count == 2)
        #expect(row.members.count == 2)
        #expect(Set(row.mutantIDs) == Set(points.map { $0.id.rawValue }))
        let aggregate = presentation.rows.aggregate
        #expect(aggregate.totalMutants == 2)
        #expect(aggregate.distinctIssues == 1)
    }

    /// Adversarial fixture: same operator, different declaration, different
    /// semantic mutation — must never cluster across declarations.
    @Test("Same operator in different declarations stays as separate rows")
    func doesNotClusterAcrossDeclarations() throws {
        let source = """
        struct Example {
            func isReady() -> Bool { return true }
            func isDone() -> Bool { return false }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 2)

        let results = points.map {
            makeResult(point: $0, outcome: .survived, evidence: evidenceWithNarrowedTests(["ExampleTests/testShared"]))
        }
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let presentation = SurvivorPresentationBuilder.build(from: report)
        #expect(presentation.rows.count == 2)
        #expect(presentation.rows.allSatisfy { $0.count == 1 })
    }

    /// Adversarial fixture: same declaration, different operators, but the
    /// exact same known test scope — a legitimate single-root-cause
    /// cluster (the operators are recorded in `operatorIDs`; each member's
    /// own diff/original/replacement is never lost, see
    /// `SurvivorActionabilityReportTests.clusteringNeverDropsAMembersOwnDiff`).
    @Test("Different operators in the same declaration with the identical known test scope cluster, keeping both operator IDs")
    func clustersAcrossOperatorsWithinOneDeclaration() throws {
        let source = "func check(flag: Bool) -> Bool { true && flag }"
        let points = try discover(
            source, path: "Sources/Check.swift", using: Operators.boolLiteral + Operators.logicalConnector
        )
        #expect(points.count == 2, "one bool-literal candidate, one logical-connector candidate, same declaration")

        let evidence = evidenceWithNarrowedTests(["CheckTests/testCheck"])
        let results = points.map { makeResult(point: $0, outcome: .survived, evidence: evidence) }
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let presentation = SurvivorPresentationBuilder.build(from: report)
        #expect(presentation.rows.count == 1)
        let row = try #require(presentation.rows.first)
        #expect(row.count == 2)
        #expect(row.operatorIDs.count == 2, "both operators must still be visible on the clustered row")
    }

    /// Adversarial fixture: no-coverage survivor vs covered-but-survived —
    /// both are actionable and both are present in this builder's output
    /// (unlike an earlier version, which silently dropped `.noCoverage`
    /// rows here). Which of the two a given reporter chooses to *render* is
    /// that reporter's own decision, not this builder's.
    @Test("Both .noCoverage and .survived rows are present in the builder's output")
    func bothReasonsArePresent() throws {
        let notCovered = try makeAnchoredPoint(file: "Sources/A.swift")
        let covered = try makeAnchoredPoint(file: "Sources/B.swift")
        let results = [
            makeResult(point: notCovered, outcome: .noCoverage),
            makeResult(point: covered, outcome: .survived, evidence: evidenceWithNarrowedTests(["Tests/testB"]))
        ]
        let report = makeReport(plan: makePlan(mutations: [notCovered, covered]), results: results)

        let presentation = SurvivorPresentationBuilder.build(from: report)
        #expect(presentation.rows.count == 2)
        #expect(presentation.rows.contains { $0.reason == .mutationSiteNotCovered })
        #expect(presentation.rows.contains { $0.reason != .mutationSiteNotCovered })
    }

    /// Adversarial fixture: missing optional evidence (no narrowed test
    /// selection ever recorded) must not crash and must honestly report
    /// `.unknown`, never overclaim `.fullSuite`.
    @Test("A survivor with no testAttempts recorded produces .unknown test scope")
    func missingOptionalEvidenceProducesUnknownScope() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .survived) // default evidence has no testAttempts
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let presentation = SurvivorPresentationBuilder.build(from: report)
        let row = try #require(presentation.rows.first)
        #expect(row.testScope == .unknown)
        #expect(row.count == 1)
    }

    /// Adversarial fixture: stable output under shuffled input — a report's
    /// `results` array order must never change which rows come out, or in
    /// what order.
    @Test("Flattening is deterministic regardless of the input results order")
    func deterministicOrderRegardlessOfInputOrder() throws {
        let source = """
        struct Example {
            func isReady() -> Bool { return true }
            func isDone() -> Bool { return false }
            func isSet() -> Bool { return true }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 3)
        let plan = makePlan(mutations: points)

        // Keyed by the point's own identity, not position -- so every point
        // carries the same covering-test fact regardless of where it lands
        // in whichever order array is passed to `results(order:)`.
        let testNameByID = Dictionary(uniqueKeysWithValues: points.enumerated().map { index, point in
            (point.id, "ExampleTests/test\(index)")
        })

        func results(order: [MutationPoint]) -> [MutationResult] {
            order.map { point in
                makeResult(
                    point: point, outcome: .survived,
                    evidence: evidenceWithNarrowedTests([testNameByID[point.id]!])
                )
            }
        }

        let forward = SurvivorPresentationBuilder.build(from: makeReport(plan: plan, results: results(order: points)))
        let reversed = SurvivorPresentationBuilder.build(
            from: makeReport(plan: plan, results: results(order: points.reversed()))
        )
        let shuffled = SurvivorPresentationBuilder.build(
            from: makeReport(plan: plan, results: results(order: [points[1], points[2], points[0]]))
        )

        #expect(forward.rows == reversed.rows)
        #expect(forward.rows == shuffled.rows)
    }

    @Test("Aggregate counts always equal the sum/number of the rows actually produced")
    func aggregateMatchesRows() throws {
        let source = """
        struct Example {
            func flags() -> (Bool, Bool, Bool) { return (true, false, true) }
            func isDone() -> Bool { return false }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 4)

        let flagsPoints = points.filter { $0.enclosingDeclaration.description.contains("flags") }
        let isDonePoints = points.filter { $0.enclosingDeclaration.description.contains("isDone") }
        #expect(flagsPoints.count == 3)
        #expect(isDonePoints.count == 1)

        let sharedEvidence = evidenceWithNarrowedTests(["ExampleTests/testFlags"])
        let results = flagsPoints.map { makeResult(point: $0, outcome: .survived, evidence: sharedEvidence) }
            + isDonePoints.map { makeResult(point: $0, outcome: .survived, evidence: sharedEvidence) }
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let presentation = SurvivorPresentationBuilder.build(from: report)
        #expect(presentation.rows.count == 2)
        let aggregate = presentation.rows.aggregate
        #expect(aggregate.distinctIssues == presentation.rows.count)
        #expect(aggregate.totalMutants == presentation.rows.reduce(0) { $0 + $1.count })
        #expect(aggregate.totalMutants == 4)
    }
}
