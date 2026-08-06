import Foundation

/// One mutation's placement within a schema — chunk, dense local index, and
/// the lowerer that embedded it — plus enough provenance to explain a
/// fallback without re-deriving it from scratch.
///
/// Kept in a companion file (`schemata-plan.json`) rather than folded into
/// `MutationPlan` itself: `plan.json` stays the single source of truth for
/// *what mutations exist*, independent of which backend ends up running
/// them. A `SchemataPlan` derived from the same `MutationPlan` is always
/// deterministically reproducible from it plus the lowerer versions in
/// effect — never a second, independently-editable source of mutation
/// identity.
public struct SchemataPlanEntry: Codable, Sendable, Hashable {
    public let mutationID: MutationID
    public let placement: SchemataPlacement
    /// Shared by every candidate a structural conflict forced apart from —
    /// candidates in the same conflict group never end up in the same
    /// chunk. `nil` when this candidate had no conflicts to record.
    public let conflictGroup: String?
    /// Representative project/target/module/product — for an
    /// `.isolatedFallback` entry, the actual (sole, or arbitrarily-chosen
    /// among several) target info; for an `.embedded` entry, the first
    /// placement by `(projectIdentity, target, module, product)` sort order
    /// (see `SchemataPlanEntry.merged(_:)`), for display/grouping purposes
    /// only. A mutation embedded into more than one target has its real,
    /// complete per-target facts in `placements`, not here — these four
    /// fields are never "the" target for such an entry.
    public let projectIdentity: String
    public let target: String
    public let module: String
    public let product: String

    public init(
        mutationID: MutationID,
        placement: SchemataPlacement,
        conflictGroup: String?,
        projectIdentity: String,
        target: String,
        module: String,
        product: String
    ) {
        self.mutationID = mutationID
        self.placement = placement
        self.conflictGroup = conflictGroup
        self.projectIdentity = projectIdentity
        self.target = target
        self.module = module
        self.product = product
    }

    /// `true` when this entry actually got embedded in a schema, `false`
    /// when it fell back to isolated execution.
    public var isEmbedded: Bool {
        if case .embedded = placement { return true }
        return false
    }

    /// Every target this mutation was independently embedded into — empty
    /// for `.isolatedFallback`. A single-target mutation has exactly one.
    public var placements: [SchemataEmbeddedPlacement] {
        guard case let .embedded(placements) = placement else { return [] }
        return placements
    }

    /// The first placement's own field, by no particular ordering guarantee
    /// beyond `placements`' own order — correct and unambiguous for the
    /// common (single-target) case; a caller that genuinely needs every
    /// target's own value must use `placements` directly.
    public var chunkID: String? { placements.first?.chunkID }
    public var selectorToken: SchemataSelectorToken? { placements.first?.selectorToken }
    /// The lowerer's own view of this chunk's build inputs — see
    /// `SchemataProgram.sourceEmbeddingID`'s doc comment.
    public var sourceEmbeddingID: String? { placements.first?.sourceEmbeddingID }
    public var lowererID: String? { placements.first?.lowererID }
    public var lowererVersion: Int? { placements.first?.lowererVersion }

    /// `nil` for a candidate that was actually embedded; present whenever
    /// this entry is `.isolatedFallback`, explaining why.
    public var fallbackReason: SchemataUnsupportedReason? {
        guard case let .isolatedFallback(reason) = placement else { return nil }
        return reason
    }

