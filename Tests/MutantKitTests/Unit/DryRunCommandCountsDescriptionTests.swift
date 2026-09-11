@testable import CLI
import MutationModel
import Testing

/// `dry-run` exists to build confidence before a real mutation run, so its
/// pass message should give a positive count whenever the test runner's own
/// structured output has one — and only fall back to a vaguer message for
/// the genuinely-unmeasured case (see `DryRunCommand.countsDescription`'s own
/// doc comment for exactly which adapters/configs that is).
@Suite("DryRunCommand.countsDescription")
struct DryRunCommandCountsDescriptionTests {
    @Test("A real summary is surfaced as a positive pass/fail/total count")
    func summaryPresentShowsRealCount() {
        let summary = TestOutcomeSummary(
            total: 42,
            passed: 41,
            failed: 1,
            failingTests: ["Suite/testSomething"],
            durationSeconds: 3.5
        )

        #expect(DryRunCommand.countsDescription(for: summary) == "41 passed, 1 failed of 42")
    }

    @Test("No summary falls back to the vaguer, but still honest, message")
    func summaryAbsentFallsBackToUnavailable() {
        let description = DryRunCommand.countsDescription(for: nil)

        #expect(description.contains("unavailable"))
        // Never invent a count from an unstructured source when none was measured.
        #expect(!description.contains("passed"))
        #expect(!description.contains("failed"))
    }
}
