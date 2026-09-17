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

/// `passedOutput(for:)` is what `run()` actually composes from — `run()`
/// itself talks to real adapters/sandboxes and cannot be unit-tested, which
/// previously left this decision effectively uncovered (SonarCloud's
/// new-code coverage gate caught it: 20% on this file for the PR that
/// introduced the branching this type replaces).
@Suite("DryRunCommand.passedOutput")
struct DryRunCommandPassedOutputTests {
    @Test("A real summary prints one line with the counts, and warns about nothing")
    func summaryPresentPrintsCountsAndNoWarning() {
        let summary = TestOutcomeSummary(
            total: 42, passed: 41, failed: 1, failingTests: ["Suite/testSomething"], durationSeconds: 3.5
        )
        let output = DryRunCommand.passedOutput(for: summary)

        #expect(output.stdoutLine == "Dry run passed (41 passed, 1 failed of 42).")
        #expect(output.stderrWarning == nil)
    }

    @Test("No summary prints a bare pass line, plus a separate stderr warning naming the real reason")
    func summaryAbsentPrintsBareLineAndSeparateWarning() {
        let output = DryRunCommand.passedOutput(for: nil)

        // The bare "Dry run passed." must never itself carry the caveat —
        // that is the whole point of splitting it into its own stderr
        // line, not a parenthetical a reader can skim past as good news.
        #expect(output.stdoutLine == "Dry run passed.")
        #expect(output.stderrWarning != nil)
        #expect(output.stderrWarning?.hasPrefix("warning: ") == true)
        #expect(output.stderrWarning?.contains("unavailable") == true)
        #expect(output.stderrWarning?.hasSuffix("\n") == true)
    }
}
