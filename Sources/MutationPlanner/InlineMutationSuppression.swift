import Foundation

/// Recognizes `// mutantkit:disable-next-line` / `// mutantkit:disable-line`
/// comments directly in source, and turns each into the same
/// `MutationSuppressionRule` the `.mutantkitignore` file already produces —
/// so an inline directive gets the identical audit trail (a `skipped` ledger
/// entry with `.userRequested` and a `detail` naming the exact rule), never a
/// silent drop.
///
/// Deliberately comment-based, not an attribute like `@MutationTestingIgnored`:
/// a comment needs no import, works identically in a `.swift` file with no
/// macro dependency, and cannot change what the compiler sees. This is a plain
/// line scan over raw source text, not a `SwiftSyntax` pass — discovery has
/// already turned source into `MutationPoint`s with 1-based `line` numbers by
/// the time this runs, and matching against those is exactly what
/// `MutationSuppressionRule.fileLine`/`.fileLineOperator` already do.
public enum InlineMutationSuppressionScanner {
    /// `// mutantkit:disable-next-line`, `// mutantkit:disable-line`, each
    /// optionally followed by a comma-separated operator ID list. With no
    /// list, every operator is suppressed on the target line — matching
    /// `.mutantkitignore`'s own `line:<file>:<line>` semantics exactly.
    private static let pattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"//\s*mutantkit:disable-(next-line|line)\b[ \t]*([^\n]*)"#
    )

    /// `file` is the plan-relative path already recorded on every
    /// `MutationPoint` for this source — callers must pass the same string a
    /// discovered point's `.file` uses, or the rule will never match.
    public static func scan(source: String, file: String) -> [MutationSuppressionRule] {
        var rules: [MutationSuppressionRule] = []
        let lines = source.components(separatedBy: "\n")

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let nsLine = rawLine as NSString
            guard let match = pattern.firstMatch(
                in: rawLine, range: NSRange(location: 0, length: nsLine.length)
            ) else { continue }

            let kind = nsLine.substring(with: match.range(at: 1))
            let targetLine = kind == "next-line" ? lineNumber + 1 : lineNumber
            guard targetLine <= lines.count else { continue }

            let operatorList = nsLine.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            let operatorIDs = operatorList
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if operatorIDs.isEmpty {
                rules.append(.fileLine(file: file, line: targetLine))
            } else {
                for operatorID in operatorIDs {
                    rules.append(.fileLineOperator(file: file, line: targetLine, operatorID: operatorID))
                }
            }
        }

        return rules
    }
}