    /// A copy with every `.embedded` placement's `sourceEmbeddingID`
    /// replaced — for a lowerer that builds its entries before the chunk's
    /// full embedding identity is known (the identity is itself derived
    /// from the entries) and fills it in once lowering completes. Called
    /// before `SchemataPlanEntry.merged(_:)` (a lowerer only ever produces
    /// single-placement, pre-merge entries — see that function's own doc
    /// comment), so mapping over every placement here is equivalent to
    /// replacing the one placement that exists at this point. A no-op on
    /// an `.isolatedFallback` entry, which has no embedding identity to
    /// set.
    public func withSourceEmbeddingID(_ sourceEmbeddingID: String) -> SchemataPlanEntry {
        guard case let .embedded(existing) = placement else { return self }
        let updated = existing.map { placement in
            SchemataEmbeddedPlacement(
                chunkID: placement.chunkID, selectorToken: placement.selectorToken,
                sourceEmbeddingID: sourceEmbeddingID, lowererID: placement.lowererID,
                lowererVersion: placement.lowererVersion, projectIdentity: placement.projectIdentity,
                target: placement.target, module: placement.module, product: placement.product,
                expectedImages: placement.expectedImages
            )
        }
        return SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: updated),
            conflictGroup: conflictGroup,
            projectIdentity: projectIdentity,
            target: target,
            module: module,
            product: product
        )
    }

    /// Combines one mutation's independent per-target embeddings — each
    /// produced separately by `SchemataChunkPlanner` (one single-placement
    /// `.embedded` entry per target its source file belongs to) — into the
    /// single entry `SchemataPlan.entries` requires:
    /// `SchemataPlan.decodeAndValidate` rejects more than one entry per
    /// `MutationID` (`ValidationError.duplicateEntry`), so a plan with N
    /// target memberships for one mutation must still end up as one entry
    /// carrying N placements, not N entries.
    ///
    /// The representative `projectIdentity`/`target`/`module`/`product` is
    /// the first entry by that same sort key — deterministic regardless of
    /// input order, not meant to be read as "the" target.
    public static func merged(_ entries: [SchemataPlanEntry]) -> SchemataPlanEntry {
        precondition(!entries.isEmpty, "merged(_:) needs at least one entry")
        precondition(
            entries.allSatisfy { $0.mutationID == entries[0].mutationID },
            "merged(_:) entries must all share one mutationID"
        )
        precondition(entries.allSatisfy(\.isEmbedded), "merged(_:) is for combining embedded placements only")
        let representative = entries.sorted {
            ($0.projectIdentity, $0.target, $0.module, $0.product) < ($1.projectIdentity, $1.target, $1.module, $1.product)
        }[0]
        return SchemataPlanEntry(
            mutationID: entries[0].mutationID,
            placement: .embedded(placements: entries.flatMap(\.placements)),
            conflictGroup: representative.conflictGroup,
            projectIdentity: representative.projectIdentity,
            target: representative.target,
            module: representative.module,
            product: representative.product
        )
    }
}

