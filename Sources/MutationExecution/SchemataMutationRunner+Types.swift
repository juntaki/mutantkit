import MutationModel

/// Public result and event types of `SchemataMutationRunner`, plus the small
/// value types its chunk scheduler passes around.
extension SchemataMutationRunner {
    /// What one full run produced. Raw pieces, not a `RunReport` — the CLI
    /// layer combines this with isolated-fallback results before building
    /// one report.
    public struct Outcome: Sendable {
        public let baseline: BaselineRecord
        /// One aggregate `MutationResult` per mutation, for display and
        /// for feeding a `RunReport` the same way isolated mode's results
        /// do. For a mutation embedded into more than one target, this is
        /// `multiTargetVerdicts`'s own aggregation policy's winner (kill
        /// in any target wins) — never a value computed separately from
        /// it, so `results` and `multiTargetVerdicts` can never disagree
        /// about which outcome won.
        public let results: [MutationResult]
        /// Every target's own verdict for every mutation, preserved in
        /// full (the authoritative verdict pipeline) — nothing about a losing target's
        /// evidence is discarded here, unlike multi-target embedding's
        /// `mergeMultiTargetResults`, which this replaces.
        public let multiTargetVerdicts: [MultiTargetVerdict]
        /// Every mutation this run attempted through schemata but could not
        /// score, for either of two structurally different reasons (see
        /// `SchemataFallbackReason`) — excluded entirely from
        /// `results`/`multiTargetVerdicts`: no schemata `TargetRecord` for
        /// this `MutationID`, for *any* of its target placements, was kept
        /// (`groupByMutation`'s own all-or-nothing rule — see `run()`).
        /// `SchemataRunOrchestration` re-runs each of these through
        /// isolated `MutationRunner` instead; this runner never scores
        /// them itself.
        public let isolatedFallbacks: [DynamicFallback]
        /// One aggregate event per chunk whose shared build genuinely
        /// failed to compile (shared chunk build-failure attribution's fan-out/observability
        /// requirement) — never one event per affected `MutationID`. Every
        /// `MutationID` a failed chunk's build covered still appears,
        /// individually, in `isolatedFallbacks` above with reason
        /// `.sharedChunkBuildFailure`; this array exists only so a
        /// systemic problem (one bad chunk taking down many `MutationID`s
        /// at once) is visible as the single widescale event it actually
        /// is, not diluted into what would otherwise look like many
        /// unremarkable individual fallbacks with no visible shared cause.
        public let sharedChunkBuildFailureEvents: [SharedChunkBuildFailureEvent]
        /// The identical fan-out/observability shape as
        /// `sharedChunkBuildFailureEvents`, for `SchemataInfrastructureFallbackEvent`
        /// instead — currently, a chunk whose own build succeeded but whose
        /// build receipt could not be resolved (`.buildReceiptUnavailable`).
        /// Every `MutationID` such a chunk covered still appears,
        /// individually, in `isolatedFallbacks` above.
        public let infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
    }

    /// One shared schemata chunk build (initial or mid-chunk recovery
    /// rebuild) that genuinely failed to compile — shared chunk build-failure attribution's
    /// required aggregate event, emitted once per failed build attempt,
    /// never once per affected `MutationID`. `diagnosticReference` is the
    /// build adapter's own already-computed `BuildFailure.diagnosis` (a
    /// stable, deterministic summary — not the full, much longer raw
    /// compiler `output`), the same field every other build-failure
    /// diagnosis in this codebase already surfaces as its explanation.
    public struct SharedChunkBuildFailureEvent: Sendable, Hashable {
        public let chunkID: String
        public let affectedMutationCount: Int
        public let diagnosticReference: String

        public init(chunkID: String, affectedMutationCount: Int, diagnosticReference: String) {
            self.chunkID = chunkID
            self.affectedMutationCount = affectedMutationCount
            self.diagnosticReference = diagnosticReference
        }
    }

