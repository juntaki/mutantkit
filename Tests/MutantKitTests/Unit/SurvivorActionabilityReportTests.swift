import Foundation
import MutationModel
import Reporting
import Testing

@Suite("SurvivorActionabilityReport")
struct SurvivorActionabilityReportTests {
    /// Two declarations, two bool-literal candidates each — enough surface
    /// for grouping (different declarations), clustering (same declaration,
    /// same reason), and non-clustering (same declaration, different test
    /// scope) all in one fixture.
    private func makeTwoDeclarationPoints() throws -> (first: [MutationPoint], second: [MutationPoint]) {
        let source = """
        struct Example {
            func isReady() -> Bool { return true }
            func isDone() -> Bool { return false }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 2, "expected one candidate per function")
        let byDeclaration = Dictionary(grouping: points, by: \.enclosingDeclaration)
        #expect(byDeclaration.count == 2, "expected two distinct declarations")
        let sortedGroups = byDeclaration.values.sorted { ($0.first?.line ?? 0) < ($1.first?.line ?? 0) }
        return (sortedGroups[0], sortedGroups[1])
    }

    /// A wave-based attempt with an explicit, narrowed test list — the one
    /// shape `TestAttemptEvidence` actually exists for (see its own doc
    /// comment). `waveIndex: 0` marks it as real wave evidence, not merely a
    /// populated array with no wave semantics.
    private func evidenceWithNarrowedTests(_ tests: [String]) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"),
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "diff",
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

    /// A wave-based attempt that explicitly ran with no narrowing at all —
    /// `selectedTests: nil`, `TestAttemptEvidence`'s own contract for "the
    /// whole configured suite ran," proven rather than assumed.
    private func evidenceWithExplicitFullSuite() -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"),
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "diff",
            buildProductHash: ContentHash.of("mutant-binary"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
            )),
            testAttempts: [
                TestAttemptEvidence(
                    selectedTests: nil, status: "passed", summary: makeTestSummary(failed: 0),
                    command: nil, resultArtifact: nil, waveIndex: 0
                )
            ]
        )
    }

    @Test("Only .survived and .noCoverage results are actionable — everything else is excluded")
    func excludesNonActionableOutcomes() throws {
        let source = """
        struct Example {
            func flags() -> (Bool, Bool) { return (true, false) }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 2, "two distinct points needed -- one result per MutationID")
        let killed = makeResult(point: points[0], outcome: .killedByAssertion)
        let unviable = makeResult(point: points[1], outcome: .unviable)
        let report = makeReport(plan: makePlan(mutations: points), results: [killed, unviable])

        let actionability = SurvivorActionabilityReport.build(from: report)
        #expect(actionability.groups.isEmpty)
    }

    @Test(".noCoverage mutants in the same declaration cluster into one issue")
    func clustersNoCoverageInSameDeclaration() throws {
        let source = """
        struct Example {
            func compute() -> Bool { return true || false }
        }
        """
        let points = try discover(source, using: [Operators.boolLiteral[0]] + Operators.logicalConnector)
        #expect(points.count >= 2)

        let results = points.map { makeResult(point: $0, outcome: .noCoverage) }
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let actionability = SurvivorActionabilityReport.build(from: report)
        #expect(actionability.groups.count == 1)
        let group = try #require(actionability.groups.first)
        #expect(group.clusters.count == 1, "all noCoverage mutants in one declaration must cluster to one issue")
        let cluster = try #require(group.clusters.first)
        #expect(cluster.reason == .mutationSiteNotCovered)
        #expect(cluster.members.count == points.count)
        #expect(cluster.reproduceCommands.count == points.count)
    }

    @Test("Two .survived mutants in the same declaration with the SAME narrowed test scope cluster into one issue")
    func clustersSurvivedWithIdenticalNarrowedScope() throws {
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

        let actionability = SurvivorActionabilityReport.build(from: report)
        #expect(actionability.groups.count == 1)
        let cluster = try #require(actionability.groups.first?.clusters.first)
        #expect(actionability.groups.first?.clusters.count == 1)
        #expect(cluster.members.count == 2)
        #expect(cluster.reason == .coveredButNotCaught(testScope: .narrowed(["ExampleTests/testFlags"])))
    }

