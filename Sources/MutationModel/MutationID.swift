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

    /// Deriving the ID from an explicit, ordered, delimited string keeps the
    /// hash inputs auditable — a reader can reconstruct the preimage by hand.
    /// The `\u{1F}` (unit separator) delimiter cannot appear in any component.
    public static func compute(
        filePath: String,
        declaration: DeclarationIdentity,
        operatorID: String,
        operatorVersion: Int,
        originalTokenFingerprint: String,
        occurrenceIndex: Int
    ) -> MutationID {
        let separator = "\u{1F}"
        let preimage = [
            "v1",
            filePath,
            declaration.description,
            operatorID,
            String(operatorVersion),
            originalTokenFingerprint,
            String(occurrenceIndex)
        ].joined(separator: separator)

        return MutationID(rawValue: "mut_" + ContentHash.shortDigest(of: preimage))
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
