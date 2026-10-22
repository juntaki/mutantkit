import Foundation
import MutationModel
import SwiftFrontend

/// The per-chunk entry scheduler for `SchemataMutationRunner`.
extension SchemataMutationRunner {
    /// Runs every entry in a chunk in order, owning both the schemata timeout-isolation design trigger
    /// points that `runPrimary`/`runConfirmation` cannot see on their own:
    /// **Trigger 1** (containment before a confirmation that follows a
    /// primary forced timeout-kill — unconditional, never skipped) and
    /// **Trigger 2** (containment before the *next* entry, only when there
    /// is a next entry to protect — the timeout-isolation acceptance gate's "no wasted
    /// rebuild"). `state` is reassigned, never mutated in place, each time
    /// a rebuild succeeds; a rebuild failure reports §4(d)'s failure
    /// outcomes for every entry it was asked to protect and ends the
    /// chunk's loop immediately (nothing further is spawned against a
    /// sandbox this chunk failed to recover).
    ///
    /// Receives the live `tracker` actor, not a value snapshotted before
    /// this chunk began: the hang-budget-overflow check below reads it
    /// fresh, at the exact moment overflow actually fires, precisely so a
    /// concurrently-running sibling chunk's later mid-run fold-in is never
    /// missed by a start-of-chunk snapshot that has since gone stale.
    func runEntries(
        _ embeddedEntries: [SchemataPlanEntry], program: SchemataProgram, state initialState: ChunkExecutionState,
        context: ChunkRunContext
    ) async -> ChunkRunResult {
        var state = initialState
        var results: [EntryRunOutcome] = []
        var buildFailureEvents: [SharedChunkBuildFailureEvent] = []
        var infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent] = []
        // Bundles the three accumulators above at whatever point a caller
        // below needs to return early — kept as one function so a later
        // fourth accumulator never needs its own 1-line change repeated at
        // every one of this loop's several early-return sites. Positional,
        // via `ChunkRunResult`'s own convenience `init` — see its doc
        // comment.
        func currentResult() -> ChunkRunResult { ChunkRunResult(results, buildFailureEvents, infrastructureFallbackEvents) }
        // Fail-closed timeout evidence: increments only on a verifier-confirmed
        // `.verifiedTimeout`, never on a raw forced kill — a primary timeout
        // whose confirmation resolves normally stays `.flaky` and must never
        // count against this budget (see items 1/6's own tests).
        var hangBudgetCount = 0

        // Resolve as many entries' primary observations as possible via one
        // shared batched invocation, before the sequential scheduler below
        // ever starts. Every entry with a value here has *already* run —
        // the loop substitutes it directly instead of calling `runPrimary`.
        // Every entry *without* one (batching unsupported, ineligible, or
        // disabled) falls through to the existing per-entry call,
        // completely unchanged. Fetched once, against `initialState`:
        // entries covered here already have their final primary result
        // before the schemata timeout-isolation design's Trigger 1/2 rebuild logic ever runs for this
        // chunk, so a later rebuild (triggered by some *other* entry's own
        // timeout) never needs to touch, invalidate, or re-fetch them —
        // see `prepareBatchedPrimaries`'s own doc comment for why their
        // results remain valid regardless.
        let batchedPrimaries = await prepareBatchedPrimaries(
            embeddedEntries, state: initialState, timeoutController: context.timeoutController,
            perTestCoverage: context.perTestCoverage, coverage: context.coverage
        )

        /// Performs a mid-chunk rebuild for `remainingEntries` and folds the
        /// result into `state`/`results`. Returns `false` when the rebuild
        /// itself failed (§4(d)) — the caller must stop iterating in that
        /// case, since every entry this call was protecting has already been
        /// given its final `EntryRunOutcome` for this chunk: a verdict-
        /// bearing failure outcome for the two shapes that are genuine
        /// failures (sandbox-creation error, untyped build error), an
        /// `.isolatedFallback(reason: .sharedChunkBuildFailure)` — never a
        /// fabricated verdict — for a typed `BuildFailure` (Addendum 4), or
        /// an `.isolatedFallback(reason: .buildReceiptUnavailable)` when the
        /// rebuild succeeded but its own receipt could not be resolved.
        func rebuild(protecting remainingEntries: [SchemataPlanEntry]) async -> Bool {
            switch await rebuildChunkState(program: program, entries: remainingEntries, state: state) {
            case let .failed(failureOutcomes, buildFailureEvent, infrastructureFallbackEvent):
                results.append(contentsOf: failureOutcomes)
                if let buildFailureEvent { buildFailureEvents.append(buildFailureEvent) }
                if let infrastructureFallbackEvent { infrastructureFallbackEvents.append(infrastructureFallbackEvent) }
                return false
            case let .ready(newState):
                state = newState
                return true
            }
        }

