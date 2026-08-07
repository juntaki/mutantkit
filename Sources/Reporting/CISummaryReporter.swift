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

    private func survivorSection(_ report: RunReport) -> String {
        let survivors = report.survivors
        guard !survivors.isEmpty else {
            return report.score == nil ? "" : "No mutants survived."
        }

        var lines = ["### Surviving mutants (\(survivors.count))", "", "| Location | Operator | Change |", "| --- | --- | --- |"]

        for result in survivors.prefix(survivorLimit) {
            let point = result.point
            lines.append(
                "| `\(point.displayLocation)` | `\(point.operatorID)` "
                    + "| `\(inlineCode(point.originalText))` → `\(inlineCode(point.replacementText))` |"
            )
        }

        if survivors.count > survivorLimit {
            lines.append("")
            lines.append("_\(survivors.count - survivorLimit) more survivor(s) in the full report._")
        }
        return lines.joined(separator: "\n")
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
