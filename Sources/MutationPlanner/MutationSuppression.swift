import Foundation
import MutationModel
import SwiftFrontend

/// One explicit reason to exclude a concrete mutation from execution.
///
/// This is intentionally separate from source excludes: source excludes prevent
/// discovery entirely, while suppression keeps the mutation visible in the plan
/// as `.userRequested`, preserving `discovered == planned + skipped` and making
/// the omission auditable.
public enum MutationSuppressionRule: Sendable, Hashable {
    case mutationID(String)
    case operatorID(String)
    case fileGlob(String)
    case fileLine(file: String, line: Int)
    /// A single line, scoped to one operator — what an inline
    /// `// mutantkit:disable-next-line <operatorID>` comment produces (see
    /// `InlineMutationSuppressionScanner`). Distinct from `fileLine`, which
    /// suppresses every operator on that line: an inline comment that names
    /// an operator must not silently also suppress a sibling mutation from
    /// a different operator anchored at the same line.
    case fileLineOperator(file: String, line: Int, operatorID: String)

    fileprivate var description: String {
        switch self {
        case let .mutationID(id): "id:\(id)"
        case let .operatorID(id): "operator:\(id)"
        case let .fileGlob(pattern): "file:\(pattern)"
        case let .fileLine(file, line): "line:\(file):\(line)"
        case let .fileLineOperator(file, line, operatorID): "line:\(file):\(line) operator:\(operatorID)"
        }
    }

    fileprivate func matches(_ point: MutationPoint) -> Bool {
        switch self {
        case let .mutationID(id):
            point.id.rawValue == id
        case let .operatorID(id):
            point.operatorID == id
        case let .fileGlob(pattern):
            // v1 contract (2026-09-12): MutantKit's own `Glob` grammar
            // (`SourceFileWalker.swift`), not POSIX `fnmatch` — a bare `*`
            // never crosses a `/` here, unlike `fnmatch(pattern, path, 0)`
            // without `FNM_PATHNAME`. Deliberately `Glob.matches`, not
            // `Glob.matchesAny`: naming a directory in `file:` does not
            // implicitly cover its contents the way `sources.exclude`'s
            // ancestor convenience does — that is a distinct, additive
            // source-selection-layer semantic this rule does not opt into,
            // so a descendant must be named explicitly (`Sources/Generated/**`).
            Glob.matches(pattern: pattern, path: point.file)
        case let .fileLine(file, line):
            point.file == file && point.line == line
        case let .fileLineOperator(file, line, operatorID):
            point.file == file && point.line == line && point.operatorID == operatorID
        }
    }
}

public struct MutationSuppressionSet: Sendable, Hashable {
    public let rules: [MutationSuppressionRule]

    public init(rules: [MutationSuppressionRule]) {
        self.rules = rules
    }

    /// Parses the compact `.mutantkitignore` format:
    ///
    ///     id:mut_abcd...
    ///     operator:swift.core.logical-connector-replacement
    ///     file:Sources/Generated/**
    ///     line:Sources/Foo.swift:42
    ///
    /// Blank lines and `#` comments are ignored. Unknown lines are rejected so a
    /// typo cannot silently turn a requested suppression into an executed mutant.
    public static func parse(_ text: String) throws -> MutationSuppressionSet {
        var rules: [MutationSuppressionRule] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("id:") {
                let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw MutationSuppressionError.invalidLine(offset + 1, line) }
                rules.append(.mutationID(value))
            } else if line.hasPrefix("operator:") {
                let value = String(line.dropFirst("operator:".count)).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw MutationSuppressionError.invalidLine(offset + 1, line) }
                rules.append(.operatorID(value))
            } else if line.hasPrefix("file:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw MutationSuppressionError.invalidLine(offset + 1, line) }
                rules.append(.fileGlob(value))
            } else if line.hasPrefix("line:") {
                let value = String(line.dropFirst(5))
                guard let colon = value.lastIndex(of: ":"),
                      let number = Int(value[value.index(after: colon)...]),
                      number > 0
                else { throw MutationSuppressionError.invalidLine(offset + 1, line) }
                let file = String(value[..<colon])
                guard !file.isEmpty else { throw MutationSuppressionError.invalidLine(offset + 1, line) }
                rules.append(.fileLine(file: file, line: number))
            } else {
                throw MutationSuppressionError.invalidLine(offset + 1, line)
            }
        }
        return MutationSuppressionSet(rules: rules)
    }

    public func matchingRule(for point: MutationPoint) -> MutationSuppressionRule? {
        rules.first { $0.matches(point) }
    }

    /// The suppression gate: moves every point a rule matches to the explicit
    /// skipped ledger (`.userRequested`, naming the rule) and returns the rest.
    /// Pure and order-preserving; the caller sorts and derives plan identity.
    public func apply(
        to points: [MutationPoint],
        _ skipped: [SkippedMutation]
    ) -> ([MutationPoint], [SkippedMutation]) {
        guard !rules.isEmpty else { return (points, skipped) }

        var kept: [MutationPoint] = []
        var skipped = skipped
        for point in points {
            if let rule = matchingRule(for: point) {
                skipped.append(SkippedMutation(
                    id: point.id,
                    file: point.file,
                    reason: .userRequested,
                    detail: "Suppressed by rule `\(rule.description)` "
                        + "(from .mutantkitignore or an inline `mutantkit:disable` source comment).",
                    operatorID: point.operatorID
                ))
            } else {
                kept.append(point)
            }
        }
        return (kept, skipped)
    }
}

extension MutationSuppressionSet {
    /// Turns each file's inline directives into suppression rules, in path
    /// order. Malformed comments and unknown operator IDs throw.
    static func inlineRules(
        _ scans: [String: InlineSuppressionScan],
        registry: MutationRegistry
    ) throws -> [MutationSuppressionRule] {
        let knownIDs = Set(registry.allDescriptors.map(\.id))
        var rules: [MutationSuppressionRule] = []
        for file in scans.keys.sorted() {
            let scan = scans[file]!
            if let bad = scan.malformed.first {
                throw PlannerError.invalidSuppressionDirective(
                    file: file, line: bad.commentLine,
                    detail: "`\(bad.text)` is not `mutantkit:disable-next-line` or `mutantkit:disable-line` "
                        + "optionally followed by comma-separated operator IDs."
                )
            }
            for directive in scan.directives {
                if let unknown = directive.operatorIDs.first(where: { !knownIDs.contains($0) }) {
                    throw PlannerError.invalidSuppressionDirective(
                        file: file, line: directive.commentLine,
                        detail: "unknown operator ID `\(unknown)`."
                    )
                }
                if directive.operatorIDs.isEmpty {
                    rules.append(.fileLine(file: file, line: directive.targetLine))
                } else {
                    rules += directive.operatorIDs.map {
                        .fileLineOperator(file: file, line: directive.targetLine, operatorID: $0)
                    }
                }
            }
        }
        return rules
    }
}

public enum MutationSuppressionError: Error, CustomStringConvertible {
    case invalidLine(Int, String)

    public var description: String {
        switch self {
        case let .invalidLine(number, line):
            "Invalid .mutantkitignore rule on line \(number): `\(line)`. Expected id:, operator:, file:, or line:<file>:<line>."
        }
    }
}