    /// One shared-chunk-level infrastructure condition (currently: the
    /// chunk's own build succeeded, but the compilation-unit-to-built-image
    /// receipt could not be resolved for it) that sent every `MutationID`
    /// it covers to isolated fallback — the same "one aggregate event per
    /// occurrence, never one per affected `MutationID`" shape
    /// `SharedChunkBuildFailureEvent` already uses, kept as a distinct type
    /// (not folded into that one) because the *meaning* is different: this
    /// is not a compile failure at all, the chunk built and is otherwise
    /// usable, only its receipt could not be established. `reason` is
    /// carried explicitly (rather than being implied by which event type
    /// this is, the way `SharedChunkBuildFailureEvent` implies "compile
    /// failure") so this type can grow further infrastructure-only fallback
    /// causes later without becoming a second flavor of `SharedChunkBuildFailureEvent`.
    public struct SchemataInfrastructureFallbackEvent: Sendable, Hashable {
        public let chunkID: String
        public let reason: SchemataFallbackReason
        public let affectedMutationCount: Int
        public let diagnosis: String

        public init(chunkID: String, reason: SchemataFallbackReason, affectedMutationCount: Int, diagnosis: String) {
            self.chunkID = chunkID
            self.reason = reason
            self.affectedMutationCount = affectedMutationCount
            self.diagnosis = diagnosis
        }
    }

    /// Why a mutation could not be scored from schemata evidence, kept as
    /// structurally distinct cases rather than one flat enumeration
    /// (the schemata timeout-isolation design): `.activation` wraps `MutationVerdictVerifier
    /// .SchemataIsolatedFallbackReason` verbatim — the verifier remains the
    /// sole authority on *what that reason means*, this type only tags
    /// *where* the reason came from. `.hangBudgetExceeded` and
    /// `.sharedChunkBuildFailure` are never verdicts at all — both are this
    /// runner's own scheduling decisions, made without consulting, and
    /// without weakening, any verifier classification: `.hangBudgetExceeded`
    /// (fail-closed timeout evidence) that a `MutationID` could not be safely finished
    /// under schemata within one chunk's hang budget;
    /// `.sharedChunkBuildFailure` (shared chunk build-failure attribution) that a typed
    /// `BuildFailure` from the chunk's own shared build is chunk-level
    /// evidence only, never per-mutant compile evidence, so it cannot by
    /// itself establish any individual `MutationID`'s verdict — only a
    /// subsequent isolated-mode build/test may.
    public enum SchemataFallbackReason: Sendable, Hashable {
        case activation(MutationVerdictVerifier.SchemataIsolatedFallbackReason)
        case hangBudgetExceeded
        case sharedChunkBuildFailure
        /// The shared baseline's own aggregate coverage map already proves
        /// this line was never executed (`CoverageMap.isKnownUncovered`) —
        /// routed to isolated mode *before* any token was ever attempted,
        /// never after. Isolated mode's own `MutationRunner.prepare(...)`
        /// takes the identical fast path for the identical reason —
        /// confirmed empirically: without it, a full token attempt would be
        /// spent on a mutation this same shared coverage data already knew
        /// was unreachable.
        case knownUncovered
        /// The chunk's own shared build succeeded, but the compilation-
        /// unit-to-built-image receipt required to prove which built image
        /// this chunk's mutations actually reached could not be resolved
        /// (`SchemataBuildable.resolveSchemataBuildReceipt` threw, or
        /// resolved ambiguously). Never scored as if the receipt were
        /// simply absent (`receipt: nil` silently proceeding) — a build
        /// whose own image identity cannot be proven is schemata-unusable
        /// for every `MutationID` it covers, the same all-or-nothing
        /// discipline `.sharedChunkBuildFailure` already applies to a
        /// genuine compile failure, applied here to a different
        /// infrastructure failure with the identical consequence.
        case buildReceiptUnavailable
    }

    /// One mutation this run could not prove activation for from schemata
    /// evidence alone, and therefore never scored — see `Outcome
    /// .isolatedFallbacks`'s own doc comment.
    public struct DynamicFallback: Sendable, Hashable {
        public let mutationID: MutationID
        public let reason: SchemataFallbackReason

        public init(mutationID: MutationID, reason: SchemataFallbackReason) {
            self.mutationID = mutationID
            self.reason = reason
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        /// `record` is the failed baseline itself, carried rather than left
        /// to be re-synthesized by whoever catches this: everything a reader
        /// needs to tell a build failure from a suite that ran and failed
        /// (the commands, the durations, the test summary) lives on it, and
        /// a caller that only has `diagnosis` has no way to put any of it
        /// back. `SchemataRunOrchestration.merge` attaches exactly this
        /// record to the degraded report, which is what that function's own
        /// doc comment already promises a reader will see.
        case baselineDidNotPass(record: BaselineRecord, diagnosis: String)

        public var description: String {
            switch self {
            case let .baselineDidNotPass(_, diagnosis):
                "the schemata baseline did not pass, so no mutant can be scored against it: \(diagnosis)"
            }
        }
    }

