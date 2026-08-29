import Foundation

// MARK: - Confidence

/// How much we trust an operator's judgement that a candidate is a real,
/// compilable, meaningful mutation.
///
/// Confidence drives run profiles: pull requests run `.high` only, nightly adds
/// `.medium`, and `.experimental` is opt-in because those operators are known to
/// produce flaky or equivalent mutants.
public enum MutationConfidence: String, Codable, Sendable, CaseIterable, Comparable {
    case high
    case medium
    case experimental

    private var rank: Int {
        switch self {
        case .high: 2
        case .medium: 1
        case .experimental: 0
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Execution mode

/// How a mutant is meant to be materialized.
///
/// v0.1 only ever produces `.isolated`. `.schemata` exists in the model now so
/// that plan files written today stay readable once schemata lands, and so the
/// differential test in Phase 4 has something to compare against.
public enum ExecutionMode: String, Codable, Sendable {
    /// One mutant per source rewrite, per build. The reference implementation.
    case isolated
    /// Many mutants in one build, selected at runtime. Optimization only.
    case schemata
}

// MARK: - Byte range

/// A half-open UTF-8 byte range within a source file.
///
/// Byte offsets — not `SwiftSyntax` node identity — are what anchors a mutation
/// to its source. Offsets survive serialization, re-parsing and process
/// boundaries; node identity does not, which is the defect this whole design
/// exists to avoid.
public struct ByteRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        precondition(start >= 0, "byte range start must be non-negative")
        precondition(end >= start, "byte range end must not precede start")
        self.start = start
        self.end = end
    }

    public init(_ range: Range<Int>) {
        self.init(start: range.lowerBound, end: range.upperBound)
    }

    public var range: Range<Int> { start ..< end }
    public var length: Int { end - start }
    public var description: String { "\(start)..<\(end)" }
}

// MARK: - Declaration identity

/// A stable, human-meaningful name for the declaration enclosing a mutation.
///
/// This is deliberately *not* a USR: it must be computable from syntax alone,
/// without a type checker or an index, so that discovery stays cheap and
/// offline. It only needs to be stable enough to keep mutation IDs steady across
/// edits elsewhere in the file.
public struct DeclarationIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Nesting path from outermost to innermost, e.g. `["Cart", "total(for:)"]`.
    public let path: [String]

    public init(path: [String]) {
        self.path = path
    }

    /// Used when a mutation sits outside any declaration (top-level code).
    public static let topLevel = DeclarationIdentity(path: ["<top-level>"])

    public var description: String { path.joined(separator: ".") }

    public func appending(_ component: String) -> DeclarationIdentity {
        DeclarationIdentity(path: path + [component])
    }
}

// MARK: - Command records

/// An executed command, recorded exactly as it was spawned.
///
/// Arguments stay a list because the process layer never builds shell strings
/// (see SECURITY.md); recording the same shape we executed keeps `reproduce`
/// honest rather than approximate.
public struct CommandRecord: Hashable, Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    /// Only variables the tool itself set, and only after redaction.
    public let environmentOverrides: [String: String]
    public let exitCode: Int32?
    public let durationSeconds: Double?

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environmentOverrides: [String: String] = [:],
        exitCode: Int32? = nil,
        durationSeconds: Double? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
    }

    /// Copy-pasteable rendering. For display only — never fed back to a shell.
    public var displayString: String {
        ([executable] + arguments).map { arg in
            arg.contains(where: { $0 == " " || $0 == "\"" }) ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }
}

// MARK: - Schema versions

/// Versions embedded in every artifact the tool writes.
///
/// A reader that does not recognise a version must refuse the file rather than
/// guess at its shape.
public enum SchemaVersion {
    public static let plan = 1
    public static let result = 1
    /// Bumped to 2 for ADR-0005 PR F: `SchemataPlacement.embedded` carries a
    /// list of per-target placements now, not a single flat set of fields —
    /// a plan written under schemaVersion 1 cannot decode against this
    /// type, by design (`SchemataPlan.decodeAndValidate`'s own
    /// `executionContext` check refuses a `schemaVersion` mismatch rather
    /// than guess at how to reinterpret an incompatible shape).
    public static let schemataPlan = 2
    /// One constant per agent-facing `--json` output type, not one shared
    /// constant across them: each type's shape can change independently
    /// (as `plan`/`result`/`schemataPlan` already do above), so a reader
    /// that only understands `AgentEvidenceReport` v1 must not be misled by
    /// a version bump that actually belongs to `RunHistoryRecord`.
    public static let agentEvidenceReport = 1
    public static let runHistoryRecord = 1
    public static let operatorCatalogEntry = 1
}
