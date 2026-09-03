import Foundation
import MutationModel

/// A compact markdown summary for a CI job summary or a PR comment.
///
/// Sized for a reader who is scanning, not investigating: the verdict, the two
/// scores, what was excluded, and the first few survivors with a link-shaped
/// location. Everything else lives in the JSON and HTML reports.
public struct CISummaryReporter: Reporter {
    private let survivorLimit: Int

    /// - Parameter survivorLimit: a PR comment with two hundred survivors is a
    ///   PR comment nobody reads. The full list is in the other formats.
    public init(survivorLimit: Int = 10) {
        self.survivorLimit = survivorLimit
    }

    public func render(_ report: RunReport) throws -> String {
        var out = ["## Mutation testing"]

        out.append(scoreSection(report))
        out.append(outcomeTable(report))
        out.append(excludedSection(report))
        out.append(survivorSection(report))
        out.append(footer(report))

        return out.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    // MARK: Sections

    private func scoreSection(_ report: RunReport) -> String {
        // Fail-closed: no number, no zero, no "0%" that a reader would skim past
        // as a bad-but-real result. The refusal is the headline.
        guard let score = report.score else {
            var lines = [
                "> [!CAUTION]",
                "> **\(FailClosed.headline)**",
                ">",
                "> \(FailClosed.explanation)",
                ">",
                "> Violations:"
            ]
            for violation in report.integrity.violations {
                lines.append("> - `\(violation.kind.rawValue)` — \(violation.detail)")
            }
            return lines.joined(separator: "\n")
        }

        return """
        | Score | Value | Formula |
        | --- | --- | --- |
        | Tested Mutation Score | **\(Format.percent(score.tested) ?? "n/a")** | `killed / (killed + survived)` = \(score.killed)/\(score.killed + score.survived) |
        | Effective Mutation Score | **\(Format.percent(score.effective) ?? "n/a")** | `killed / (killed + survived + noCoverage)` = \(score.killed)/\(score.killed + score.survived + score.noCoverage) |
        """
    }

    private func outcomeTable(_ report: RunReport) -> String {
        var lines = [
            "<details><summary>Outcome breakdown</summary>",
            "",
            "| Outcome | Count | Scoring |",
            "| --- | ---: | --- |"
        ]
        for (outcome, count) in report.outcomeCounts {
            lines.append("| \(outcome.displayName) | \(count) | \(outcome.isScorable ? "in denominator" : "excluded") |")
        }
        lines.append("")
        lines.append("</details>")
        return lines.joined(separator: "\n")
    }

    private func excludedSection(_ report: RunReport) -> String {
        guard !report.excludedCounts.isEmpty else { return "" }

        let items = report.excludedCounts
            .map { "\($0.outcome.displayName) \($0.count)" }
            .joined(separator: ", ")

        return "**Excluded from every denominator (\(report.excludedTotal)):** \(items). "
            + "These describe the tool run, not the test suite."
    }

    /// Same scope as before this rendering changed (`.survived` only, never
    /// `.noCoverage` — the exact set `report.survivors` itself names), just
    /// grouped by declaration and clustered to one row per distinct root
    /// cause instead of one row per mutant, via the shared
    /// `SurvivorPresentation` model — the identical rows
    /// `ConsoleReporter` and `HTMLReporter` render from, so all three agree
    /// on cluster identity, membership, and counts for the same run. A
    /// near-duplicate cluster (five mutants in one function, all run against
    /// the same weak test scope) used to cost five rows of `survivorLimit`'s
    /// own budget for one real story; now it costs one, so a PR comment
    /// sized for the same budget surfaces more distinct issues, not more
    /// repetition of the same one.
    ///
    /// "Tests run", not "caught by": these mutants are `.survived` — by
    /// definition nothing caught them. The column names what the run's own
    /// evidence establishes was exercised, not a claim about which test is
    /// responsible for the miss.
    private func survivorSection(_ report: RunReport) -> String {
        let rows = SurvivorPresentationBuilder.build(from: report).rows
            .filter { $0.reason != .mutationSiteNotCovered }

        guard !rows.isEmpty else {
            return report.score == nil ? "" : "No mutants survived."
        }

        let aggregate = rows.aggregate
        var lines = [
            "### Surviving mutants (\(aggregate.totalMutants), \(aggregate.distinctIssues) distinct issue(s))",
            "", "| Location | Operator(s) | Change | Tests run |", "| --- | --- | --- | --- |"
        ]

        for row in rows.prefix(survivorLimit) {
            let representative = row.members[0]
            let countSuffix = row.count > 1 ? " (×\(row.count))" : ""
            lines.append(
                "| `\(row.file):\(representative.line)`\(countSuffix) | `\(row.operatorIDs.joined(separator: ", "))` "
                    + "| `\(inlineCode(representative.original))` → `\(inlineCode(representative.replacement))` "
                    + "| \(testsRunLabel(row.testScope)) |"
            )
        }

        if rows.count > survivorLimit {
            lines.append("")
            lines.append("_\(rows.count - survivorLimit) more issue(s) in the full report._")
        }
        return lines.joined(separator: "\n")
    }

    private func testsRunLabel(_ scope: SurvivorActionabilityReport.TestScope?) -> String {
        switch scope {
        case .none, .unknown: "unknown"
        case .fullSuite: "full suite"
        case let .narrowed(tests):
            tests.prefix(2).joined(separator: ", ") + (tests.count > 2 ? ", …" : "")
        }
    }

    private func footer(_ report: RunReport) -> String {
        let baseline = report.baseline.passed ? "green" : "**red**"
        return "<sub>Plan `\(report.planID)` · baseline \(baseline) · "
            + "MutantKit \(report.toolchain.toolVersion) · Swift \(report.toolchain.swiftVersion)</sub>"
    }

    // MARK: Helpers

    /// A table cell is one line, and a `|` in mutated source would split the row
    /// into columns that do not exist.
    private func inlineCode(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "`", with: "'")
    }
}