/// The schemata-specific companion to a `MutationPlan` — every mutation's
/// chunk placement, plus the content-addressed `schemataPlanID` that
/// identifies this exact combination of inputs.
///
/// Written as `schemata-plan.json` alongside `plan.json`, never merged into
/// it — see `SchemataPlanEntry`'s doc comment for why. Entries are sorted by
/// `mutationID` on construction so two independently-produced plans over the
/// identical input set are byte-identical, the same discipline
/// `MutationPlan.init` already applies to `mutations`.
public struct SchemataPlan: Codable, Sendable {
    public let schemaVersion: Int
    /// Content-addressed: a full SHA-256 (never truncated — see
    /// `schemataPlanID`'s doc comment on why a short hash is wrong for a
    /// trust-boundary identity) of everything that determines *how
    /// mutations are arranged*: the parent plan's identity, backend
    /// identity/version, toolchain, build arguments, and a canonical
    /// encoding of every entry — never a sequential counter or list
    /// position. A sequential ID would shift every later chunk's identity on
    /// a single addition, invalidating schema build cache, artifact cache,
    /// and historical benchmark comparisons for no real reason. See
    /// ADR-0003.
    ///
    /// This identifies the *plan*, not any one chunk's actual build
    /// artifact — adding a mutation anywhere changes `schemataPlanID`, by
    /// design, since the arrangement genuinely did change. A build cache
    /// keyed on an individual chunk's contents must use that chunk's own
    /// `SchemataPlanEntry.sourceEmbeddingID` instead, which stays stable
    /// across unrelated additions elsewhere in the plan.
    ///
    /// `MutationID`, `workUnitID`, and the rest of this codebase's *human-
    /// facing* identifiers deliberately truncate to 64 bits (`ContentHash
    /// .shortDigest`) — short enough to read and type, at a collision risk
    /// acceptable for "two mutations happen to get the same short name."
    /// `schemataPlanID` is not human-facing: it is the boundary a build
    /// cache and an evidence-trust check are keyed on, where a collision
    /// means silently reusing the wrong cached binary. It uses the full,
    /// untruncated `ContentHash.of(...)` for that reason, as does
    /// `SchemataProgram.sourceEmbeddingID`.
    public let schemataPlanID: String
    /// The parent `MutationPlan.planID` this schema was derived from.
    /// `decodeAndValidate` checks this against the `MutationPlan` it is
    /// handed, so a `schemata-plan.json` can never be silently paired with
    /// the wrong `plan.json` — the same hazard `MutationResultCache`'s own
    /// context-digest binding already guards against for cached results.
    public let mutationPlanID: String
    /// `MutationPlan.workUnitID` at construction time — identifies the exact
    /// mutation *set*, not just which plan lineage it came from. A re-plan
    /// that changes which mutations exist changes `workUnitID` but can
    /// leave `planID` unchanged (see `MutationPlan.workUnitID`'s own doc
    /// comment); this schema must be invalidated by either.
    public let mutationPlanWorkUnitID: String
    public let backendID: String
    public let backendVersion: Int
    public let toolchainHash: String
    public let buildArgumentsHash: String
    public let entries: [SchemataPlanEntry]

    /// Takes the parent `MutationPlan` itself, not just its ID strings —
    /// `SchemataPlan` never exists independent of one specific plan.
    public init(
        mutationPlan: MutationPlan,
        backendID: String,
        backendVersion: Int,
        toolchainHash: String,
        buildArgumentsHash: String,
        entries: [SchemataPlanEntry]
    ) {
        schemaVersion = SchemaVersion.schemataPlan
        mutationPlanID = mutationPlan.planID
        mutationPlanWorkUnitID = mutationPlan.workUnitID
        self.backendID = backendID
        self.backendVersion = backendVersion
        self.toolchainHash = toolchainHash
        self.buildArgumentsHash = buildArgumentsHash
        let sortedEntries = entries.sorted { $0.mutationID < $1.mutationID }
        self.entries = sortedEntries
        schemataPlanID = Self.deriveSchemataPlanID(
            header: Header(
                schemaVersion: schemaVersion,
                mutationPlanID: mutationPlanID,
                mutationPlanWorkUnitID: mutationPlanWorkUnitID,
                backendID: backendID,
                backendVersion: backendVersion,
                toolchainHash: toolchainHash,
                buildArgumentsHash: buildArgumentsHash
            ),
            entries: sortedEntries
        )
    }

    /// Everything `schemataPlanID` hashes over except the entries
    /// themselves — bundled so `deriveSchemataPlanID` takes two parameters,
    /// not eight.
    private struct Header {
        let schemaVersion: Int
        let mutationPlanID: String
        let mutationPlanWorkUnitID: String
        let backendID: String
        let backendVersion: Int
        let toolchainHash: String
        let buildArgumentsHash: String
    }

