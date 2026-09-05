/// Proof that a build/test run actually reached and exercised the mutated
/// code, backing `.killedByAssertion`/`.killedByCrash`/`.verifiedTimeout`/
/// `.survived`.
///
/// `outcome` is stored, not re-derived by a caller, and is the *only* place
/// this proof's outcome lives — `VerifiedMutationRecord` no longer has a
/// separate `outcome` field that could disagree with it (ADR-0006 Stage 1:
/// a second review round found the original two-field shape combinable
/// into a mismatched pair, even though only the verifier ever constructed
/// one in practice). Wraps the existing `MutationEvidence` rather than
/// re-deriving a parallel proof shape: `MutationEvidence.applicationEvidence`
/// already carries the isolated/schemata activation proof this case exists
/// to certify.
public struct ExecutedMutationProof: Encodable, Sendable, Hashable {
    public let mutationRef: PlannedMutationRef
    public let outcome: MutationOutcome
    public let evidence: MutationEvidence
    public let testSummary: TestOutcomeSummary?
    /// The one-sentence human explanation — everything a reporter needs to
    /// display this verdict lives in the proof, so `MutationResult` can be
    /// projected from a `VerifiedMutationRecord` with no second, caller-
    /// supplied diagnosis that could drift from what the verifier actually
    /// decided.
    public let diagnosis: String

    /// `outcome` must be one of `.killedByAssertion`/`.killedByCrash`/
    /// `.verifiedTimeout`/`.survived` — enforced here as defense in depth,
    /// even though `MutationVerdictVerifier` is the only real caller.
    public init(mutationRef: PlannedMutationRef, outcome: MutationOutcome, evidence: MutationEvidence, testSummary: TestOutcomeSummary?, diagnosis: String) {
        precondition(
            [.killedByAssertion, .killedByCrash, .verifiedTimeout, .survived].contains(outcome),
            "ExecutedMutationProof.outcome must be a real execution outcome, got \(outcome)"
        )
        self.mutationRef = mutationRef
        self.outcome = outcome
        self.evidence = evidence
        self.testSummary = testSummary
        self.diagnosis = diagnosis
    }
}

/// The coverage-miss fast path's proof. Always `.noCoverage` — see
/// `VerdictProof.outcome`.
///
/// `coverageSource` (e.g. `"swift-package-codecov"`, `"xccov"`) is the one
/// positive fact this codebase's coverage readers actually produce today —
/// see `CoverageObservation.source`. The richer fields ADR-0005 item 3
/// originally sketched (coverage profile ID/tool version, original
/// location, profile source hash, test-selection digest) stay un-invented:
/// no coverage reader in this codebase produces any of them yet, and
/// adding fields with no real producer is exactly the speculative-
/// abstraction risk ADR-0004 (items 6, 8, 9) already declined.
public struct NoCoverageProof: Encodable, Sendable, Hashable {
    public let mutationRef: PlannedMutationRef
    public let sourceApplication: MutationEvidence
    /// `nil` when no coverage source claim was available to attach — still
    /// a legitimate `.noCoverage`, just with one less fact recorded about
    /// where the "never executed" claim came from.
    public let coverageSource: String?
    public let diagnosis: String

    public init(mutationRef: PlannedMutationRef, sourceApplication: MutationEvidence, coverageSource: String?, diagnosis: String) {
        self.mutationRef = mutationRef
        self.sourceApplication = sourceApplication
        self.coverageSource = coverageSource
        self.diagnosis = diagnosis
    }
}

/// Proof backing `.unviable`: the mutation was applied to source, but the
/// resulting build failed before any test could run. Always `.unviable` —
/// see `VerdictProof.outcome`.
public struct BuildFailureProof: Encodable, Sendable, Hashable {
    public let mutationRef: PlannedMutationRef
    public let diagnosis: String
    public let evidence: MutationEvidence?

