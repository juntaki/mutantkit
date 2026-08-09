import Foundation
import MutationModel
import SwiftFrontend

/// Where one `MutationPoint` in `sources` actually gets compiled — the
/// planner has no way to derive this itself (that is a build-adapter
/// concern, already solved elsewhere for isolated mode), so it is supplied
/// per file by the caller.
///
/// `projectIdentity` exists because `target`/`module`/`product` alone are
/// not a safe grouping key: two different Xcode projects (or two different
/// SwiftPM packages) can trivially have identically-named targets, and
/// without something that distinguishes the *project*, the chunk planner
/// would silently merge mutations from two unrelated builds into one
/// chunk. Callers should pass a canonical, build-system-stable identity —
/// e.g. the resolved `.xcodeproj` path (or target GUID) for Xcode, or the
/// package identity for SwiftPM — not a display name.
public struct SchemataTargetInfo: Sendable, Hashable {
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
}

/// Everything about the backend/toolchain that identifies *how* a schema
/// was built, independent of which mutations it contains — the same role
/// `SchemataPlan.toolchainHash`/`buildArgumentsHash` already play, bundled
/// here so `SchemataChunkPlanner.plan` takes one parameter for it instead
/// of four.
public struct SchemataBackendInfo: Sendable {
    public let backendID: String
    public let backendVersion: Int
    public let toolchainHash: String
    public let buildArgumentsHash: String

    public init(backendID: String, backendVersion: Int, toolchainHash: String, buildArgumentsHash: String) {
        self.backendID = backendID
        self.backendVersion = backendVersion
        self.toolchainHash = toolchainHash
        self.buildArgumentsHash = buildArgumentsHash
    }
}

public struct SchemataChunkPlanResult: Sendable {
    public let schemataPlan: SchemataPlan
    /// One `SchemataProgram` per chunk actually lowered — the rewritten
    /// sources a build orchestrator (not yet built) would compile.
    public let programs: [SchemataProgram]

    public init(schemataPlan: SchemataPlan, programs: [SchemataProgram]) {
        self.schemataPlan = schemataPlan
        self.programs = programs
    }
}

public enum SchemataChunkPlanningError: Error, Equatable, CustomStringConvertible {
    /// A mutation's own file has no entry in the `sources` map the caller
    /// supplied.
    case missingSource(file: String)
    /// A mutation's own file has no entry in the `targetInfo` map.
    case missingTargetInfo(file: String)
    /// Two distinct chunks derived the identical selector namespace — see
    /// `SchemataChunk.namespace`'s doc comment. Vanishingly unlikely (a
    /// 64-bit hash collision) but must fail closed rather than silently let
    /// two chunks' mutations alias each other's activation tokens if a run
    /// ever loads both into the same process.
    case namespaceCollision(chunkIDs: [String], namespace: UInt64)
    /// `maxChunkSize` was not a positive count — silently treating this as
    /// "one unbounded chunk" would defeat the entire point of the parameter
    /// rather than surface the caller's bug.
    case invalidMaxChunkSize(Int)

    public var description: String {
        switch self {
        case let .missingSource(file):
            "no source content supplied for \(file)"
        case let .missingTargetInfo(file):
            "no target/module/product info supplied for \(file)"
        case let .namespaceCollision(chunkIDs, namespace):
            "chunks \(chunkIDs.joined(separator: ", ")) collide on selector namespace \(namespace)"
        case let .invalidMaxChunkSize(value):
            "maxChunkSize must be positive, got \(value)"
        }
    }
}

