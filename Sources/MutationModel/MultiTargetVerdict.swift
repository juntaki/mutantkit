/// Which target a `TargetVerdict` belongs to — stable, sortable identity so
/// `MultiTargetVerdict.perTarget` has one deterministic order regardless of
/// which target's chunk happened to finish evaluating first.
public struct TargetExecutionIdentity: Codable, Sendable, Hashable, Comparable {
    public let projectIdentity: String
    public let target: String
    public let module: String
    public let product: String

    public init(projectIdentity: String, target: String, module: String, product: String) {
        self.projectIdentity = projectIdentity
        self.target = target
        self.module = module
        self.product = product
    }

    public static func < (lhs: TargetExecutionIdentity, rhs: TargetExecutionIdentity) -> Bool {
        (lhs.projectIdentity, lhs.target, lhs.module, lhs.product) <
            (rhs.projectIdentity, rhs.target, rhs.module, rhs.product)
    }
}

/// One target's own independent verdict for a mutation embedded into more
/// than one target's build.
public struct TargetVerdict: Encodable, Sendable, Hashable {
    public let targetIdentity: TargetExecutionIdentity
    public let record: VerifiedMutationRecord

    public init(targetIdentity: TargetExecutionIdentity, record: VerifiedMutationRecord) {
        self.targetIdentity = targetIdentity
        self.record = record
    }
}

/// A mutation's full multi-target verdict — every target's own
/// `VerifiedMutationRecord`, never collapsed to a single winner that
/// discards the others' evidence (the authoritative verdict pipeline, second review round:
/// the earlier multi-target embedding's `mergeMultiTargetResults` did exactly that, keeping only the
/// highest-ranked target's `MutationResult` and losing every other
/// target's proof permanently).
public struct MultiTargetVerdict: Encodable, Sendable, Hashable {
    public let mutationRef: PlannedMutationRef
    /// The rank policy version `aggregateOutcome` was derived under — see
    /// `MultiTargetVerdict.aggregatePolicyVersion`. Recorded so a future
    /// change to the ranking itself does not silently reinterpret an
    /// already-persisted verdict as meaning something the policy in effect
    /// when it was computed did not say.
    public let aggregationPolicyVersion: Int
    /// Every target's own verdict, sorted by `TargetExecutionIdentity` —
    /// never insertion order, which depends on chunk-processing order and
    /// is not reproducible run to run.
    public let perTarget: [TargetVerdict]

    /// The current aggregation policy:
    ///
    /// 1. A kill in any placement (`isKillLike`) wins: the mutation is killed overall and needs nothing
    ///    further.
    /// 2. With no kill, if every placement is scorable (`isScorable`), the usual ranking applies:
    ///    `.survived` over `.noCoverage`.
    /// 3. With no kill and at least one non-scorable placement, the aggregate is that non-scorable outcome,
    ///    never `.survived` or `.noCoverage`, and `requiresIsolatedFallback` asks for the whole MutationID to
    ///    be re-run once in isolated mode.
    /// 4. Isolated mode builds and tests the whole project once per MutationID and never produces a
    ///    `MultiTargetVerdict`, so a re-run that is still not scorable is reported as such, with no second
    ///    fallback.
    ///
    /// Version 1 ranked `.survived` above every non-scorable outcome, so a survived placement hid a sibling
    /// whose own verdict could not be trusted. Bumping this requires bumping `aggregationPolicyVersion`
    /// alongside it.
    public static let currentAggregationPolicyVersion = 2

    /// A `MultiTargetVerdict` claims every entry in `perTarget` is this same
    /// mutation's own verdict from a distinct target — a claim callers must
    /// prove, not merely assert, since `ResultLedger`'s "the ledger's key
    /// always matches the entry's own identity" guarantee only holds if
    /// nothing upstream can construct a verdict whose outer `mutationRef`
    /// disagrees with an inner record it aggregates, or whose `perTarget`
    /// secretly names the same target twice.
    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case mutationRefMismatch(expected: PlannedMutationRef, actual: PlannedMutationRef)
        case duplicateTarget(TargetExecutionIdentity)

        public var description: String {
            switch self {
            case .empty:
                "MultiTargetVerdict needs at least one target's verdict."
            case let .mutationRefMismatch(expected, actual):
                "TargetVerdict.record.mutationRef (\(actual)) does not match the verdict's own mutationRef (\(expected))."
            case let .duplicateTarget(identity):
                "\(identity) appears more than once in a single MultiTargetVerdict."
            }
        }
    }

    public init(mutationRef: PlannedMutationRef, perTarget: [TargetVerdict]) throws {
        guard !perTarget.isEmpty else { throw ValidationError.empty }

        for target in perTarget where target.record.mutationRef != mutationRef {
            throw ValidationError.mutationRefMismatch(expected: mutationRef, actual: target.record.mutationRef)
        }

        var seenIdentities = Set<TargetExecutionIdentity>()
        for target in perTarget where !seenIdentities.insert(target.targetIdentity).inserted {
            throw ValidationError.duplicateTarget(target.targetIdentity)
        }

        self.mutationRef = mutationRef
        aggregationPolicyVersion = Self.currentAggregationPolicyVersion
        self.perTarget = perTarget.sorted { $0.targetIdentity < $1.targetIdentity }
    }

    /// Derived, never independently settable — `aggregateOutcome` can only
    /// ever be a real function of `perTarget`, not a value some caller set
    /// alongside it that could disagree.
    public var aggregateOutcome: MutationOutcome {
        let outcomes = perTarget.map(\.record.outcome)
        let byRank: (MutationOutcome, MutationOutcome) -> Bool = { Self.rank($0) < Self.rank($1) }
        if let kill = outcomes.filter(Self.isKillLike).max(by: byRank) { return kill }
        if let unscorable = outcomes.filter({ !Self.isScorable($0) }).max(by: byRank) { return unscorable }
        return outcomes.max(by: byRank) ?? .infrastructureFailure
    }

    /// True when this is a genuine multi-target aggregate (more than one placement), no placement killed, and
    /// at least one placement is not scorable. Such a MutationID must not be scored from these placements; it
    /// goes to isolated mode as a whole instead.
    public var requiresIsolatedFallback: Bool {
        guard perTarget.count > 1 else { return false }
        let outcomes = perTarget.map(\.record.outcome)
        return !outcomes.contains(where: Self.isKillLike) && !outcomes.allSatisfy(Self.isScorable)
    }

    /// An outcome that settles the mutation as caught.
    public static func isKillLike(_ outcome: MutationOutcome) -> Bool {
        switch outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout: true
        case .survived, .noCoverage, .unviable, .timedOut, .flaky, .notApplied, .baselineMismatch, .notMaterialized,
             .infrastructureFailure, .skipped: false
        }
    }

    /// An outcome that is evidence about the test suite either way. Every other outcome says nothing about
    /// whether the tests would catch the mutation in that placement.
    public static func isScorable(_ outcome: MutationOutcome) -> Bool {
        switch outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived, .noCoverage: true
        case .unviable, .timedOut, .flaky, .notApplied, .baselineMismatch, .notMaterialized, .infrastructureFailure,
             .skipped: false
        }
    }

    private static func rank(_ outcome: MutationOutcome) -> Int {
        switch outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout: 5
        case .survived: 4
        case .noCoverage: 3
        case .unviable: 2
        case .flaky, .timedOut, .notApplied, .baselineMismatch, .notMaterialized: 1
        case .infrastructureFailure, .skipped: 0
        }
    }
}
