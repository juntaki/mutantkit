import Foundation

/// Describes the toolchain a plan was produced with.
///
/// Recorded so a plan executed on a different machine can be rejected — or at
/// least reported — rather than silently producing results that will not
/// reproduce.
public struct ToolchainFingerprint: Codable, Sendable, Hashable {
    public let toolVersion: String
    public let toolCommitSHA: String?
    public let swiftVersion: String
    public let swiftSyntaxVersion: String
    public let xcodeVersion: String?

    public init(
        toolVersion: String,
        toolCommitSHA: String?,
        swiftVersion: String,
        swiftSyntaxVersion: String,
        xcodeVersion: String?
    ) {
        self.toolVersion = toolVersion
        self.toolCommitSHA = toolCommitSHA
        self.swiftVersion = swiftVersion
        self.swiftSyntaxVersion = swiftSyntaxVersion
        self.xcodeVersion = xcodeVersion
    }
}

/// A mutation the planner found but deliberately will not run, and why.
///
/// Skips are part of the plan rather than a silent omission: the integrity
/// invariant `planned = applied + skipped` can only be checked if every dropped
/// mutation is accounted for.
public struct SkippedMutation: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable {
        case budgetExceeded
        case operatorDisabled
        case confidenceBelowProfile
        case fileExcluded
        case outsideDiff
        case userRequested
    }

    public let id: MutationID
    public let file: String
    public let reason: Reason
    public let detail: String?
    /// The operator that would have produced this mutation, when known at the
    /// gate that skipped it. `nil` only for plans serialized before this field
    /// existed — every gate that skips a `MutationPoint` today has its
    /// `operatorID` on hand and records it, which is what lets a report
    /// reconstruct discovered/eligible/selected counts per operator (e.g. for
    /// `stratifyBy: operatorSubtype`) directly from `mutations` + `skipped`
    /// without a separate summary structure — see `OperatorBudgetSummary`.
    public let operatorID: String?

    public init(id: MutationID, file: String, reason: Reason, detail: String? = nil, operatorID: String? = nil) {
        self.id = id
        self.file = file
        self.reason = reason
        self.detail = detail
        self.operatorID = operatorID
    }
}

/// Per-operator eligible/selected/budgetDropped, derived from a plan's own
/// `mutations` + `skipped` rather than tracked separately during selection.
///
/// - `selected`: this operator's count in `mutations` — what actually made
///   it into the plan.
/// - `budgetDropped`: this operator's count among `skipped` entries whose
///   `reason` is `.budgetExceeded` — candidates the budget gate saw and did
///   not pick, not candidates dropped by an earlier gate (confidence, diff
///   scope, suppression). An operator disabled entirely, or whose sites were
///   all outside a diff scope, is absent from both `mutations` and any
///   `.budgetExceeded` skip, so it does not appear here at all — this type
///   only speaks to the budget gate's own decision.
/// - `eligible`: `selected + budgetDropped` — everything the budget gate had
///   to choose from for this operator.
public struct OperatorBudgetSummary: Codable, Sendable, Hashable {
    public let operatorID: String
    public let eligible: Int
    public let selected: Int
    public let budgetDropped: Int

    public init(operatorID: String, eligible: Int, selected: Int, budgetDropped: Int) {
        self.operatorID = operatorID
        self.eligible = eligible
        self.selected = selected
        self.budgetDropped = budgetDropped
    }

    /// One summary per operator that appears in `mutations` or in a
    /// `.budgetExceeded` skip, sorted by `operatorID` for a deterministic
    /// report.
    public static func tally(mutations: [MutationPoint], skipped: [SkippedMutation]) -> [OperatorBudgetSummary] {
        var selectedByOperator: [String: Int] = [:]
        for point in mutations {
            selectedByOperator[point.operatorID, default: 0] += 1
        }
        var droppedByOperator: [String: Int] = [:]
        for skip in skipped where skip.reason == .budgetExceeded {
            guard let operatorID = skip.operatorID else { continue }
            droppedByOperator[operatorID, default: 0] += 1
        }

        let operatorIDs = Set(selectedByOperator.keys).union(droppedByOperator.keys)
        return operatorIDs.sorted().map { operatorID in
            let selected = selectedByOperator[operatorID] ?? 0
            let dropped = droppedByOperator[operatorID] ?? 0
            return OperatorBudgetSummary(
                operatorID: operatorID, eligible: selected + dropped, selected: selected, budgetDropped: dropped
            )
        }
    }
}

