import Foundation
import MutationModel
import SwiftFrontend

/// Per-chunk sandbox, build and finalization steps for `SchemataMutationRunner`.
extension SchemataMutationRunner {
    /// One chunk's contribution to the whole run: its entries' own
    /// outcomes, plus any shared chunk build-failure attribution aggregate build-failure
    /// events it generated (at most one in practice — a chunk stops as
    /// soon as any build attempt, initial or recovery, fails — but kept as
    /// an array rather than an `Optional` so accumulation at every call
    /// site is uniform, never a special case).
    struct ChunkRunResult {
        let outcomes: [EntryRunOutcome]
        let buildFailureEvents: [SharedChunkBuildFailureEvent]
        let infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]

        static let empty = ChunkRunResult(outcomes: [], buildFailureEvents: [], infrastructureFallbackEvents: [])

        init(
            outcomes: [EntryRunOutcome], buildFailureEvents: [SharedChunkBuildFailureEvent],
            infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
        ) {
            self.outcomes = outcomes
            self.buildFailureEvents = buildFailureEvents
            self.infrastructureFallbackEvents = infrastructureFallbackEvents
        }

        /// Positional convenience for `runEntries`'s own several early-return
        /// sites, which repeatedly reconstruct this from the same three
        /// loop-local accumulators — the keyword form's three long labels
        /// made every one of those sites needlessly wide.
        init(
            _ outcomes: [EntryRunOutcome], _ buildFailureEvents: [SharedChunkBuildFailureEvent],
            _ infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
        ) {
            self.outcomes = outcomes
            self.buildFailureEvents = buildFailureEvents
            self.infrastructureFallbackEvents = infrastructureFallbackEvents
        }
    }

    func runChunk(
        _ program: SchemataProgram,
        context: ChunkRunContext
    ) async -> ChunkRunResult {
        let embeddedEntries = program.entries.filter(\.isEmbedded)
        guard !embeddedEntries.isEmpty else { return .empty }

        let sandbox: Sandbox
        do {
            let sandboxCreateStart = GateTimingRecorder.shared.now()
            sandbox = try await session.workspaces.createSandbox(id: program.chunkID)
            await GateTimingRecorder.shared.record("chunk.sandboxCreate", chunkID: program.chunkID, start: sandboxCreateStart)
        } catch {
            let outcomes = embeddedEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the chunk sandbox could not be created: \(error)")
            }.map(EntryRunOutcome.verified)
            return ChunkRunResult(outcomes: outcomes, buildFailureEvents: [], infrastructureFallbackEvents: [])
        }

        let result = await runChunk(
            program, entries: embeddedEntries, in: sandbox, context: context
        )
        try? await session.workspaces.destroySandbox(sandbox)
        return result
    }

    func runChunk(
        _ program: SchemataProgram, entries embeddedEntries: [SchemataPlanEntry], in sandbox: Sandbox,
        context: ChunkRunContext
    ) async -> ChunkRunResult {
        switch await prepareChunkState(program: program, entries: embeddedEntries, in: sandbox) {
        case let .failed(outcomes, buildFailureEvent, infrastructureFallbackEvent):
            return ChunkRunResult(
                outcomes: outcomes, buildFailureEvents: buildFailureEvent.map { [$0] } ?? [],
                infrastructureFallbackEvents: infrastructureFallbackEvent.map { [$0] } ?? []
            )
        case let .ready(state):
            return await runEntries(
                embeddedEntries, program: program, state: state, context: context
            )
        }
    }

    /// Bundles one chunk's build product and receipt with the sandbox they
    /// were built in — the unit `prepareChunkState`/`rebuildChunkState`
    /// (the schemata timeout-isolation design) produce and every per-entry spawn consumes. Kept as a
    /// value, never mutated in place: a rebuild produces an entirely new
    /// `ChunkExecutionState`, it never patches an existing one.
    struct ChunkExecutionState {
        /// Destroyed and recreated as a unit by a recovery rebuild.
        let container: Sandbox
        let artifact: BuildArtifact
        let receipt: SchemataBuildReceipt?
        /// The workspace the chunk is built and run in.
        var sandbox: URL {
            container.workspaceRoot
        }

        /// The container's directory name, which timing spans label a chunk by.
        var chunkLabel: String {
            container.containerRoot.lastPathComponent
        }
    }

    /// `prepareChunkState`'s result: either a usable `ChunkExecutionState`,
    /// or the already-final `EntryRunOutcome`s every entry this attempt
    /// covered must be reported as (never both — this is the same
    /// exhaustive four-way split `runChunk`'s own initial build already
    /// used, kept exhaustive rather than becoming a throwing `Error` so a
    /// non-`Error` payload like `[EntryRunOutcome]` can be carried directly).
    enum ChunkPreparationOutcome {
        case ready(ChunkExecutionState)
        /// `buildFailureEvent` is non-`nil` only for the typed-`BuildFailure`
        /// shape (shared chunk build-failure attribution); `infrastructureFallbackEvent` is
        /// non-`nil` only for the build-receipt-unavailable shape. Mutually
        /// exclusive in practice (each failure path populates at most one),
        /// kept as two separate optionals rather than one combined enum so
        /// each aggregation site downstream can accumulate the two kinds
        /// into their own separate arrays without an extra unwrap.
        case failed(
            [EntryRunOutcome], buildFailureEvent: SharedChunkBuildFailureEvent? = nil,
            infrastructureFallbackEvent: SchemataInfrastructureFallbackEvent? = nil
        )
    }

    /// The single entry point for turning a sandbox into a built,
    /// receipt-resolved chunk — used both for a chunk's initial build and
    /// (the schemata timeout-isolation design) for every mid-chunk recovery rebuild after a forced
    /// timeout-kill, so both paths route through the exact same failure
    /// handlers by construction, never by separately-maintained duplicate
    /// logic: typed `BuildFailure` -> whole-`MutationID` dynamic isolated
    /// fallback (shared chunk build-failure attribution — a shared chunk build's `BuildFailure`
    /// is chunk-level evidence, not per-mutant compile evidence, so it must
    /// not directly establish `.unviable` for entries it merely happened to
    /// contain), untyped error / nil product hash -> `infrastructureFailure`
    /// (unchanged), receipt-resolution failure -> whole-chunk
    /// `.buildReceiptUnavailable` isolated fallback — no schemata execution
    /// ever proceeds without a proven receipt.
    private func prepareChunkState(
        program: SchemataProgram, entries embeddedEntries: [SchemataPlanEntry], in container: Sandbox
    ) async -> ChunkPreparationOutcome {
        let sandbox = container.workspaceRoot
        let artifact: BuildArtifact
        do {
            artifact = try await build.buildSchemataChunk(loweredSources: program.loweredSources, in: sandbox)
        } catch let failure as BuildFailure {
            // Chunk-level evidence only (shared chunk build-failure attribution): the shared
            // lowered program did not compile, which proves nothing about
            // any individual entry's own mutation. Every `MutationID` this
            // failed build/rebuild attempt covers falls back to isolated
            // mode as a whole — never per-placement — joining the same
            // all-or-nothing dynamic-fallback mechanism `run()` already
            // uses for activation/hang-budget fallback (see that function's
            // own `dynamicFallbackReasons` scan). Only a subsequent
            // isolated-mode build/test, verified by `MutationVerdictVerifier`
            // exactly as it is today, may establish `.unviable` for one of
            // these `MutationID`s. `failure` itself is preserved (not
            // discarded) so the fan-out/observability event below can
            // reference its own diagnosis — one aggregate event per failed
            // chunk build, never one per affected `MutationID`.
            return .failed(
                embeddedEntries.map { .isolatedFallback(mutationID: $0.mutationID, reason: .sharedChunkBuildFailure) },
                buildFailureEvent: SharedChunkBuildFailureEvent(
                    chunkID: program.chunkID, affectedMutationCount: embeddedEntries.count, diagnosticReference: failure.diagnosis
                )
            )
        } catch {
            return .failed(embeddedEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the chunk build could not be run: \(error)")
            }.map(EntryRunOutcome.verified))
        }

        guard artifact.productHash != nil else {
            return .failed(embeddedEntries.compactMap {
                infrastructureFailureResult(
                    for: $0, reason: "the chunk build produced no product hash, so its evidence cannot be trusted"
                )
            }.map(EntryRunOutcome.verified))
        }

        // Real per-compilation-unit, per-image LC_UUID identity (the build-time half of the image-identity proof and unit-to-image mapping)
        // — resolved through the build
        // system's own metadata (`SwiftPMCompilationUnitImageResolver`'s
        // dependency-graph reachability, or Xcode's per-target build
        // settings), never through a target-name substring match. A
        // request this stage cannot build (a malformed/missing
        // `sourceEmbeddingID` or lowerer identity on the entry itself) is
        // simply left unresolved for that one entry — `expectedImageUUIDs`
        // below falls back to the product-hash placeholder for it, the
        // same "not proven, not guessed" discipline the rest of this
        // pipeline already uses for an ambiguous mapping.
        var requestsByMutationID: [MutationID: SchemataCompilationUnitTargetRequest] = [:]
        for entry in embeddedEntries {
            guard
                let point = points[entry.mutationID],
                let sourceEmbeddingIDString = entry.sourceEmbeddingID,
                let sourceEmbeddingID = SHA256Digest(rawValue: sourceEmbeddingIDString),
                let lowererID = entry.lowererID,
                let lowererVersion = entry.lowererVersion
            else { continue }

            let compilationUnitID = CompilationUnitID.derive(
                projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
                sourcePath: point.file, lowererID: lowererID, lowererVersion: lowererVersion
            )
            requestsByMutationID[entry.mutationID] = SchemataCompilationUnitTargetRequest(
                compilationUnitID: compilationUnitID,
                sourceEmbeddingID: sourceEmbeddingID,
                buildTarget: BuildTargetIdentity(projectIdentity: entry.projectIdentity, targetName: entry.target, moduleName: entry.module)
            )
        }

        // Two mutations in the same file (same target/module/lowerer) share
        // one compilation unit — `SchemataBuildReceipt` rightly refuses a
        // duplicate `CompilationUnitID`, so the request list passed to the
        // resolver is deduplicated by that ID before the call, not per
        // mutation.
        var uniqueRequestsByUnit: [CompilationUnitID: SchemataCompilationUnitTargetRequest] = [:]
        for request in requestsByMutationID.values {
            uniqueRequestsByUnit[request.compilationUnitID] = request
        }

        let receiptContext = SchemataBuildReceiptContext(
            planID: planID, workUnitID: workUnitID, chunkID: program.chunkID,
            toolchainHash: toolchainHash, buildArgumentsHash: buildArgumentsHash
        )
        // `SchemataBuildable.resolveSchemataBuildReceipt`'s own protocol
        // contract: fail closed (throw) when the built image cannot be
        // resolved to a provably unique identity — never resolve
        // ambiguously and never stand in a placeholder. A previous version
        // of this call absorbed that throw via a bare `try?`, letting the
        // chunk proceed with `receipt: nil` and every one of its
        // mutations scored (or not) with no proof of which built image
        // they actually reached. Receipt resolution failing is not a
        // per-mutant infrastructure failure — it means schemata itself
        // cannot vouch for this chunk at all, so every `MutationID` it
        // covers falls back to isolated mode as a whole, the identical
        // all-or-nothing shape `.sharedChunkBuildFailure` already uses for
        // a genuine compile failure.
        do {
            let receipt = try await build.resolveSchemataBuildReceipt(
                for: Array(uniqueRequestsByUnit.values), artifact: artifact, in: sandbox, context: receiptContext
            )
            return .ready(ChunkExecutionState(container: container, artifact: artifact, receipt: receipt))
        } catch {
            return .failed(
                embeddedEntries.map { .isolatedFallback(mutationID: $0.mutationID, reason: .buildReceiptUnavailable) },
                infrastructureFallbackEvent: SchemataInfrastructureFallbackEvent(
                    chunkID: program.chunkID, reason: .buildReceiptUnavailable,
                    affectedMutationCount: embeddedEntries.count,
                    diagnosis: "the chunk's own build receipt could not be resolved: \(error)"
                )
            )
        }
    }

    /// The timeout-isolation design's containment mechanism. Called
    /// whenever a forced timeout-kill (primary or confirmation run) is
    /// observed, for every not-yet-finalized entry the caller passes in
    /// `remainingEntries` — never a subset the caller forgot to include,
    /// since the caller (the `runEntries` scheduler) is the only place that
    /// knows which entries are still unresolved. Unconditional: the
    /// existing sandbox/build product is discarded and never reused,
    /// regardless of whether the timeout that triggered this call is later
    /// classified `.verifiedTimeout` or `.flaky` — that classification
    /// question belongs to `MutationVerdictVerifier` alone (fail-closed timeout evidence)
    /// and is never consulted here.
    ///
    /// Sandbox recreation reuses `program.chunkID` — `WorkspaceManager
    /// .createSandbox(id:)` is deterministic by `id`, so destroy-then-create
    /// under the same chunk ID always yields the same directory, freshly
    /// emptied. The rebuild itself (once a fresh sandbox exists) routes
    /// through the exact same `prepareChunkState` every initial chunk build
    /// already uses, so a mid-chunk recovery rebuild failure is handled by
    /// the identical four-way split (the post-hang recovery semantics(d)), never a separately
    /// maintained duplicate.
    func rebuildChunkState(
        program: SchemataProgram, entries remainingEntries: [SchemataPlanEntry], state: ChunkExecutionState
    ) async -> ChunkPreparationOutcome {
        try? await session.workspaces.destroySandbox(state.container)
        let sandbox: Sandbox
        do {
            let sandboxCreateStart = GateTimingRecorder.shared.now()
            sandbox = try await session.workspaces.createSandbox(id: program.chunkID)
            await GateTimingRecorder.shared.record("chunk.sandboxCreate", chunkID: program.chunkID, start: sandboxCreateStart)
        } catch {
            return .failed(remainingEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the recovery sandbox could not be recreated: \(error)")
            }.map(EntryRunOutcome.verified))
        }
        return await prepareChunkState(program: program, entries: remainingEntries, in: sandbox)
    }

    /// The same derivation `runChunk`'s build-receipt resolution and the
    /// lowerer itself (`BoolLiteralSchemataLowerer.lower`) use — real
    /// compilation-unit identity, never a placeholder. Computed directly
    /// from `entry`/`point` (not read back from `runChunk`'s own per-entry
    /// request map) so this holds even for an entry that map left
    /// unresolved (a malformed `sourceEmbeddingID`, say): the chain check
    /// still has a real, derived unit to check the runtime's own report
    /// against, exactly mirroring `embeddingEvidence`'s existing
    /// `entry.lowererID ?? "unknown"` fallback discipline.
    static func compilationUnitID(for entry: SchemataPlanEntry, point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
            sourcePath: point.file, lowererID: entry.lowererID ?? "unknown", lowererVersion: entry.lowererVersion ?? 0
        )
    }

    static func targetIdentity(for entry: SchemataPlanEntry) -> TargetExecutionIdentity {
        TargetExecutionIdentity(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module, product: entry.product
        )
    }

    /// Mirrors `MutationRunner.finalize` (the authoritative verdict pipeline): the schemata
    /// path's single choke point from raw observations to a verified
    /// record. Unlike `MutationRunner`, this returns the
    /// `VerifiedMutationRecord` itself rather than a projected
    /// `MutationResult` — `run()` needs every target's own record intact
    /// to build `MultiTargetVerdict`s before any one of them is picked for
    /// display.
    func finalize(
        point: MutationPoint,
        sourceApplication: SourceApplicationOutcome? = nil,
        build: BuildObservation? = nil,
        test: SingleTestObservation? = nil,
        confirmations: [ConfirmationObservation] = [],
        infrastructureFailureDiagnosis: String? = nil
    ) -> VerifiedMutationRecord {
        let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: sourceApplication,
            build: build,
            coverage: nil,
            test: test,
            confirmations: confirmations,
            infrastructureFailureDiagnosis: infrastructureFailureDiagnosis
        )
        archive(observations)
        return MutationVerdictVerifier.verify(observations, policy: session.policy)
    }

    /// Writes `observations` to the run's evidence archive, when one was
    /// requested. Mirrors `MutationEvidenceAssembler.archiveEvidence`: a write
    /// failure is counted on the writer (warned once, aggregated into one
    /// operational issue) and never touches the verdict. One file per
    /// `MutationID`, so a mutation placed in several targets keeps the last
    /// target's observations; `verify-run` then reports a mismatch rather than
    /// trusting an archive that does not describe the merged verdict.
    func archive(_ observations: MutationObservations) {
        guard let evidenceArchive else { return }
        do {
            try evidenceArchive.record(observations)
        } catch {
            let diagnosis = "evidence archive write failed for \(observations.plannedMutation.mutationID): \(error)"
            if evidenceArchive.noteWriteFailure(diagnosis) {
                FileHandle.standardError.write(
                    Data("warning: \(diagnosis) (further archive write failures are counted, not repeated)\n".utf8)
                )
            }
        }
    }

    /// The same `MutationObservations` shape `finalize` will eventually
    /// verify, built early so `runEntry` can ask `MutationVerdictVerifier
    /// .confirmationRequirement` whether a confirmation is needed *before*
    /// deciding to gather one — mirrors `finalize`'s own construction
    /// exactly (confirmations always empty here; that is the question this
    /// exists to answer, not something it can already know).
    func preliminaryObservations(
        point: MutationPoint, sourceApplication: SourceApplicationOutcome, build: BuildObservation, test: SingleTestObservation
    ) -> MutationObservations {
        MutationObservations(
            plannedMutation: PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID),
            sourceApplication: sourceApplication, build: build, coverage: nil, test: test
        )
    }
}