    @Test("Two .survived mutants in the same declaration with DIFFERENT narrowed test scopes stay separate")
    func doesNotClusterSurvivedWithDifferentNarrowedScopes() throws {
        let source = """
        struct Example {
            func flags() -> (Bool, Bool) { return (true, false) }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 2)

        let resultA = makeResult(point: points[0], outcome: .survived, evidence: evidenceWithNarrowedTests(["ExampleTests/testA"]))
        let resultB = makeResult(point: points[1], outcome: .survived, evidence: evidenceWithNarrowedTests(["ExampleTests/testB"]))
        let report = makeReport(plan: makePlan(mutations: points), results: [resultA, resultB])

        let actionability = SurvivorActionabilityReport.build(from: report)
        #expect(actionability.groups.count == 1)
        #expect(
            actionability.groups.first?.clusters.count == 2,
            "different known test scopes must not be clustered into one another"
        )
    }

    @Test("Different declarations produce different groups, sorted by file then declaration")
    func groupsByDeclaration() throws {
        let (first, second) = try makeTwoDeclarationPoints()
        let allPoints = first + second
        let results = allPoints.map { makeResult(point: $0, outcome: .noCoverage) }
        let report = makeReport(plan: makePlan(mutations: allPoints), results: results)

        let actionability = SurvivorActionabilityReport.build(from: report)
        #expect(actionability.groups.count == 2)
        #expect(actionability.groups[0].declaration != actionability.groups[1].declaration)
    }

    @Test("Within one group, mutationSiteNotCovered sorts before coveredButNotCaught")
    func sortsUncoveredBeforeCoveredButSurvived() throws {
        let source = """
        struct Example {
            func flags() -> (Bool, Bool) { return (true, false) }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 2)

        let notCovered = makeResult(point: points[0], outcome: .noCoverage)
        let covered = makeResult(point: points[1], outcome: .survived, evidence: evidenceWithNarrowedTests(["ExampleTests/testA"]))
        let report = makeReport(plan: makePlan(mutations: points), results: [covered, notCovered])

        let actionability = SurvivorActionabilityReport.build(from: report)
        let clusters = try #require(actionability.groups.first?.clusters)
        #expect(clusters.count == 2)
        #expect(clusters[0].reason == .mutationSiteNotCovered)
    }

    // MARK: - RED scenarios from code review (see this file's own git history
    // for the exact critique): each of the following reproduces one specific
    // overclaim or data-loss bug found in an earlier version of this model.

    /// RED scenario B: a single, ordinary (non-wave) invocation with no
    /// `testAttempts` recorded must never be read as "the full suite ran" —
    /// the evidence genuinely does not say either way (the real invocation
    /// may have been narrowed via `execution.selectCoveringTests`, just not
    /// through the attempt-tracked path this model has access to).
    @Test("An empty testAttempts list produces .unknown test scope, never .fullSuite")
    func emptyTestAttemptsIsUnknownNotFullSuite() throws {
        let point = try makeAnchoredPoint()
        // Default makeEvidence() has empty testAttempts -- the ordinary,
        // non-wave shape.
        let result = makeResult(point: point, outcome: .survived)
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let actionability = SurvivorActionabilityReport.build(from: report)
        let cluster = try #require(actionability.groups.first?.clusters.first)
        #expect(cluster.reason == .coveredButNotCaught(testScope: .unknown))
    }

