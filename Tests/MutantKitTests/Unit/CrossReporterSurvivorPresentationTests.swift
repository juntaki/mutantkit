import Foundation
import MutationModel
import Reporting
import Testing

/// `CISummaryReporter`, `ConsoleReporter`, and `HTMLReporter`
/// all render their survivor section from the same
/// `SurvivorPresentationBuilder.build(from:)` output now, instead of each
/// deciding grouping/clustering independently. These tests hold that
/// structural guarantee directly: given the identical `RunReport`, all three
/// must agree on cluster membership and counts — not merely produce output
/// that happens to look similar. They also hold the non-lossy guarantee
/// `SurvivorActionabilityReportTests.clusteringNeverDropsAMembersOwnDiff`
/// asserts at the model layer: a reporter clustering N mutants into one row
/// must still surface all N of their own diffs, not one shared sample.
@Suite("Cross-reporter survivor grouping")
struct CrossReporterSurvivorPresentationTests {
    private func evidenceWithNarrowedTests(_ tests: [String], diff: String) -> MutationEvidence {
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

    /// One declaration with three duplicate survivors (clusters to one row,
    /// count 3, each with its own distinctly-tagged diff so a test can prove
    /// none of the three is dropped) and a second declaration with one
    /// distinct survivor (clusters to one row, count 1) — two groups, four
    /// mutants total.
    private func makeMixedReport() throws -> RunReport {
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

        // Every flags-group member gets its OWN distinctly-tagged diff
        // (FLAGS_0/1/2), not one shared evidence object -- exactly the
        // shape that would have silently lost two of three diffs under an
        // earlier, single-representative-per-row design.
        let flagsResults = flagsPoints.enumerated().map { index, point in
            makeResult(
                point: point, outcome: .survived,
                evidence: evidenceWithNarrowedTests(
                    ["ExampleTests/testFlags"],
                    diff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -2,1 +2,1 @@\n-DISTINCTIVE_FLAGS_\(index)_DIFF\n"
                )
            )
        }
        let singletonEvidence = evidenceWithNarrowedTests(
            ["ExampleTests/testIsDone"],
            diff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -3,1 +3,1 @@\n-DISTINCTIVE_ISDONE_DIFF\n"
        )
        let results = flagsResults + isDonePoints.map { makeResult(point: $0, outcome: .survived, evidence: singletonEvidence) }

        return makeReport(plan: makePlan(mutations: points), results: results)
    }

    @Test("CI, Console, and HTML report the identical aggregate counts for the same run")
    func aggregateCountsMatchAcrossReporters() throws {
        let report = try makeMixedReport()
        let rows = SurvivorPresentationBuilder.build(from: report).rows
        #expect(rows.count == 2)
        let aggregate = rows.aggregate
        #expect(aggregate.totalMutants == 4)

        let header = "(\(aggregate.totalMutants), \(aggregate.distinctIssues) distinct issue(s))"

        let ci = try CISummaryReporter().render(report)
        let console = try ConsoleReporter(colorEnabled: false).render(report)
        let html = try HTMLReporter().render(report)

        #expect(ci.contains(header), "CI summary must show the same aggregate the shared model computed")
        #expect(console.contains(header), "Console must show the same aggregate the shared model computed")
        #expect(html.contains(header), "HTML must show the same aggregate the shared model computed")
    }

    @Test("CI, Console, and HTML all show the ×N collapse indicator for the same cluster")
    func collapseCountMatchesAcrossReporters() throws {
        let report = try makeMixedReport()
        let rows = SurvivorPresentationBuilder.build(from: report).rows
        let clusteredRow = try #require(rows.first { $0.count > 1 })
        #expect(clusteredRow.count == 3)

        let ci = try CISummaryReporter().render(report)
        let console = try ConsoleReporter(colorEnabled: false).render(report)
        let html = try HTMLReporter().render(report)

        #expect(ci.contains("×3"))
        #expect(console.contains("×3"))
        #expect(html.contains("×3"))
    }

    /// The non-lossy guarantee, at the rendering layer: Console and HTML are
    /// full local reports, so clustering three mutants into one row must
    /// still surface all three of their own diffs -- never one shared
    /// sample standing in for the other two.
    @Test("Console and HTML surface every clustered member's own diff, not one shared sample")
    func clusteredMembersEachKeepTheirOwnDiffInConsoleAndHTML() throws {
        let report = try makeMixedReport()

        let console = try ConsoleReporter(colorEnabled: false).render(report)
        let html = try HTMLReporter().render(report)

        for index in 0 ..< 3 {
            #expect(console.contains("DISTINCTIVE_FLAGS_\(index)_DIFF"), "Console dropped flags-cluster member \(index)'s own diff")
            #expect(html.contains("DISTINCTIVE_FLAGS_\(index)_DIFF"), "HTML dropped flags-cluster member \(index)'s own diff")
        }
        #expect(console.contains("DISTINCTIVE_ISDONE_DIFF"))
        #expect(html.contains("DISTINCTIVE_ISDONE_DIFF"))
    }

    /// CI's own compact scope renders `original`/`replacement` for one
    /// representative member per row (never the raw diff, and never every
    /// member's own change) -- a deliberate, visible truncation appropriate
    /// to a PR-comment budget, not a silent loss the way losing it in
    /// Console/HTML's full-report scope would be.
    @Test("CI renders the singleton row's own original/replacement")
    func ciRendersSingletonRepresentative() throws {
        let report = try makeMixedReport()
        let rows = SurvivorPresentationBuilder.build(from: report).rows
        let singleton = try #require(rows.first { $0.count == 1 })
        #expect(singleton.declaration.contains("isDone"))

        let ci = try CISummaryReporter().render(report)
        let representative = try #require(singleton.members.first)
        #expect(ci.contains(representative.original))
        #expect(ci.contains(representative.replacement))
    }

    @Test("An empty run never shows a survivor count or a collapse indicator in any reporter")
    func emptyRunHasNoSurvivorsAnywhere() throws {
        let point = try makeAnchoredPoint()
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .killedByAssertion)])

        let ci = try CISummaryReporter().render(report)
        let console = try ConsoleReporter(colorEnabled: false).render(report)
        let html = try HTMLReporter().render(report)

        #expect(!ci.contains("distinct issue"))
        #expect(!console.contains("distinct issue"))
        #expect(!html.contains("distinct issue"))
    }

    /// Console/HTML's own extra scope, beyond CI: both `.mutationSiteNotCovered`
    /// and `.coveredButNotCaught` rows must appear, split into their own
    /// labeled sections -- unlike CI, which stays `.survived`-only, matching
    /// `RunReport.survivors`'s own long-standing scope.
    @Test("Console and HTML show both not-covered and covered-but-survived; CI shows only covered-but-survived")
    func consoleAndHTMLShowBothReasonsCIShowsOnlySurvived() throws {
        let notCovered = try makeAnchoredPoint(file: "Sources/A.swift")
        let covered = try makeAnchoredPoint(file: "Sources/B.swift")
        let results = [
            makeResult(point: notCovered, outcome: .noCoverage),
            makeResult(point: covered, outcome: .survived, evidence: evidenceWithNarrowedTests(["Tests/testB"], diff: "diff"))
        ]
        let report = makeReport(plan: makePlan(mutations: [notCovered, covered]), results: results)

        let ci = try CISummaryReporter().render(report)
        let console = try ConsoleReporter(colorEnabled: false).render(report)
        let html = try HTMLReporter().render(report)

        #expect(!ci.contains("Sources/A.swift"), "CI must stay .survived-only, matching RunReport.survivors")
        #expect(ci.contains("Sources/B.swift"))

        #expect(console.contains("Not covered"))
        #expect(console.contains("Covered but survived"))
        #expect(html.contains("Not covered"))
        #expect(html.contains("Covered but survived"))
    }
}
