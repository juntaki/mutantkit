/// The scheme a plan's `MutationID`s were derived under.
///
/// An ID is a claim about how it was computed. Changing any input (declaration
/// granularity, replacement variant, ...) would silently re-map every
/// historical ID, so such a change is a new case here, never an edit to an
/// existing one. A plan records its version; a reader that does not implement
/// that version refuses the plan (`PlanError.unsupportedIdentityVersion`)
/// instead of recomputing IDs under a different scheme.
public enum MutationIdentityVersion: Int, Codable, Sendable, Comparable {
    /// The original scheme; also what a plan with no recorded version means.
    case v1 = 1

    /// The scheme this build derives new IDs under.
    public static let current: MutationIdentityVersion = .v1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Deriving the ID from an explicit, ordered, delimited string keeps the
    /// hash inputs auditable — a reader can reconstruct the preimage by hand.
    /// The `\u{1F}` (unit separator) delimiter cannot appear in any component.
    public func deriveID(
        filePath: String,
        declaration: DeclarationIdentity,
        operatorID: String,
        operatorVersion: Int,
        originalTokenFingerprint: String,
        occurrenceIndex: Int
    ) -> MutationID {
        let separator = "\u{1F}"
        let preimage = [
            "v\(rawValue)",
            filePath,
            declaration.description,
            operatorID,
            String(operatorVersion),
            originalTokenFingerprint,
            String(occurrenceIndex)
        ].joined(separator: separator)

        return MutationID(rawValue: "mut_" + ContentHash.shortDigest(of: preimage))
    }
}

/// A content-derived identifier for a single mutation.
///
/// The ID is a hash of *what the mutation is*, never of *when we found it*. It
/// contains no global counter and no `SwiftSyntax` node identity, so it is
/// unchanged by parallel discovery, by re-parsing, by shuffling shards across
/// machines, and by edits to unrelated parts of the same file.
///
/// Inputs, per the design:
///
///   relative file path
/// + enclosing declaration identity
/// + operator ID
/// + operator version
/// + original token fingerprint
/// + local occurrence index
///
/// Every input is stored on the `MutationPoint` that carries the ID, so `verify`
/// can recompute an ID from the plan and reject any file whose IDs do not
/// reproduce.
///
/// **v0.5 Stable Contracts: what a Swift toolchain/SwiftSyntax upgrade does
/// to an existing ID is explicitly *not* guaranteed.** None of the inputs
/// above include a toolchain or parser version, so an upgrade is not itself
/// an ID input — but nothing here proves a newer SwiftSyntax parses a given
/// file's structure identically to an older one in every case (a node
/// reclassified, trivia attached differently). If it does not, the
/// `declaration`/token-fingerprint inputs derived from that parse could
/// change even though the source bytes did not, which would change the ID.
/// Baselines pinned across a toolchain upgrade are not proven stable by
/// this design; `MutationPoint.recomputedID`'s check (see `verify`) is what
/// would surface such a change, as an ID-mismatch failure rather than a
/// silent misattribution.
public struct MutationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

extension MutationID: Codable {
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension MutationID: Comparable {
    /// Sorting by ID is what makes run order deterministic without a seed.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
