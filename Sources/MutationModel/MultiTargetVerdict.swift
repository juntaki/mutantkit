import Foundation

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
/// discards the others' evidence (ADR-0006 Stage 1, second review round:
/// PR F's `mergeMultiTargetResults` did exactly that, keeping only the
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

    /// The current aggregation policy: kill in any target counts as killed
    /// overall (the product decision ADR-0005 PR F settled on). Ranked so
    /// a kill always wins over `.survived`, which wins over `.noCoverage`,
    /// which wins over a build failure, which wins over an environmental/
    /// indeterminate outcome. Bumping this requires bumping
    /// `aggregationPolicyVersion` alongside it.
    public static let currentAggregationPolicyVersion = 1

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
        perTarget.map(\.record.outcome).max { Self.rank($0) < Self.rank($1) } ?? .infrastructureFailure
    }

    private static func rank(_ outcome: MutationOutcome) -> Int {
        switch outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout: 5
        case .survived: 4
        case .noCoverage: 3
        case .unviable: 2
        case .flaky, .timedOut, .notApplied, .baselineMismatch: 1
        case .infrastructureFailure, .skipped: 0
        }
    }
}
