import Foundation
@testable import MutationExecution
import MutationModel
import Testing

/// A per-test coverage pass that could not prove every test still costs the
/// full pass — the most expensive thing a baseline does — and buys something
/// measurably coarser than a complete one. The predecessor of this reporting
/// said nothing at all in that case, which is how a real project paid ~100
/// minutes for it twice while every mutant still ran the whole suite. These
/// pin that it reaches `report.json`, and that it stays quiet otherwise.
@Suite("Per-test coverage attribution reporting")
struct PerTestCoverageAttributionReportTests {
    private let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
    private let unproven = TestIdentifier(target: "FooTests", qualifiedName: "FlakyTests/testFlaky")

    @Test("A complete attribution reports nothing — this is a degradation notice, not a progress line")
    func completeAttributionIsSilent() async {
        let log = OperationalIssueLog()

        await PerTestCoverageAttribution.report(
            PerTestCoverageMap(coveringTests: ["Sources/Foo.swift": [1: [addTest]]], source: "test"), to: log
        )

        #expect(await log.snapshot().isEmpty)
    }

    @Test("A partial attribution becomes one warning-severity operational issue naming the unproven tests")
    func partialAttributionIsRecorded() async throws {
        let log = OperationalIssueLog()

        await PerTestCoverageAttribution.report(
            PerTestCoverageMap(
                coveringTests: ["Sources/Foo.swift": [1: [addTest]]], source: "test", unattributedTests: [unproven]
            ),
            to: log
        )

        let issue = try #require(await log.snapshot().first)
        #expect(await log.snapshot().count == 1)
        #expect(issue.kind == .perTestCoverageIncomplete)
        #expect(issue.severity == .warning)
        // Never attributed to one mutant: the pass is a run-level event, the
        // same one-per-cause rule `schemataChunkBuildFailed` follows.
        #expect(issue.mutationID == nil)
        #expect(issue.diagnosis.contains(unproven.onlyTestingArgument))
        // The reason a reader can stop worrying about the score, stated in
        // the issue itself rather than left to be inferred.
        #expect(issue.diagnosis.contains("noCoverage"))
    }

    /// A systemic failure — the whole suite unprovable — must not turn one
    /// report field into a list of every test in the project.
    @Test("Many unproven tests are summarised rather than listed in full")
    func manyUnprovenTestsAreSummarised() async throws {
        let many = Set((1 ... 40).map { TestIdentifier(target: "FooTests", qualifiedName: "BigTests/test\($0)") })
        let log = OperationalIssueLog()

        await PerTestCoverageAttribution.report(
            PerTestCoverageMap(
                coveringTests: ["Sources/Foo.swift": [1: [addTest]]], source: "test", unattributedTests: many
            ),
            to: log
        )

        let issue = try #require(await log.snapshot().first)
        #expect(issue.diagnosis.contains("40 test(s)"))
        #expect(issue.diagnosis.contains("(+30 more)"))
    }
}