    /// Every way `decodeAndValidate` refuses a decoded `SchemataPlan` before
    /// a caller ever sees it — the trust-boundary checks that plain
    /// `JSONDecoder().decode(SchemataPlan.self)` cannot enforce, since a
    /// hand-edited or stale-on-disk file decodes as valid Swift values
    /// regardless of whether it actually describes the plan it claims to.
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        /// `mutationPlanID` does not match the `MutationPlan` this schema
        /// was validated against — a `schemata-plan.json` paired with the
        /// wrong `plan.json`.
        case mutationPlanIDMismatch(expected: String, found: String)
        /// `mutationPlanWorkUnitID` does not match — the mutation *set* the
        /// schema was built for is not the one in the plan handed in, even
        /// if `planID` happens to agree (a re-plan of the same target).
        case mutationPlanWorkUnitIDMismatch(expected: String, found: String)
        /// Recomputing `schemataPlanID` from the decoded fields disagrees
        /// with the stored one — the file was hand-edited, truncated, or
        /// written by an incompatible version.
        case schemataPlanIDMismatch(expected: String, recomputed: String)
        /// The same `MutationID` appears in `entries` more than once.
        case duplicateEntry(MutationID)
        /// Two `.embedded` entries share an identical `SchemataSelectorToken`.
        case duplicateSelectorToken(SchemataSelectorToken)
        /// An entry names a `MutationID` the parent `MutationPlan` does not
        /// contain.
        case entryNotInMutationPlan(MutationID)
        /// The parent `MutationPlan` contains a mutation with no
        /// corresponding entry — every mutation must be accounted for,
        /// embedded or isolated-fallback, never silently dropped.
        case mutationMissingEntry(MutationID)
        /// `executionContext` was supplied and the plan's `schemaVersion`
        /// does not match it — a plan written by an incompatible schema
        /// version, being read by code that does not know how to interpret
        /// it. See `decodeAndValidate(_:against:executionContext:)`.
        case schemaVersionMismatch(expected: Int, found: Int)
        /// `executionContext` was supplied and the plan's `backendID` does
        /// not match it — this plan was built for a different execution
        /// backend than the one about to run it.
        case backendIDMismatch(expected: String, found: String)
        /// `executionContext` was supplied and the plan's `backendVersion`
        /// does not match it — same backend, but a version whose chunking/
        /// lowering behavior may have changed since this plan was built.
        case backendVersionMismatch(expected: Int, found: Int)
        /// `executionContext` was supplied and the plan's `toolchainHash`
        /// does not match it — this plan was built against a different
        /// Swift toolchain than the one about to run it; a schema built
        /// under one toolchain has no guarantee of building or activating
        /// identically under another.
        case toolchainMismatch(expected: String, found: String)
        /// `executionContext` was supplied and the plan's
        /// `buildArgumentsHash` does not match it — the build arguments
        /// (platform, configuration, SDK, and similar) this plan assumed no
        /// longer hold for the run about to use it.
        case buildArgumentsMismatch(expected: String, found: String)