    public init(mutationRef: PlannedMutationRef, diagnosis: String, evidence: MutationEvidence?) {
        self.mutationRef = mutationRef
        self.diagnosis = diagnosis
        self.evidence = evidence
    }
}

/// The catch-all for every outcome that is neither a positive execution
/// proof, a coverage-miss proof, nor a build failure: `.skipped`,
/// `.notApplied`, `.baselineMismatch`, `.timedOut`, `.flaky`,
/// `.infrastructureFailure`. None of these are cacheable or scorable
/// (`MutationOutcome.isCacheableResult`/`isScorable`), so this case
/// deliberately carries no strong proof shape of its own — only enough to
/// explain, for reporting, why no stronger proof applies. `outcome` is its
/// own field here (not implied by the case alone) because this is the one
/// case covering more than one possible outcome.
public struct ExclusionProof: Encodable, Sendable, Hashable {
    public let mutationRef: PlannedMutationRef
    public let outcome: MutationOutcome
    public let diagnosis: String
    /// `nil` when nothing was ever built or applied to produce evidence
    /// from (an early infrastructure exit); present whenever the mutation
    /// was at least applied, so a `.flaky`/`.timedOut` result still carries
    /// its confirming rebuild's own evidence (`crashConfirmation`/
    /// `timeoutConfirmation`) for display — losing it here would silently
    /// drop the very proof that explains *why* the pipeline disagreed with
    /// itself.
    public let evidence: MutationEvidence?

    public init(mutationRef: PlannedMutationRef, outcome: MutationOutcome, diagnosis: String, evidence: MutationEvidence? = nil) {
        precondition(
            ![MutationOutcome.killedByAssertion, .killedByCrash, .verifiedTimeout, .survived, .noCoverage, .unviable]
                .contains(outcome),
            "\(outcome) has its own VerdictProof case — it does not belong under .excluded"
        )
        self.mutationRef = mutationRef
        self.outcome = outcome
        self.diagnosis = diagnosis
        self.evidence = evidence
    }
}

/// What actually backs a `VerifiedMutationRecord`'s outcome — and the
/// *only* place that outcome lives. `VerifiedMutationRecord` has no
/// separate `outcome` field: `MutationVerdictVerifier` is the only place
/// that picks both a case and its outcome together, and nothing downstream
/// can construct a mismatched pair because there is no second field to
/// disagree with the first.
public enum VerdictProof: Encodable, Sendable, Hashable {
    case executed(ExecutedMutationProof)
    case noCoverage(NoCoverageProof)
    case unviable(BuildFailureProof)
    case excluded(ExclusionProof)

    public var mutationRef: PlannedMutationRef {
        switch self {
        case let .executed(proof): proof.mutationRef
        case let .noCoverage(proof): proof.mutationRef
        case let .unviable(proof): proof.mutationRef
        case let .excluded(proof): proof.mutationRef
        }
    }

    /// The evidence this proof is backed by, if any — `nil` for `.excluded`,
    /// which by definition has no strong proof of its own.
    public var evidence: MutationEvidence? {
        switch self {
        case let .executed(proof): proof.evidence
        case let .noCoverage(proof): proof.sourceApplication
        case let .unviable(proof): proof.evidence
        case let .excluded(proof): proof.evidence
        }
    }

    public var testSummary: TestOutcomeSummary? {
        if case let .executed(proof) = self { return proof.testSummary }
        return nil
    }

    public var diagnosis: String {
        switch self {
        case let .executed(proof): proof.diagnosis
        case let .noCoverage(proof): proof.diagnosis
        case let .unviable(proof): proof.diagnosis
        case let .excluded(proof): proof.diagnosis
        }
    }

    public var outcome: MutationOutcome {
        switch self {
        case let .executed(proof): proof.outcome
        case .noCoverage: .noCoverage
        case .unviable: .unviable
        case let .excluded(proof): proof.outcome
        }
    }
}
