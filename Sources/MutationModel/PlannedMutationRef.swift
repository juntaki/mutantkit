import Foundation

/// A full reference to one specific mutation's content — not just its
/// `MutationID`.
///
/// ADR-0005's problem: today, result/plan/evidence reconciliation is mostly
/// by `MutationID` set membership (see `IntegrityChecker.check`). Nothing
/// confirms that a result, its plan entry, and any proof attached to it all
/// describe the *same* mutation content — only that some `MutationID`
/// happens to appear on all of them. `pointDigest` closes that: it is a hash
/// of every field that describes what the mutation actually is, so two
/// pieces of proof can only share a `PlannedMutationRef` if they agree on
/// the mutation's real content, not merely its ID.
public struct PlannedMutationRef: Codable, Sendable, Hashable {
    public let planID: String
    public let workUnitID: String
    public let mutationID: MutationID
    public let pointDigest: String

    public init(planID: String, workUnitID: String, mutationID: MutationID, pointDigest: String) {
        self.planID = planID
        self.workUnitID = workUnitID
        self.mutationID = mutationID
        self.pointDigest = pointDigest
    }

    /// Builds the ref for `point`, computing `pointDigest` from exactly the
    /// fields that describe the mutation's content: file, byte range,
    /// original/replacement text, the source file's hash, the operator's
    /// identity, the enclosing declaration, and the execution mode.
    ///
    /// Deliberately excludes discovery-time metadata that can legitimately
    /// differ between two honest re-discoveries of the same edit —
    /// `confidence`, `line`/`column` (display only, never an anchor), and
    /// the anchor token fingerprints (derived from, not independent of, the
    /// fields already included).
    public static func forPoint(_ point: MutationPoint, planID: String, workUnitID: String) -> PlannedMutationRef {
        PlannedMutationRef(
            planID: planID,
            workUnitID: workUnitID,
            mutationID: point.id,
            pointDigest: pointDigest(for: point)
        )
    }

    /// Exposed for callers (proof constructors) that need to compare a
    /// point against an already-built ref without constructing a whole new
    /// one.
    public static func pointDigest(for point: MutationPoint) -> String {
        let canonical = CanonicalPointContent(
            file: point.file,
            utf8RangeStart: point.utf8Range.start,
            utf8RangeEnd: point.utf8Range.end,
            originalText: point.originalText,
            replacementText: point.replacementText,
            sourceFileHash: point.sourceFileHash,
            operatorID: point.operatorID,
            operatorVersion: point.operatorVersion,
            enclosingDeclaration: point.enclosingDeclaration.path,
            executionMode: point.executionMode.rawValue
        )
        guard let data = try? MutationPlan.encoder().encode(canonical) else {
            preconditionFailure("CanonicalPointContent must always encode: it has no failable field types.")
        }
        return ContentHash.of(data)
    }

    /// Field order does not matter for correctness (`MutationPlan.encoder()`
    /// sorts keys), only completeness: every case here must match the field
    /// list this type's doc comment promises.
    private struct CanonicalPointContent: Codable {
        let file: String
        let utf8RangeStart: Int
        let utf8RangeEnd: Int
        let originalText: String
        let replacementText: String
        let sourceFileHash: String
        let operatorID: String
        let operatorVersion: Int
        let enclosingDeclaration: [String]
        let executionMode: String
    }
}
