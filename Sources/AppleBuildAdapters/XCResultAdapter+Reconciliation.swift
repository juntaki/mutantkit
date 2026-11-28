import Foundation
import MutationModel

/// Reconciliation of a single (non-batch) result against its own counts: a result
/// that does not account for every selected test is unknown, never a pass.
extension XCResultAdapter {
    /// Counts that disagree with each other cannot account for the selected tests.
    /// Negative counts, parts exceeding the total, or a passing result whose passed,
    /// skipped and expected-failure counts do not add up to the total (tests with no
    /// recorded outcome) are `.infrastructureFailure`. A failing result is left to the
    /// failure path: a run that stopped on a genuine failure legitimately has unrun tests.
    func inconsistentCountsOutcome(summary: TestSummaryJSON, outcomeSummary: TestOutcomeSummary) -> Outcome? {
        let parts = [summary.passedTests, summary.failedTests, summary.skippedTests, summary.expectedFailures]
        let accounted = parts.reduce(0, +)
        let problem: String?
        if parts.contains(where: { $0 < 0 }) || summary.totalTestCount < 0 {
            problem = "a count is negative"
        } else if accounted > summary.totalTestCount {
            problem = "the per-outcome counts (\(accounted)) exceed the total (\(summary.totalTestCount))"
        } else if summary.failedTests == 0, accounted < summary.totalTestCount {
            problem = "\(summary.totalTestCount - accounted) of \(summary.totalTestCount) test(s) have no recorded outcome"
        } else {
            problem = nil
        }
        guard let problem else { return nil }
        return Outcome(
            status: .infrastructureFailure,
            summary: outcomeSummary,
            diagnosis: "The result bundle's counts are inconsistent: \(problem). The selection is not accounted for, so it is not scored."
        )
    }

    /// A selection that was only skipped proved nothing about the mutant, so it is
    /// not a pass. Applies to a passing result only.
    func allSkippedOutcome(summary: TestSummaryJSON, outcomeSummary: TestOutcomeSummary) -> Outcome? {
        guard summary.result == "Passed", summary.passedTests + summary.expectedFailures == 0 else { return nil }
        return Outcome(
            status: .infrastructureFailure,
            summary: outcomeSummary,
            diagnosis: """
            Every one of the \(summary.totalTestCount) test(s) in the result was skipped, so \
            no test executed. Skipped tests are not a pass.
            """
        )
    }

    /// A failure record next to a zero failed count is a contradiction, not a kill.
    func contradictionOutcome(
        summary: TestSummaryJSON,
        failures: [TestSummaryJSON.Failure],
        outcomeSummary: TestOutcomeSummary
    ) -> Outcome? {
        guard !failures.isEmpty, summary.failedTests == 0 else { return nil }
        return Outcome(
            status: .infrastructureFailure,
            summary: outcomeSummary,
            diagnosis: """
            The result bundle names \(failures.count) failing test(s) but reports no failed \
            tests. The result contradicts itself, so it is not scored as a kill.
            """
        )
    }
}