    /// What one embedded entry's own attempt produced — either a fully
    /// verified schemata result, or a signal that this `MutationID` (every
    /// target placement, not just this one) needs to be re-run through
    /// isolated mode instead (see `Outcome.isolatedFallbacks`'s own doc
    /// comment).
    enum EntryRunOutcome {
        case verified(TargetRecord)
        case isolatedFallback(mutationID: MutationID, reason: SchemataFallbackReason)

        var mutationID: MutationID {
            switch self {
            case let .verified(record): record.record.mutationRef.mutationID
            case let .isolatedFallback(mutationID, _): mutationID
            }
        }
    }

    /// Concurrency-safe home for `completedPlacementsByMutationID`
    /// (the post-hang recovery semantics(b) — see `run()`'s own doc comment above where this is
    /// constructed for the full rationale). An `actor` rather than a plain
    /// `var` because `run()` now fans chunks out over a bounded
    /// `TaskGroup`: two chunks that both embed the same `MutationID` may run
    /// concurrently and each need an accurate, up-to-date-as-of-now count of
    /// the other's contribution when their own hang-budget-overflow check
    /// fires, not a snapshot frozen at whichever moment they started.
    actor CompletedPlacementsTracker {
        private var counts: [MutationID: Int] = [:]

        /// Read fresh at the exact moment a chunk's own hang-budget overflow
        /// fires (`runEntries`, right where `hangBudgetOverflowClosure` is
        /// called) — never once, frozen, at chunk start. A chunk-start
        /// snapshot goes stale the instant a concurrently-running sibling
        /// chunk folds its own contribution in later, mid-run: two chunks
        /// embedding the same `MutationID` can each be mid-flight when the
        /// other finishes, and by the time *this* chunk's own overflow
        /// actually fires — however much later that is — it must see
        /// whatever every other chunk has folded in as of *now*, not as of
        /// whenever this chunk happened to start.
        func snapshot() -> [MutationID: Int] { counts }

        /// Folded in once per chunk, only after that chunk fully returns —
        /// same fold-in point, same "once per `MutationID`, not once per
        /// outcome" dedup discipline the old loop used (see `runChunkTracked`).
        func fold(in mutationIDs: some Sequence<MutationID>) {
            for mutationID in mutationIDs {
                counts[mutationID, default: 0] += 1
            }
        }
    }

    /// The run-wide values every chunk needs besides its own program: the
    /// resolved per-mutant timeout controller, the baseline coverage, and the
    /// cross-chunk placement bookkeeping (`tracker` is a live reference, never
    /// a snapshot — see `CompletedPlacementsTracker.snapshot()`).
    struct ChunkRunContext: Sendable {
        let timeoutController: TimeoutController
        let perTestCoverage: PerTestCoverageMap?
        let coverage: CoverageMap?
        let expectedPlacementsByMutationID: [MutationID: Int]
        let tracker: CompletedPlacementsTracker
    }

    /// One chunk task's contribution to the `TaskGroup` in `run()` — the
    /// same two fields `ChunkRunResult` already carries, just `Sendable` and
    /// named for its role as a task-group element rather than as
    /// `runChunk`'s own return value (kept distinct from `ChunkRunResult`
    /// itself only because renaming that type's own long-established call
    /// sites is out of scope here).
    struct ChunkTaskOutcome: Sendable {
        let outcomes: [EntryRunOutcome]
        let buildFailureEvents: [SharedChunkBuildFailureEvent]
        let infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
    }

    /// One target's own verified record, paired with which target
    /// produced it — the raw material `groupIntoMultiTargetVerdicts` folds
    /// into one `MultiTargetVerdict` per mutation.
    struct TargetRecord {
        let targetIdentity: TargetExecutionIdentity
        let record: VerifiedMutationRecord
        let durationSeconds: Double
        let testDurationSeconds: Double?
    }

    /// One mutation's `MultiTargetVerdict`, paired with the raw
    /// `TargetRecord`s it was built from — kept alongside so
    /// `projectAggregate` can recover the winning target's own timing,
    /// which `TargetVerdict` itself does not carry.
    struct GroupedMutation {
        let verdict: MultiTargetVerdict
        let perTarget: [TargetRecord]
    }
}
