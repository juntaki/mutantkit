import MutationModel
import SwiftFrontend

/// Cross-chunk bookkeeping and per-target aggregation for `SchemataMutationRunner`.
extension SchemataMutationRunner {
    /// One task-group child's whole lifecycle: run the chunk with a live
    /// reference to the tracker (never a value snapshotted up front — see
    /// `CompletedPlacementsTracker.snapshot()`'s own doc comment for why),
    /// fold this chunk's own contribution back into the tracker once it
    /// fully returns, return. Never called for more than one chunk
    /// concurrently from the same `Task` — `run()`'s `TaskGroup` is what
    /// bounds how many of these run at once (`workers`).
    func runChunkTracked(
        _ program: SchemataProgram, context: ChunkRunContext
    ) async -> ChunkTaskOutcome {
        let chunkResult = await runChunk(
            program, context: context
        )
        // Deduped by `MutationID`, not one increment per outcome: a chunk
        // whose own hang-budget overflow retroactively flags an earlier,
        // already-`.verified` entry in the *same* chunk (§4(b)) returns two
        // outcomes for that one `MutationID` (its verified record and the
        // overflow's `.isolatedFallback`) — both belong to the same single
        // placement this chunk contributed, so it must count once here, not
        // twice, or a later chunk's own finalization check would see an
        // inflated count.
        //
        // Deliberately not covered by an end-to-end `Outcome`-level test
        // (raised in review, disposed here rather than contrived): any
        // `MutationID` that ever earns a `.isolatedFallback` entry in one
        // chunk is *permanently* excluded from `results`/`multiTargetVerdicts`
        // by the dict-based scan in `run()`, for every chunk for the rest of
        // this run — count inflation for that same `MutationID` can only
        // ever make a later chunk's "already fully finalized" check pass
        // *more* easily, never less, and an already-excluded `MutationID`
        // staying excluded either way is not an observable difference in
        // `Outcome`. This dedup is correct-by-construction hygiene for the
        // internal invariant ("this dict counts placements, not outcomes"),
        // not something the current single consumer can be made to expose a
        // passing-vs-failing test for.
        await context.tracker.fold(in: Set(chunkResult.outcomes.map(\.mutationID)))
        return ChunkTaskOutcome(
            outcomes: chunkResult.outcomes, buildFailureEvents: chunkResult.buildFailureEvents,
            infrastructureFallbackEvents: chunkResult.infrastructureFallbackEvents
        )
    }

    /// How many of `programs`' own (embedded) entries exist for each
    /// `MutationID` — a mutation embedded into N targets appears in N
    /// different programs (`SchemataChunkPlanner.classify`), each
    /// contributing exactly one entry, so this is also "how many target
    /// placements must all finalize before this `MutationID` counts as
    /// done" (the post-hang recovery semantics(b)).
    static func expectedPlacementCounts(programs: [SchemataProgram]) -> [MutationID: Int] {
        var counts: [MutationID: Int] = [:]
        for program in programs {
            for entry in program.entries where entry.isEmbedded {
                counts[entry.mutationID, default: 0] += 1
            }
        }
        return counts
    }

    /// A mutation embedded into more than one target (see
    /// `SchemataChunkPlanner.classify`) runs — and is verified — once per
    /// target, independently, since each is a genuinely separate build.
    /// Groups every target's own record by `MutationID` into one
    /// `MultiTargetVerdict`, preserving every target's evidence — see
    /// `MultiTargetVerdict`'s own doc comment for why this replaced
    /// Multi-target embedding's lossy `mergeMultiTargetResults`.
    static func groupByMutation(_ perTarget: [TargetRecord]) throws -> [GroupedMutation] {
        var order: [MutationID] = []
        var grouped: [MutationID: [TargetRecord]] = [:]
        for entry in perTarget {
            let id = entry.record.mutationRef.mutationID
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(entry)
        }
        return try order.map { id in
            let records = grouped[id]!
            let verdict = try MultiTargetVerdict(
                mutationRef: records[0].record.mutationRef,
                perTarget: records.map { TargetVerdict(targetIdentity: $0.targetIdentity, record: $0.record) }
            )
            return GroupedMutation(verdict: verdict, perTarget: records)
        }
    }

    /// Projects a mutation's aggregate outcome into a single
    /// `MutationResult` for display — the specific `TargetRecord` whose
    /// own outcome equals `aggregateOutcome` (ties broken by `perTarget`'s
    /// own deterministic, identity-sorted order), never a value computed
    /// independently of it.
    static func projectAggregate(
        _ grouped: GroupedMutation, points: [MutationID: MutationPoint], planID: String, workUnitID: String
    ) throws -> MutationResult {
        let verdict = grouped.verdict
        // Ties broken by target identity, not by whichever chunk happened
        // to finish evaluating first: `grouped.perTarget` is orchestration
        // order (per-chunk completion), not the deterministic order
        // `verdict.perTarget` already sorts into.
        let winningIdentities = verdict.perTarget
            .filter { $0.record.outcome == verdict.aggregateOutcome }
            .map(\.targetIdentity)
        let winnerIdentity = winningIdentities.min() ?? verdict.perTarget[0].targetIdentity
        let winner = grouped.perTarget.first { $0.targetIdentity == winnerIdentity } ?? grouped.perTarget[0]
        guard let point = points[verdict.mutationRef.mutationID] else {
            preconditionFailure("no MutationPoint supplied for embedded mutation \(verdict.mutationRef.mutationID.rawValue)")
        }
        return try MutationResult.projected(
            from: winner.record, point: point, planID: planID, workUnitID: workUnitID,
            durationSeconds: winner.durationSeconds, testDurationSeconds: winner.testDurationSeconds
        )
    }
}