/// Turns a `MutationPlan` into a `SchemataPlan`: for every mutation, asks
/// the registered lowerer (if any) whether it is eligible, groups eligible
/// points into chunks small enough to build as one compile unit, and lowers
/// each chunk for real — producing both the persisted plan and the
/// rewritten sources a build orchestrator would actually compile.
///
/// Deliberately conservative about what counts as one chunk: points are
/// only ever grouped with other points bound for the identical
/// lowerer/target/module/product. A more sophisticated planner (packing
/// across targets, balancing chunk sizes for build parallelism) is future
/// work — this is the S4 the roadmap called for, not the final word on
/// chunking strategy.
public enum SchemataChunkPlanner {
    public static func plan(
        mutationPlan: MutationPlan,
        registry: SchemataLowererRegistry,
        sources: [String: Data],
        targetInfo: [String: [SchemataTargetInfo]],
        backend: SchemataBackendInfo,
        maxChunkSize: Int = 200
    ) throws -> SchemataChunkPlanResult {
        guard maxChunkSize > 0 else { throw SchemataChunkPlanningError.invalidMaxChunkSize(maxChunkSize) }
        let classified = try classify(mutationPlan: mutationPlan, registry: registry, sources: sources, targetInfo: targetInfo)
        // One file can belong to more than one target (see
        // `SchemataUnsupportedReason.multipleTargetsNotYetSupported`) —
        // every membership still needs its file available under that
        // target's own key, for whichever *other* file in that same target
        // actually gets chunked.
        var filesByTarget: [SchemataTargetInfo: [String]] = [:]
        for (file, infos) in targetInfo {
            for info in infos { filesByTarget[info, default: []].append(file) }
        }

        var programs: [SchemataProgram] = []
        var embeddedEntries: [SchemataPlanEntry] = []
        // Failures isolated to one batch — never allowed to take down every
        // other batch in this group, let alone every other group. See
        // `lower(batch:...)`'s own doc comment on why a batch can still fail
        // here even though every point in it individually passed
        // `analyze()`.
        var recoveredFallbackEntries: [SchemataPlanEntry] = []
        for key in classified.groups.keys.sorted(by: Self.orderGroupKeys) {
            let points = classified.groups[key]!.sorted { $0.id < $1.id }
            let lowerer = classified.lowererByID[key.lowererID]!
            let targetInfoForKey = SchemataTargetInfo(
                projectIdentity: key.projectIdentity, target: key.target, module: key.module, product: key.product
            )
            // Non-overlapping waves *before* the size cap: two points at
            // the identical byte span (a single comparison's boundary and
            // negation candidates, say — `RelationalOperatorReplacement`
            // always produces exactly this shape) cannot share one lowered
            // chunk no matter how small `maxChunkSize` is, since both would
            // rewrite the same source bytes. Splitting by overlap first,
            // and size-capping *within* each already-non-overlapping wave,
            // is what lets a file with many independent comparisons still
            // batch into as few builds as its worst site's own candidate
            // count requires — not one build per mutation.
            for wave in nonOverlappingWaves(points) {
                for batch in wave.chunked(into: maxChunkSize) {
                    do {
                        let program = try lower(batch: batch, key: key, lowerer: lowerer, filesByTarget: filesByTarget, sources: sources)
                        programs.append(program)
                        embeddedEntries.append(contentsOf: program.entries)
                    } catch {
                        // `analyze()` cleared every point in `batch`
                        // individually, but `lower()` still failed for the
                        // batch as a whole — a genuine structural conflict
                        // `analyze()` cannot see in isolation (an
                        // unexpected overlap after wave-splitting, a
                        // namespace derivation failure, or any other
                        // lowerer-internal error). Recorded as an isolated-
                        // fallback violation scoped to *this batch's*
                        // points only: every other batch, wave, and group
                        // still gets its real chance at schemata embedding.
                        for point in batch {
                            recoveredFallbackEntries.append(fallbackEntry(
                                point: point, info: targetInfoForKey,
                                reason: .structuralConflict(reason: "batch failed to lower: \(error)")
                            ))
                        }
                    }
                }
            }
        }

        try checkNamespaceCollisions(among: programs)

        // A mutation whose file belongs to more than one target appears
        // once per target here (`classify` added it to every target's own
        // group) — each single-placement, pre-merge entry from a distinct
        // `lower(...)` call. `SchemataPlan.decodeAndValidate` allows exactly
        // one entry per `MutationID`, so every mutation's entries collapse
        // into one multi-placement entry before the plan is built.
        let mergedEmbeddedEntries = Dictionary(grouping: embeddedEntries, by: \.mutationID)
            .values.map(SchemataPlanEntry.merged)

        let schemataPlan = SchemataPlan(
            mutationPlan: mutationPlan,
            backendID: backend.backendID,
            backendVersion: backend.backendVersion,
            toolchainHash: backend.toolchainHash,
            buildArgumentsHash: backend.buildArgumentsHash,
            entries: classified.fallbackEntries + recoveredFallbackEntries + mergedEmbeddedEntries
        )
        return SchemataChunkPlanResult(schemataPlan: schemataPlan, programs: programs)
    }