        public var description: String {
            switch self {
            case let .mutationPlanIDMismatch(expected, found):
                "schema's mutationPlanID \(found) does not match the given plan's planID \(expected)"
            case let .mutationPlanWorkUnitIDMismatch(expected, found):
                "schema's mutationPlanWorkUnitID \(found) does not match the given plan's workUnitID \(expected)"
            case let .schemataPlanIDMismatch(expected, recomputed):
                "schemataPlanID \(expected) does not match recomputed \(recomputed) — file may be hand-edited or corrupted"
            case let .duplicateEntry(mutationID):
                "mutation \(mutationID.rawValue) has more than one entry"
            case let .duplicateSelectorToken(token):
                "selector token (namespace: \(token.namespace), localIndex: \(token.localIndex)) is assigned to more than one entry"
            case let .entryNotInMutationPlan(mutationID):
                "entry for \(mutationID.rawValue) has no corresponding mutation in the given plan"
            case let .mutationMissingEntry(mutationID):
                "mutation \(mutationID.rawValue) in the given plan has no schemata entry"
            case let .schemaVersionMismatch(expected, found):
                "the current execution context expects schemaVersion \(expected), but this plan is schemaVersion \(found)"
            case let .backendIDMismatch(expected, found):
                "the current execution context is backend \(expected), but this plan was built for backend \(found)"
            case let .backendVersionMismatch(expected, found):
                "the current execution context is backend version \(expected), but this plan was built for version \(found)"
            case let .toolchainMismatch(expected, found):
                "the current execution context's toolchain (\(expected)) does not match this plan's (\(found))"
            case let .buildArgumentsMismatch(expected, found):
                "the current execution context's build arguments (\(expected)) do not match this plan's (\(found))"
            }
        }
    }

    /// What the *current* execution environment is, at the moment a
    /// `SchemataPlan` is about to be used — as distinct from what
    /// `decodeAndValidate`'s existing checks already verify (that the plan
    /// is internally self-consistent, and that it was built from the exact
    /// parent `MutationPlan` handed in). Self-consistency alone cannot
    /// catch a stale or foreign-toolchain plan: a plan built yesterday
    /// under an older toolchain, run today without rebuilding it, would
    /// still recompute its own `schemataPlanID` correctly — nothing about
    /// its own recorded fields is wrong, only that they no longer describe
    /// *this* run. Passing this to `decodeAndValidate` closes that gap.
    ///
    /// Optional on `decodeAndValidate` (not required) because no production
    /// caller constructs a `SchemataPlan`-consuming execution path yet — see
    /// ADR-0004. When one exists, it should always pass this; the
    /// parameterless overload's behavior — self-consistency only — remains
    /// available for exactly the callers this codebase already has: tests
    /// exercising the plan/entry contract in isolation, not a real backend
    /// run.
    public struct SchemataExecutionContext: Sendable {
        public let schemaVersion: Int
        public let backendID: String
        public let backendVersion: Int
        public let toolchainHash: String
        public let buildArgumentsHash: String

        public init(
            schemaVersion: Int, backendID: String, backendVersion: Int, toolchainHash: String, buildArgumentsHash: String
        ) {
            self.schemaVersion = schemaVersion
            self.backendID = backendID
            self.backendVersion = backendVersion
            self.toolchainHash = toolchainHash
            self.buildArgumentsHash = buildArgumentsHash
        }
    }

    /// Decodes `data` and re-verifies every trust-boundary invariant plain
    /// `Decodable` synthesis cannot: that `schemataPlanID` still matches its
    /// own recomputation, that this schema was actually built from `plan`
    /// (both `planID` and `workUnitID`), that entries carry no duplicate
    /// `MutationID` or `SchemataSelectorToken`, and that entries and the
    /// plan's mutations correspond one-to-one. Production code must call
    /// this, never a bare `JSONDecoder().decode(SchemataPlan.self, from:)`.
    ///
    /// `executionContext`, when supplied, additionally checks the plan
    /// against the *current* execution environment — see
    /// `SchemataExecutionContext`'s own doc comment for why self-consistency
    /// alone cannot catch a stale or foreign-toolchain plan. `nil` (the
    /// default) preserves this function's original, context-free behavior.
    public static func decodeAndValidate(
        _ data: Data, against plan: MutationPlan, executionContext: SchemataExecutionContext? = nil
    ) throws -> SchemataPlan {
        let decoded = try JSONDecoder().decode(SchemataPlan.self, from: data)
        return try Self.validateSelfConsistency(decoded, against: plan, executionContext: executionContext)
    }

    /// The shared validation body both `decodeAndValidate` and
    /// `SchemataPlanLoader.validateForExecution` run — split out so decoding
    /// happens exactly once regardless of which entry point a caller uses
    /// (`validateForExecution` is handed an already-decoded
    /// `UnvalidatedSchemataPlan`, not raw `Data`, precisely so it never
    /// re-decodes).
    fileprivate static func validateSelfConsistency(
        _ decoded: SchemataPlan, against plan: MutationPlan, executionContext: SchemataExecutionContext?
    ) throws -> SchemataPlan {
        guard decoded.mutationPlanID == plan.planID else {
            throw ValidationError.mutationPlanIDMismatch(expected: plan.planID, found: decoded.mutationPlanID)
        }
        guard decoded.mutationPlanWorkUnitID == plan.workUnitID else {
            throw ValidationError.mutationPlanWorkUnitIDMismatch(expected: plan.workUnitID, found: decoded.mutationPlanWorkUnitID)
        }

        if let executionContext {
            try validate(decoded, against: executionContext)
        }

        let recomputed = Self.deriveSchemataPlanID(
            header: Header(
                schemaVersion: decoded.schemaVersion,
                mutationPlanID: decoded.mutationPlanID,
                mutationPlanWorkUnitID: decoded.mutationPlanWorkUnitID,
                backendID: decoded.backendID,
                backendVersion: decoded.backendVersion,
                toolchainHash: decoded.toolchainHash,
                buildArgumentsHash: decoded.buildArgumentsHash
            ),
            entries: decoded.entries
        )
        guard recomputed == decoded.schemataPlanID else {
            throw ValidationError.schemataPlanIDMismatch(expected: decoded.schemataPlanID, recomputed: recomputed)
        }

        var seenMutationIDs: Set<MutationID> = []
        var seenTokens: Set<SchemataSelectorToken> = []
        for entry in decoded.entries {
            guard seenMutationIDs.insert(entry.mutationID).inserted else {
                throw ValidationError.duplicateEntry(entry.mutationID)
            }
            if let token = entry.selectorToken {
                guard seenTokens.insert(token).inserted else {
                    throw ValidationError.duplicateSelectorToken(token)
                }
            }
        }

        let planMutationIDs = Set(plan.mutations.map(\.id))
        for entry in decoded.entries where !planMutationIDs.contains(entry.mutationID) {
            throw ValidationError.entryNotInMutationPlan(entry.mutationID)
        }
        for mutationID in planMutationIDs where !seenMutationIDs.contains(mutationID) {
            throw ValidationError.mutationMissingEntry(mutationID)
        }

        return decoded
    }

    /// The `executionContext` half of `decodeAndValidate` — split out so the
    /// parent function's own cyclomatic complexity stays within SwiftLint's
    /// threshold; every check here is independent of the self-consistency
    /// checks `decodeAndValidate` already ran before calling this.
    private static func validate(_ plan: SchemataPlan, against executionContext: SchemataExecutionContext) throws {
        guard plan.schemaVersion == executionContext.schemaVersion else {
            throw ValidationError.schemaVersionMismatch(expected: executionContext.schemaVersion, found: plan.schemaVersion)
        }
        guard plan.backendID == executionContext.backendID else {
            throw ValidationError.backendIDMismatch(expected: executionContext.backendID, found: plan.backendID)
        }
        guard plan.backendVersion == executionContext.backendVersion else {
            throw ValidationError.backendVersionMismatch(expected: executionContext.backendVersion, found: plan.backendVersion)
        }
        guard plan.toolchainHash == executionContext.toolchainHash else {
            throw ValidationError.toolchainMismatch(expected: executionContext.toolchainHash, found: plan.toolchainHash)
        }
        guard plan.buildArgumentsHash == executionContext.buildArgumentsHash else {
            throw ValidationError.buildArgumentsMismatch(
                expected: executionContext.buildArgumentsHash, found: plan.buildArgumentsHash
            )
        }
    }

    /// An explicit, ordered, delimited preimage for everything *except* each
    /// entry's own content — `MutationID.compute` and `MutationPlan
    /// .workUnitID`'s discipline. Each entry itself folds in via a
    /// canonical (`.sortedKeys`) JSON encoding rather than a hand-maintained
    /// field list: a manually-enumerated list is exactly how the first
    /// version of this hash silently omitted `fallbackReason`,
    /// `conflictGroup`, and `target`/`module`/`product` — fields that are
    /// semantically part of an entry's identity but happened to not be
    /// listed. A canonical encoding cannot omit a field that exists on the
    /// type, now or in the future.
    private static func deriveSchemataPlanID(header: Header, entries: [SchemataPlanEntry]) -> String {
        let separator = "\u{1F}"
        let headerComponents = [
            String(header.schemaVersion), header.mutationPlanID, header.mutationPlanWorkUnitID,
            header.backendID, String(header.backendVersion), header.toolchainHash, header.buildArgumentsHash
        ]
        let entryComponents = entries.map(Self.canonicalEncoding)
        return ContentHash.of((headerComponents + entryComponents).joined(separator: separator))
    }

    private static func canonicalEncoding(of entry: SchemataPlanEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else {
            preconditionFailure("SchemataPlanEntry must always be encodable")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A `SchemataPlan` decoded but not yet checked against anything — ADR-0006's
/// fix for `decodeAndValidate`'s own fail-open shape: `executionContext`
/// being optional means a production execution path can call the weaker,
/// context-free overload as easily as the real one, with nothing at the
/// type level to stop it. Plan inspection (`InspectCommand` and similar,
/// which only ever wants "is this internally self-consistent," never "is
/// this safe to execute") is this type's one legitimate consumer —
/// `SchemataPlanLoader.decodeForInspection` is its only public source.
public struct UnvalidatedSchemataPlan: Sendable {
    fileprivate let decoded: SchemataPlan
}

/// A `SchemataPlan` proven to match both the parent `MutationPlan` it claims
/// to derive from and the *current* execution environment about to run it —
/// the only thing a real schemata execution path may accept. Constructible
/// only via `SchemataPlanLoader.validateForExecution`, never directly, so a
/// production runner cannot be handed a plan that skipped the
/// `SchemataExecutionContext` check by mistake.
public struct ExecutableSchemataPlan: Sendable {
    public let plan: SchemataPlan
    public let mutationPlan: MutationPlan
    public let executionContext: SchemataPlan.SchemataExecutionContext

    fileprivate init(plan: SchemataPlan, mutationPlan: MutationPlan, executionContext: SchemataPlan.SchemataExecutionContext) {
        self.plan = plan
        self.mutationPlan = mutationPlan
        self.executionContext = executionContext
    }
}

/// The two entry points `SchemataPlan`'s trust boundary is split across —
/// see `UnvalidatedSchemataPlan`/`ExecutableSchemataPlan`'s own doc comments
/// for why one decode path is deliberately weaker than the other.
public enum SchemataPlanLoader {
    /// Decodes `data` with no validation beyond `Decodable` synthesis
    /// itself — deliberately not even `SchemataPlan.decodeAndValidate`'s
    /// self-consistency checks, so nothing about this call can be mistaken
    /// for "this plan is safe to execute." For inspection tooling only.
    public static func decodeForInspection(_ data: Data) throws -> UnvalidatedSchemataPlan {
        UnvalidatedSchemataPlan(decoded: try JSONDecoder().decode(SchemataPlan.self, from: data))
    }

    /// The only way to produce an `ExecutableSchemataPlan`: re-verifies
    /// every self-consistency invariant `decodeAndValidate` already checks
    /// (this schema was actually built from `mutationPlan`, no duplicate
    /// entries or selector tokens, every mutation accounted for) *and*
    /// `context`, non-optional here unlike `decodeAndValidate`'s own
    /// parameter — a caller cannot omit the execution-environment check by
    /// forgetting an argument the way it could before this split existed.
    public static func validateForExecution(
        _ unvalidated: UnvalidatedSchemataPlan, against mutationPlan: MutationPlan,
        context: SchemataPlan.SchemataExecutionContext
    ) throws -> ExecutableSchemataPlan {
        let validated = try SchemataPlan.validateSelfConsistency(unvalidated.decoded, against: mutationPlan, executionContext: context)
        return ExecutableSchemataPlan(plan: validated, mutationPlan: mutationPlan, executionContext: context)
    }
}
