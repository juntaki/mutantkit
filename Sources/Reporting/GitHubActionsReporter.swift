import Foundation
import MutationModel

/// Emits GitHub Actions workflow-command annotations
/// (`::warning ...::`/`::error ...::`) so surviving mutants and integrity
/// violations show up as inline annotations on the "Files changed" tab of a
/// pull request and in the job's own Checks summary — GitHub's own
/// equivalent of the issue-navigator experience `XcodeReporter` gives Xcode.
///
/// Phase C7 (competitive-parity program): `CISummaryReporter` already gives
/// a markdown job-summary/PR-comment view, but nothing in this codebase ever
/// emitted the workflow-command syntax GitHub's own runner parses out of a
/// step's stdout to create those inline annotations — a real, confirmed gap
/// (C0), not an oversight this reporter merely rewords.
///
/// ## Workflow-command format
///
/// `::warning file={file},line={line},col={col}::{message}` or
/// `::error file={file},line={line},col={col}::{message}`. GitHub only
/// recognizes this when printed to the step's own stdout during a run — it
/// is not a file format, matching `ConsoleReporter`/`XcodeReporter`'s own
/// "printed, never written to disk" treatment in `RunCommand`.
///
/// ## Escaping
///
/// GitHub's workflow-command parser treats `%`, CR and LF as control
/// characters that must be percent-escaped, in both the property values
/// (`file=`/`line=`/`col=`) and the message; property *values* additionally
/// escape `,` and `:`, which would otherwise be read as the next
/// property/value delimiter. Getting this wrong does not merely look ugly —
/// an un-escaped `\n` or `:` truncates or corrupts the annotation GitHub
/// actually renders, which is exactly the kind of silent, half-broken
/// integration this reporter must not ship.
public struct GitHubActionsReporter: Reporter {
    public init() {}

    public func render(_ report: RunReport) throws -> String {
        var lines: [String] = []

        // Fail-closed, mirroring XcodeReporter exactly and for the identical
        // reason: an integrity violation means this run's own proof that a
        // mutant was applied and observed is broken, so no survivor claim
        // from this run can be published as an annotation.
        if report.score == nil {
            lines.append(contentsOf: integrityAnnotations(report))
            return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        }

        for result in report.survivors {
            lines.append(warningAnnotation(for: result))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Annotations

    private func warningAnnotation(for result: MutationResult) -> String {
        let point = result.point
        let message = "Mutant survived: \(point.operatorID) changed "
            + "`\(point.originalText)` to `\(point.replacementText)` "
            + "and every test still passed. \(result.diagnosis) "
            + "[\(point.id)] — run `mutantkit inspect \(point.id.rawValue)` for the full diff and evidence."

        return command(
            "warning", file: point.file, line: point.line, column: point.column, message: message
        )
    }

    private func integrityAnnotations(_ report: RunReport) -> [String] {
        var lines: [String] = []
        let pointsByID = Dictionary(
            report.results.map { ($0.id, $0.point) },
            uniquingKeysWith: { first, _ in first }
        )

        for violation in report.integrity.violations {
            var message = "\(FailClosed.headline): \(violation.kind.rawValue) — \(violation.detail)"
            if let id = violation.mutationID {
                message += " — run `mutantkit inspect \(id.rawValue)` for details."
            }

            if let id = violation.mutationID, let point = pointsByID[id] {
                lines.append(command("error", file: point.file, line: point.line, column: point.column, message: message))
            } else {
                // No mutation to anchor to (a whole-run violation) — GitHub's
                // own syntax allows a bare `::error::message` with no
                // file/line properties at all, unlike XcodeReporter, which
                // has no equivalent "properties are optional" affordance and
                // must fabricate a `1:1` anchor instead.
                lines.append(command("error", file: nil, line: nil, column: nil, message: message))
            }
        }
        return lines
    }

    // MARK: Workflow-command construction

    private func command(_ level: String, file: String?, line: Int?, column: Int?, message: String) -> String {
        var properties: [String] = []
        if let file { properties.append("file=\(escapeProperty(file))") }
        if let line { properties.append("line=\(line)") }
        if let column { properties.append("col=\(column)") }

        let propertyList = properties.isEmpty ? "" : " " + properties.joined(separator: ",")
        return "::\(level)\(propertyList)::\(escapeData(message))"
    }

    /// Escaping for workflow-command *data* — the message after the final
    /// `::` — per GitHub's own documented order: `%` first (so escaping the
    /// other characters cannot itself introduce a fresh `%` that later
    /// escaping would double-encode), then CR, then LF.
    private func escapeData(_ text: String) -> String {
        text
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Escaping for a workflow-command *property value* (e.g. after
    /// `file=`): everything `escapeData` escapes, plus `,` and `:` — both of
    /// which are themselves the property-list delimiter syntax, so an
    /// unescaped one would truncate this property or start a fake one.
    private func escapeProperty(_ text: String) -> String {
        escapeData(text)
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: ":", with: "%3A")
    }
}
