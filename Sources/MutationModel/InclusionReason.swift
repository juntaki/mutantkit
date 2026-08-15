/// A machine-readable explanation of why one specific mutant was included in
/// a budget-limited plan — the symmetric counterpart to `SkippedMutation`'s
/// `detail` (which explains exclusions), closing ADR-0007 B.1 invariant 6.
///
/// Per ADR-0007 B.7's frozen schema (Choice 4), this is deliberately
/// minimal: no field Budget Selection v2's allocator doesn't already
/// compute, no timestamp, no raw score — a shard-count-independent,
/// resume-stable, mechanically derivable record. Lives in `MutationModel`
/// (not `MutationPlanner`, where the v2 allocator itself lives) because
/// `MutationPlan` — which persists one of these per v2-selected mutant —
/// cannot depend on `MutationPlanner` without inverting the module graph.
///
/// Only produced under `budget.selection: v2` (ADR-0007 B.8/Choice 1); a
/// v1 plan's `MutationPlan.budgetInclusionReasons` is always empty.
public struct InclusionReason: Codable, Sendable, Hashable {
    public enum ReasonCode: String, Codable, Sendable {
        /// This mutant filled a slot granted during Phase 1 (minimum
        /// reservation).
        case minimumReservation
        /// This mutant filled a slot granted during Phase 2 (largest-
        /// remainder proportional distribution).
        case proportionalRemainder
    }

    /// The selected mutant this record describes.
    public let mutationID: MutationID
    /// Drawn from the *terminal* allocation call's own phase split for this
    /// mutant's innermost stratum — never a parent stratum's split, even
    /// when an inner dimension is configured (ADR-0007 B.7, normatively).
    public let reasonCode: ReasonCode
    /// The stratum identity chain: one element for a single-level (outer
    /// only) allocation, `[outerStratumID, innerStratumID]` when an inner
    /// dimension is configured.
    public let stratumPath: [String]
    /// This mutant's 0-based index in the terminal stratum's own
    /// deterministic output order.
    public let selectionOrdinal: Int

    public init(mutationID: MutationID, reasonCode: ReasonCode, stratumPath: [String], selectionOrdinal: Int) {
        self.mutationID = mutationID
        self.reasonCode = reasonCode
        self.stratumPath = stratumPath
        self.selectionOrdinal = selectionOrdinal
    }
}