/// The single source of truth for a mutation run.
///
/// Discovery writes one of these and touches nothing else — it never rewrites a
/// source file. Execution reads it and works only from what it says. Because the
/// plan is plain JSON with content-derived IDs, it shards, resumes and
/// reproduces without any live process state.
public struct MutationPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let createdAt: Date
    public let projectRoot: String
    public let toolchain: ToolchainFingerprint
    /// Hash of the resolved configuration, so a plan run under different
    /// settings is detectable.
    public let configurationHash: String
    /// Hashes of every source file considered, keyed by relative path.
    public let sourceFileHashes: [String: String]
    /// Sorted by `MutationID` — this is what makes execution order deterministic.
    public let mutations: [MutationPoint]
    public let skipped: [SkippedMutation]
    /// Operator descriptors in effect, embedded so results stay interpretable
    /// even if the operator set changes in a later release.
    public let operators: [OperatorDescriptor]
    /// One record per mutant in `mutations`, present only when this plan was
    /// selected under `budget.selection: v2` (ADR-0007 B.7) — always empty
    /// for a v1 plan. Computed once, at planning time, and never recomputed:
    /// `PlanSharding.shard` copies each shard's subset unchanged rather than
    /// re-deriving it, and it is excluded from `planID`/`workUnitID`'s hash
    /// inputs on the same terms `createdAt` already is — derived data
    /// describing an already-fixed selection, not part of what makes two
    /// plans "the same plan."
    public let budgetInclusionReasons: [InclusionReason]

    public init(
        planID: String,
        createdAt: Date,
        projectRoot: String,
        toolchain: ToolchainFingerprint,
        configurationHash: String,
        sourceFileHashes: [String: String],
        mutations: [MutationPoint],
        skipped: [SkippedMutation],
        operators: [OperatorDescriptor],
        budgetInclusionReasons: [InclusionReason] = []
    ) {
        schemaVersion = SchemaVersion.plan
        self.planID = planID
        self.createdAt = createdAt
        self.projectRoot = projectRoot
        self.toolchain = toolchain
        self.configurationHash = configurationHash
        self.sourceFileHashes = sourceFileHashes
        self.mutations = mutations.sorted { $0.id < $1.id }
        self.skipped = skipped
        self.operators = operators
        self.budgetInclusionReasons = budgetInclusionReasons.sorted { $0.mutationID < $1.mutationID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, planID, createdAt, projectRoot, toolchain, configurationHash
        case sourceFileHashes, mutations, skipped, operators, budgetInclusionReasons
    }

    /// Custom only for `budgetInclusionReasons`: a plan.json written before
    /// this field existed has no such key, and decoding that as a hard
    /// failure would break every plan/checkpoint produced before this
    /// change for no reason — treated as v1's implicit empty case instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        planID = try container.decode(String.self, forKey: .planID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        projectRoot = try container.decode(String.self, forKey: .projectRoot)
        toolchain = try container.decode(ToolchainFingerprint.self, forKey: .toolchain)
        configurationHash = try container.decode(String.self, forKey: .configurationHash)
        sourceFileHashes = try container.decode([String: String].self, forKey: .sourceFileHashes)
        mutations = try container.decode([MutationPoint].self, forKey: .mutations)
        skipped = try container.decode([SkippedMutation].self, forKey: .skipped)
        operators = try container.decode([OperatorDescriptor].self, forKey: .operators)
        budgetInclusionReasons = try container.decodeIfPresent(
            [InclusionReason].self, forKey: .budgetInclusionReasons
        ) ?? []
    }

    /// Custom only for `budgetInclusionReasons`: omitted entirely when empty
    /// (a v1 plan, or a v2 plan with no candidates), rather than encoded as
    /// `[]`. Synthesized `Encodable` would always emit the key — a Codex
    /// integration review caught that this makes every v1 plan.json's bytes
    /// change even though v1's own selection behavior is untouched, breaking
    /// ADR-0007 invariant 8/B.8's byte-identical-for-existing-configs
    /// requirement. Omitting rather than emitting `[]` restores that.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(planID, forKey: .planID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(projectRoot, forKey: .projectRoot)
        try container.encode(toolchain, forKey: .toolchain)
        try container.encode(configurationHash, forKey: .configurationHash)
        try container.encode(sourceFileHashes, forKey: .sourceFileHashes)
        try container.encode(mutations, forKey: .mutations)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(operators, forKey: .operators)
        if !budgetInclusionReasons.isEmpty {
            try container.encode(budgetInclusionReasons, forKey: .budgetInclusionReasons)
        }
    }

    /// Total mutations discovered, whether or not they will run.
    public var discoveredCount: Int { mutations.count + skipped.count }

    /// Identifies the exact set of work this plan represents.
    ///
    /// Distinct from `planID`, and deliberately so. Every shard of a plan keeps
    /// its parent's `planID` — they are the same plan, split — which makes
    /// `planID` the wrong key for a checkpoint: all the shards would share one
    /// file, and each would resume from its siblings' results and then report
    /// mutations that are not in its own plan.
    ///
    /// Keying on the mutation set instead means a checkpoint can only ever be
    /// resumed by a run of exactly the same work, which is the only case where
    /// resuming is sound. Editing or re-planning changes the key, so a stale
    /// checkpoint is ignored rather than silently mixed in.
    public var workUnitID: String {
        ContentHash.shortDigest(
            of: ([planID] + mutations.map(\.id.rawValue)).joined(separator: "\u{1F}")
        )
    }
}