    private struct GroupKey: Hashable {
        let lowererID: String
        let projectIdentity: String
        let target: String
        let module: String
        let product: String
    }

    private struct Classification {
        var fallbackEntries: [SchemataPlanEntry] = []
        var groups: [GroupKey: [MutationPoint]] = [:]
        var lowererByID: [String: any SchemataLowerer] = [:]
    }

    private static func classify(
        mutationPlan: MutationPlan,
        registry: SchemataLowererRegistry,
        sources: [String: Data],
        targetInfo: [String: [SchemataTargetInfo]]
    ) throws -> Classification {
        var result = Classification()
        for point in mutationPlan.mutations {
            guard let infos = targetInfo[point.file], !infos.isEmpty else {
                throw SchemataChunkPlanningError.missingTargetInfo(file: point.file)
            }
            // `representative` is only used to give a *fallback* entry
            // some target/module/product to record — deterministic
            // (sorted), but not to be read as "the" target this mutation
            // belongs to when there is more than one.
            let representative = infos.sorted { ($0.target, $0.module, $0.product) < ($1.target, $1.module, $1.product) }[0]

            guard let lowerer = registry.lowerer(forOperatorID: point.operatorID) else {
                let reason = SchemataUnsupportedReason.operatorNotYetLowered(operatorID: point.operatorID)
                result.fallbackEntries.append(fallbackEntry(point: point, info: representative, reason: reason))
                continue
            }
            guard let source = sources[point.file] else {
                throw SchemataChunkPlanningError.missingSource(file: point.file)
            }

            // Eligibility depends only on the point/source content, never
            // on which target(s) compile it — analyzed once, reused for
            // every target membership below.
            switch lowerer.analyze(point, source: source) {
            case let .isolatedOnly(reason):
                result.fallbackEntries.append(fallbackEntry(point: point, info: representative, reason: reason))
            case .eligible:
                // A file compiled into more than one target (a shared
                // model file added directly to an app target and a widget
                // extension's own Compile Sources, say) embeds
                // independently into *every* target's own group — each is
                // a genuinely separate build, chunked and namespaced on
                // its own. `plan(...)` merges the resulting per-target
                // entries for this MutationID into one multi-placement
                // entry (`SchemataPlanEntry.merged(_:)`) before persisting
                // the final `SchemataPlan`.
                for info in infos {
                    let key = GroupKey(
                        lowererID: lowerer.descriptor.lowererID, projectIdentity: info.projectIdentity,
                        target: info.target, module: info.module, product: info.product
                    )
                    result.groups[key, default: []].append(point)
                }
                result.lowererByID[lowerer.descriptor.lowererID] = lowerer
            }
        }
        return result
    }

    private static func lower(
        batch: [MutationPoint],
        key: GroupKey,
        lowerer: any SchemataLowerer,
        filesByTarget: [SchemataTargetInfo: [String]],
        sources: [String: Data]
    ) throws -> SchemataProgram {
        let targetKey = SchemataTargetInfo(
            projectIdentity: key.projectIdentity, target: key.target, module: key.module, product: key.product
        )
        let chunkID = deriveChunkID(key: key, points: batch)
        let chunk = SchemataChunk(
            chunkID: chunkID, points: batch, projectIdentity: key.projectIdentity,
            target: key.target, module: key.module, product: key.product
        )

        var chunkSources: [SchemataSourceFile] = []
        for file in filesByTarget[targetKey] ?? [] {
            guard let data = sources[file] else { throw SchemataChunkPlanningError.missingSource(file: file) }
            chunkSources.append(SchemataSourceFile(relativePath: file, contents: String(decoding: data, as: UTF8.self)))
        }

        return try lowerer.lower(chunk, sources: chunkSources)
    }

    private static func checkNamespaceCollisions(among programs: [SchemataProgram]) throws {
        var owners: [UInt64: String] = [:]
        for program in programs {
            let namespace = ContentHash.uint64(of: program.chunkID)
            if let existing = owners[namespace], existing != program.chunkID {
                throw SchemataChunkPlanningError.namespaceCollision(chunkIDs: [existing, program.chunkID], namespace: namespace)
            }
            owners[namespace] = program.chunkID
        }
    }