        var index = 0
        while index < embeddedEntries.count {
            let entry = embeddedEntries[index]
            let rawTimedOut: Bool

            let primaryOutcome = await primaryOutcomeOrPrefetched(
                batchedPrimaries[entry.mutationID], entry: entry, state: state, timeoutController: context.timeoutController,
                perTestCoverage: context.perTestCoverage, coverage: context.coverage
            )

            switch primaryOutcome {
            case let .settled(outcome, primaryTimedOut):
                results.append(outcome)
                rawTimedOut = primaryTimedOut

            case let .needsConfirmation(handoff):
                // Trigger 1: unconditional, never skipped regardless of how
                // many entries remain — this entry's own about-to-run
                // confirmation must never reuse a sandbox a forced kill just
                // left in an unverified state.
                if handoff.primaryTimedOut {
                    guard await rebuild(protecting: Array(embeddedEntries[index...])) else { return currentResult() }
                }

                // If Trigger 1 just rebuilt, `handoff.request`'s receipt is
                // the stale, pre-rebuild one — always re-pin it to the
                // current state's receipt (a no-op when no rebuild happened)
                // rather than assume the two can never diverge.
                var request = handoff.request
                request.receipt = state.receipt
                // The SAME resolved limit the primary run this confirms
                // used — computed once in `runPrimary` from that entry's own
                // `selectedTests`, carried through `handoff`, never
                // recomputed here (and never the flat, chunk-wide fallback).
                let confirmation = await runConfirmation(
                    handoff.requirement, request: request, state: state,
                    timeoutSeconds: handoff.resolvedTimeoutSeconds,
                    selectedTests: handoff.selectedTests
                )
                // Read before `finalize` is even called (fail-closed timeout evidence: a
                // raw supervision fact, checked before any verdict exists) —
                // `rawTimedOut` here can never be influenced by, or made to
                // depend on, the verdict `finalize` is about to compute.
                rawTimedOut = confirmation.run.status == .timedOut

                // Like isolated mode, the evidence carries the confirming run's own
                // record so `verify-run` can see it. `timedOutAgain`/`crashedAgain`
                // start false; `MutationEvidence.verifierAuthored` sets them from the
                // verifier's own folded confirmation chain, never from this runner.
                let confirmedEvidence = handoff.evidence.addingRunnerConfirmations(
                    for: handoff.requirement, buildCommand: state.artifact.command, confirmingRun: confirmation.run
                )
                let record = finalize(
                    point: handoff.point, sourceApplication: .applied(confirmedEvidence),
                    build: handoff.buildObservation, test: handoff.testObservation, confirmations: [confirmation]
                )
                results.append(.verified(TargetRecord(
                    targetIdentity: handoff.targetIdentity, record: record,
                    durationSeconds: Date().timeIntervalSince(handoff.startedAt),
                    testDurationSeconds: Date().timeIntervalSince(handoff.testStartedAt)
                )))
                if record.outcome == .verifiedTimeout {
                    hangBudgetCount += 1
                }
            }

            // Hang-budget overflow (fail-closed timeout evidence and post-hang recovery(b)) — checked before
            // Trigger 2: an overflowing chunk closes out everything it has
            // left unconditionally, so there is nothing left for Trigger 2
            // to protect once this fires.
            //
            // Fetched fresh, right here, right now — never a value carried
            // in from before this chunk started. A concurrently-running
            // sibling chunk that shares a `MutationID` with this one may
            // finish and fold its own contribution in at any point during
            // this chunk's run, including well after this chunk began; only
            // a read taken at the moment overflow actually fires can be
            // trusted to reflect that.
            if hangBudgetCount > maxVerifiedTimeoutsPerChunk {
                let latestCompleted = await context.tracker.snapshot()
                results.append(contentsOf: hangBudgetOverflowClosure(
                    embeddedEntries, upThroughIndex: index,
                    expectedPlacementsByMutationID: context.expectedPlacementsByMutationID,
                    completedPlacementsByMutationID: latestCompleted
                ))
                return currentResult()
            }

            // Trigger 2: only when a next entry actually exists to protect
            // (the timeout-isolation acceptance gate — rebuilding after the chunk's last spawn
            // is wasted work, verified by construction here, not assumed).
            let remaining = Array(embeddedEntries[(index + 1)...])
            if rawTimedOut, !remaining.isEmpty {
                guard await rebuild(protecting: remaining) else { return currentResult() }
            }

            index += 1
        }
        return currentResult()
    }

    /// Closes out every not-yet-fully-finalized `MutationID` in this chunk
    /// once its hang budget is exceeded (fail-closed timeout evidence and post-hang recovery(b)): every entry
    /// this chunk has not yet run (`upThroughIndex+1...`, always
    /// unfinalized by definition), plus every entry this chunk *has* already
    /// run (`0...upThroughIndex`) whose `MutationID` is not yet fully
    /// finalized once this chunk's own contribution is counted —
    /// `completedPlacementsByMutationID` only reflects *other, already-
    /// returned* chunks (`run()` folds a chunk's own outcomes in only after
    /// it fully returns), so `+1` here accounts for the current chunk's own
    /// placement, per §0's fact that one `MutationID` appears at most once
    /// per chunk. A `MutationID` this closes out may already have a
    /// `.verified` entry earlier in `results` from this same chunk — that is
    /// intentional, not a bug: `run()`'s existing all-or-nothing scan drops
    /// every `.verified` record for any `MutationID` with *any*
    /// `.isolatedFallback` entry, so emitting a second entry here is exactly
    /// what makes the whole `MutationID` (not just its unfinished
    /// placements) fall back to isolated mode, with zero changes to that
    /// scan.
    func hangBudgetOverflowClosure(
        _ embeddedEntries: [SchemataPlanEntry], upThroughIndex index: Int,
        expectedPlacementsByMutationID: [MutationID: Int], completedPlacementsByMutationID: [MutationID: Int]
    ) -> [EntryRunOutcome] {
        var outcomes: [EntryRunOutcome] = []
        for remainingEntry in embeddedEntries[(index + 1)...] {
            outcomes.append(.isolatedFallback(mutationID: remainingEntry.mutationID, reason: .hangBudgetExceeded))
        }
        for seenEntry in embeddedEntries[0 ... index] {
            let priorCount = completedPlacementsByMutationID[seenEntry.mutationID] ?? 0
            let expected = expectedPlacementsByMutationID[seenEntry.mutationID] ?? 1
            if priorCount + 1 < expected {
                outcomes.append(.isolatedFallback(mutationID: seenEntry.mutationID, reason: .hangBudgetExceeded))
            }
        }
        return outcomes
    }
}
