import Foundation
import MutationModel
import Reporting
import Testing

/// `CISummaryReporter`'s own survivor section renders the
/// grouped/clustered `SurvivorActionabilityReport` view instead of one row
/// per mutant — same scope as before (`.survived` only, never
/// `.noCoverage`), just fewer, more informative rows. See
/// `SurvivorActionabilityReportTests` for the underlying grouping/clustering
/// logic itself; these tests only check the rendering built on top of it.
@Suite("CISummaryReporter survivor grouping")
struct CISummaryReporterSurvivorGroupingTests {
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

    @Test("Two survivors in the same declaration with identical narrowed test scope render as one row, not two")
    func clustersIntoOneRow() throws {
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

        let output = try CISummaryReporter().render(report)
        #expect(output.contains("Surviving mutants (2, 1 distinct issue(s))"))
        #expect(output.contains("×2"))
        #expect(output.contains("ExampleTests/testFlags"))
        // Only one data row for this declaration -- the sample change must
        // appear exactly once, not twice.
        let occurrences = output.components(separatedBy: "ExampleTests/testFlags").count - 1
        #expect(occurrences == 1)
    }

    @Test(".noCoverage mutants never appear in the survivor section — scope is unchanged from before grouping")
    func excludesNoCoverage() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .noCoverage)
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let output = try CISummaryReporter().render(report)
        #expect(!output.contains("Surviving mutants"))
    }

    /// RED scenario B, at the CI rendering layer: an ordinary (non-wave)
    /// invocation with no `testAttempts` recorded must render as "unknown",
    /// never "full suite" — the evidence does not distinguish the two, and
    /// claiming "full suite" would be a stronger statement than the run
    /// actually proved.
    @Test("A survivor with no testAttempts recorded renders as 'unknown', never 'full suite'")
    func missingTestAttemptsRendersAsUnknown() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .survived) // default evidence: no testAttempts
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let output = try CISummaryReporter().render(report)
        #expect(output.contains("unknown"))
        #expect(!output.contains("full suite"))
    }

    /// The positive counterpart: an attempt that explicitly ran with no
    /// narrowing (`selectedTests == nil`) is real, proven evidence — "full
    /// suite" is the correct label there, not "unknown".
    @Test("A survivor whose deciding attempt explicitly ran unnarrowed renders as 'full suite'")
    func explicitFullSuiteRendersAsFullSuite() throws {
        let point = try makeAnchoredPoint()
        let evidence = MutationEvidence(
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
        let result = makeResult(point: point, outcome: .survived, evidence: evidence)
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let output = try CISummaryReporter().render(report)
        #expect(output.contains("full suite"))
    }
}
