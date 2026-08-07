import Foundation
import MutationModel

/// Emits diagnostics in the form Xcode's build log parser recognises, so
/// surviving mutants land in the issue navigator next to the code that needs a
/// test.
///
/// The format Xcode matches is exact and undocumented-by-contract:
/// `<file>:<line>:<column>: warning: <message>`
/// Anything else — a stray prefix, a missing column — is treated as plain log
/// text and silently disappears from the navigator.
public struct XcodeReporter: Reporter {
    private let useAbsolutePaths: Bool

    /// - Parameter useAbsolutePaths: Xcode resolves relative paths against the
    ///   build's working directory, which is not the project root for most
    ///   schemes. Absolute paths are what actually click through.
    public init(useAbsolutePaths: Bool = true) {
        self.useAbsolutePaths = useAbsolutePaths
    }

    public func render(_ report: RunReport) throws -> String {
        var lines: [String] = []

        // Fail-closed: with a broken run we cannot claim a mutant survived, so
        // we emit the integrity violations instead. Publishing survivor warnings
        // from an untrustworthy run would put unverified claims in front of a
        // developer with the full authority of an Xcode issue.
        if report.score == nil {
            lines.append(contentsOf: integrityDiagnostics(report))
            return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }

        for result in report.survivors {
            lines.append(diagnostic(for: result, in: report))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Diagnostics

    private func diagnostic(for result: MutationResult, in report: RunReport) -> String {
        let point = result.point
        let message = "Mutant survived: \(point.operatorID) changed "
            + "`\(singleLine(point.originalText))` to `\(singleLine(point.replacementText))` "
            + "and every test still passed. \(result.diagnosis) [\(point.id)]"

        return "\(path(for: point.file, in: report)):\(point.line):\(point.column): warning: \(message)"
    }

    private func integrityDiagnostics(_ report: RunReport) -> [String] {
        var lines: [String] = []
        let pointsByID = Dictionary(
            report.results.map { ($0.id, $0.point) },
            uniquingKeysWith: { first, _ in first }
        )

        for violation in report.integrity.violations {
            let message = "\(FailClosed.headline): \(violation.kind.rawValue) — \(singleLine(violation.detail))"

            // Anchor to the offending mutation when the violation names one;
            // otherwise the whole run is at fault and there is no honest line
            // number to point at.
            if let id = violation.mutationID, let point = pointsByID[id] {
                lines.append("\(path(for: point.file, in: report)):\(point.line):\(point.column): warning: \(message)")
            } else {
                lines.append("\(report.projectRoot):1:1: warning: \(message)")
            }
        }
        return lines
    }

    // MARK: Helpers

    private func path(for file: String, in report: RunReport) -> String {
        guard useAbsolutePaths else { return file }
        return URL(fileURLWithPath: report.projectRoot)
            .appendingPathComponent(file)
            .path
    }

    /// One diagnostic is one line by definition; a newline inside the message
    /// would split it into an unparseable fragment plus loose log text.
    private func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
