/// A result that has passed verification — the only form a mutation's
/// outcome may take once it is eligible for scoring, caching,
/// checkpointing, or reporting.
///
/// Renamed from `VerifiedMutationVerdict` (ADR-0006 Stage 1): this is now
/// the *only* currency in the pipeline — `MutationResult`'s public
/// initializer is gone, so nothing downstream of the verifier constructs
/// anything else. `outcome` is not a stored field: it reads straight from
/// `proof`, so there is no way to construct a record whose outcome
/// disagrees with the proof backing it — the exact combination the
/// previous two-field shape allowed in principle, even though only the
/// verifier ever exercised it in practice.
///
/// This type has no public initializer: because it is `public` but
/// declares no explicit `init`, Swift synthesizes only the implicit
/// memberwise initializer, which is `internal` — construction is only
/// possible from within `MutationModel`. `MutationVerdictVerifier.verify`
/// (same module) is the only call site that actually does so.
///
/// `Encodable`, deliberately not `Decodable` (nor its `VerdictProof`/proof-
/// case payload types below): a synthesized `Decodable.init(from:)` is a
/// *second* construction path that does not go through the memberwise
/// init's module boundary at all, and — unlike the proof types' own
/// `init`s — carries none of their preconditions (`ExecutedMutationProof`'s
/// outcome-shape check, `ExclusionProof`'s), so untrusted bytes could
/// decode a record no real verification could ever have produced. Dropping
/// `Decodable` makes that a compile error everywhere, not a runtime
/// contract call sites have to remember to honor. Persistence
/// (`MutationResultCache`/`CheckpointStore`) decodes `MutationObservations`
/// instead and calls `MutationVerdictVerifier.verify` itself to obtain one
/// of these — see their own doc comments.
public struct VerifiedMutationRecord: Encodable, Sendable, Hashable {
    public let mutationRef: PlannedMutationRef
    public let proof: VerdictProof
    public let verificationVersion: Int

    public var outcome: MutationOutcome { proof.outcome }
}