    /// The positive counterpart: a wave-based attempt that explicitly ran
    /// with `selectedTests == nil` is real, proven evidence the whole suite
    /// ran — `.fullSuite`, not `.unknown` — the distinction `.unknown`
    /// exists to preserve.
    @Test("An attempt with selectedTests == nil produces .fullSuite, proven not assumed")
    func explicitNilSelectionIsFullSuite() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .survived, evidence: evidenceWithExplicitFullSuite())
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let actionability = SurvivorActionabilityReport.build(from: report)
        let cluster = try #require(actionability.groups.first?.clusters.first)
        #expect(cluster.reason == .coveredButNotCaught(testScope: .fullSuite))
    }

    /// RED scenario C: two semantically different mutants (different
    /// operators, different source positions) that happen to share a
    /// declaration and an (unknown) test scope must still cluster — that is
    /// expected, not a bug, since the evidence cannot distinguish them — but
    /// clustering must never cost either one its own diff. An earlier
    /// version of this model kept only one "representative" diff per
    /// cluster, silently discarding the other's.
    @Test("Clustered mutants each keep their own diff — clustering never discards a member's own change")
    func clusteringNeverDropsAMembersOwnDiff() throws {
        let source = "func check(flag: Bool) -> Bool { true && flag }"
        let points = try discover(source, path: "Sources/Check.swift", using: Operators.boolLiteral + Operators.logicalConnector)
        #expect(points.count == 2, "one bool-literal candidate, one logical-connector candidate, same declaration")

        let results = points.map { makeResult(point: $0, outcome: .survived) } // default evidence: unknown scope for both
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let actionability = SurvivorActionabilityReport.build(from: report)
        #expect(actionability.groups.count == 1)
        let cluster = try #require(actionability.groups.first?.clusters.first)
        #expect(cluster.members.count == 2, "same declaration, same (unknown) scope -- expected to cluster")
        // Each member's own original/replacement must still be individually
        // present, not collapsed to one shared sample.
        let originals = Set(cluster.members.map(\.original))
        #expect(originals.count == 2, "two distinct mutations must keep two distinct `original` values, not one shared sample")
        #expect(cluster.operatorIDs.count == 2, "both operators must still be visible on the clustered issue")
    }

    /// RED scenario D: grouping/clustering must be a total ordering, not
    /// merely "mostly sorted" — two same-size clusters in the same severity
    /// band, built from a `results` array in a different order, must still
    /// come out in the identical order every time. `Dictionary(grouping:)`'s
    /// own iteration order is unspecified, so without a final tiebreaker
    /// this could silently flip between builds.
    @Test("Same-size clusters in the same band sort identically regardless of input order (RED: total ordering)")
    func sameSizeClustersHaveATotalOrdering() throws {
        // One declaration, three candidates, each given its own distinct
        // narrowed scope -- three separate clusters, all `.coveredButNotCaught`
        // (same severity band) and all size 1 (same count), so only the
        // final mutant-ID tiebreaker can decide their relative order.
        let source = """
        struct Example {
            func flags() -> (Bool, Bool, Bool) { return (true, false, true) }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count == 3)
        let plan = makePlan(mutations: points)

        // Keyed by the point's own identity, not position, so the semantic
        // content is identical regardless of which order `results(order:)`
        // is handed -- only the *order* of construction differs.
        let testNameByID = Dictionary(uniqueKeysWithValues: points.enumerated().map { index, point in
            (point.id, "ExampleTests/test\(index)")
        })
        func results(order: [MutationPoint]) -> [MutationResult] {
            order.map { point in
                makeResult(point: point, outcome: .survived, evidence: evidenceWithNarrowedTests([testNameByID[point.id]!]))
            }
        }

        let forward = SurvivorActionabilityReport.build(from: makeReport(plan: plan, results: results(order: points)))
        let reversed = SurvivorActionabilityReport.build(from: makeReport(plan: plan, results: results(order: points.reversed())))
        let shuffled = SurvivorActionabilityReport.build(
            from: makeReport(plan: plan, results: results(order: [points[1], points[2], points[0]]))
        )

        #expect(forward.groups.count == 1)
        #expect(forward.groups.first?.clusters.count == 3, "three distinct narrowed scopes -- three separate clusters")
        #expect(forward.groups.map { $0.clusters.map(\.members) } == reversed.groups.map { $0.clusters.map(\.members) })
        #expect(forward.groups.map { $0.clusters.map(\.members) } == shuffled.groups.map { $0.clusters.map(\.members) })
    }
}