// MARK: - Canonical serialization

public extension MutationPlan {
    /// Sorted keys and stable date encoding: byte-identical output for identical
    /// input, which is what "deterministic by default" has to mean for a file
    /// that CI will diff and cache.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Decodes and structurally validates a plan: schema version, plus every
    /// invariant `IntegrityChecker.validatePlan` would otherwise only catch
    /// *after* something downstream (`Dictionary(uniqueKeysWithValues:)` in
    /// `IntegrityChecker.check`/`CheckpointStore.loadAll`) has already
    /// trapped on it. A plan with a duplicate or unstable mutation ID is
    /// rejected here, at the one place every caller already goes through to
    /// get a `MutationPlan` from disk, rather than reaching execution and
    /// crashing the process instead of reporting a violation.
    static func decode(from data: Data) throws -> MutationPlan {
        let plan = try decoder().decode(MutationPlan.self, from: data)
        guard plan.schemaVersion == SchemaVersion.plan else {
            throw PlanError.unsupportedSchemaVersion(found: plan.schemaVersion, expected: SchemaVersion.plan)
        }
        let violations = IntegrityChecker.validatePlan(plan)
        guard violations.isEmpty else {
            throw PlanError.invalidStructure(violations)
        }
        return plan
    }
}

public enum PlanError: Error, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case idMismatch(declared: MutationID, recomputed: MutationID, file: String)
    /// Duplicate or unstable mutation IDs found while decoding — see
    /// `MutationPlan.decode`'s doc comment for why this is caught here
    /// rather than left for a later stage to trap on.
    case invalidStructure([IntegrityViolation])

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, expected):
            "Plan schema version \(found) is not supported by this tool (expects \(expected))."
        case let .idMismatch(declared, recomputed, file):
            """
            Mutation ID in \(file) does not reproduce from its own components: \
            plan says \(declared), recomputing gives \(recomputed). The plan was \
            edited by hand or written by an incompatible version.
            """
        case let .invalidStructure(violations):
            "Plan is not internally consistent:\n" + violations.map { "  - \($0.detail)" }.joined(separator: "\n")
        }
    }
}
