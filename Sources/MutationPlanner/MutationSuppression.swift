import Darwin
import Foundation
import MutationModel

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
            fnmatch(pattern, point.file, 0) == 0
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

    /// Returns a new plan with suppressed mutations moved to the explicit skipped
    /// ledger. The source/operator metadata remains unchanged; only the work set
    /// and plan identity change.
    public func applying(to plan: MutationPlan) -> MutationPlan {
        guard !rules.isEmpty else { return plan }

        var kept: [MutationPoint] = []
        var skipped = plan.skipped
        var suppressedIDs: [String] = []

        for point in plan.mutations {
            if let rule = matchingRule(for: point) {
                suppressedIDs.append(point.id.rawValue)
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

        skipped.sort { lhs, rhs in
            lhs.id == rhs.id ? lhs.reason.rawValue < rhs.reason.rawValue : lhs.id < rhs.id
        }
        let identity = ([plan.planID] + suppressedIDs.sorted()).joined(separator: "\u{1F}")

        return MutationPlan(
            planID: "plan_" + ContentHash.shortDigest(of: identity),
            createdAt: plan.createdAt,
            projectRoot: plan.projectRoot,
            toolchain: plan.toolchain,
            configurationHash: plan.configurationHash,
            sourceFileHashes: plan.sourceFileHashes,
            mutations: kept,
            skipped: skipped,
            operators: plan.operators
        )
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