    private static func fallbackEntry(
        point: MutationPoint, info: SchemataTargetInfo, reason: SchemataUnsupportedReason
    ) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: point.id,
            placement: .isolatedFallback(reason: reason),
            conflictGroup: nil,
            projectIdentity: info.projectIdentity,
            target: info.target,
            module: info.module,
            product: info.product
        )
    }

    /// An explicit, delimited preimage — same discipline every other
    /// content-addressed identifier in this codebase uses — of the chunk's
    /// own routing key plus its sorted mutation-ID set, so two
    /// independently-produced plans over the identical input always agree
    /// on `chunkID` regardless of classification order.
    ///
    /// Full, untruncated `ContentHash.of`, not `shortDigest`: `chunkID`
    /// feeds `SchemataChunk.namespace` (`ContentHash.uint64(of: chunkID)`),
    /// which is exactly the value two distinct chunks must never share. A
    /// 64-bit-truncated `chunkID` would make `checkNamespaceCollisions`'
    /// `existing == program.chunkID` exemption blind to a genuine chunkID
    /// collision between two chunks built from different inputs: if their
    /// (already-truncated) IDs happened to coincide, the check would treat
    /// them as "the same chunk, nothing to report" instead of the real
    /// collision they are — the same trust-boundary reasoning
    /// `SchemataPlan.schemataPlanID` and `BoolLiteralSchemataLowerer
    /// .sourceEmbeddingID` already apply.
    private static func deriveChunkID(key: GroupKey, points: [MutationPoint]) -> String {
        let separator = "\u{1F}"
        let header = [key.lowererID, key.projectIdentity, key.target, key.module, key.product]
        let pointIDs = points.map(\.id.rawValue).sorted()
        return ContentHash.of((header + pointIDs).joined(separator: separator))
    }

    private static func orderGroupKeys(_ lhs: GroupKey, _ rhs: GroupKey) -> Bool {
        (lhs.lowererID, lhs.projectIdentity, lhs.target, lhs.module, lhs.product) <
            (rhs.lowererID, rhs.projectIdentity, rhs.target, rhs.module, rhs.product)
    }

    /// Greedily partitions `points` into waves with no two overlapping
    /// `utf8Range`s *in the same file* within a wave. A lowerer's own chunk
    /// can never embed two points that rewrite the same source bytes —
    /// `RelationalOperatorReplacementSchemataLowerer`, for one, always
    /// offers a boundary and a negation candidate anchored at the identical
    /// operator token — so those must land in *different* waves (and
    /// therefore different builds) even when they would otherwise fit in
    /// the same size-capped chunk together.
    ///
    /// Byte ranges from *different* files are never compared against each
    /// other: `utf8Range` is file-relative, so two points in unrelated
    /// files can trivially share the same numeric offsets without
    /// conflicting at all — comparing across files here would wave-split
    /// pairs that were never actually in each other's way, for no reason.
    ///
    /// Deterministic: points are sorted by `(file, start offset)` first, so
    /// two independently-produced plans over the identical input always
    /// split into the same waves.
    private struct WavePoint {
        let file: String
        let range: ByteRange
        let point: MutationPoint
    }

    private static func nonOverlappingWaves(_ points: [MutationPoint]) -> [[MutationPoint]] {
        var waves: [[WavePoint]] = []
        for point in points.sorted(by: { ($0.file, $0.utf8Range.start) < ($1.file, $1.utf8Range.start) }) {
            let wavePoint = WavePoint(file: point.file, range: point.utf8Range, point: point)
            if let index = waves.firstIndex(where: { wave in
                wave.allSatisfy {
                    $0.file != wavePoint.file || $0.range.end <= wavePoint.range.start || wavePoint.range.end <= $0.range.start
                }
            }) {
                waves[index].append(wavePoint)
            } else {
                waves.append([wavePoint])
            }
        }
        return waves.map { $0.map(\.point) }
    }
}

private extension Array {
    /// Splits into consecutive slices of at most `size` elements each,
    /// preserving order — the simplest possible chunk-size cap, adequate
    /// until a real chunking strategy (balancing build time, not just
    /// count) replaces it. `size` must be positive — `plan(...)` already
    /// rejects a non-positive `maxChunkSize` before this is ever called.
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0, "chunked(into:) requires a positive size")
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
