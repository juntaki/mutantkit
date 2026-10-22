import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Gate 3 Phase H15C: a batched primary whose own result is ambiguous (omitted
/// from the batch result, or classified as an infrastructure failure) is
/// recovered through one fresh individual retry, then settles through the
/// unmodified per-entry state machine.
@Suite("SchemataMutationRunner: batched-primary ambiguity recovery (Gate 3 Phase H15C)")
struct SchemataMutationRunnerBatchRecoveryTests: SchemataBatchingTestHarness {
    typealias ChunkFixture = BatchingChunkFixture

    @Test("""
    A batched primary omitted entirely from the batch's own result dictionary is recovered via one fresh, individual \
    retry that settles survived — siblings sharing the same batch are untouched
    """)
    func omittedBatchResultIsRecoveredAsAPass() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        for index in 0 ..< 3 {
            adapter.scripts[fixture.token(at: index)] = .init(
                compilationUnitID: fixture.compilationUnitID(at: index), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
            )
        }
        // Entry 1's batch item is dispatched (its script still runs) but
        // never makes it into the returned dictionary at all — the "missing
        // batch configuration" shape `prepareBatchedPrimaries` already had
        // fallback code for, indistinguishable by the time this recovery
        // logic sees it from `classifyBatch`'s own `.infrastructureFailure`
        // classification (both normalize to the identical
        // `run.status == .infrastructureFailure` check).
        adapter.omitFromBatchResults = [fixture.sortedPoints[1].id]

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 3)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(
            try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .survived,
            "the recovered pass must settle survived, not infrastructureFailure"
        )
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .survived)

        #expect(adapter.schemataBatchCallCount == 1)
        // Exactly one individual dispatch: entry 1's own recovery retry.
        // Entries 0 and 2 — untouched siblings sharing the same batch —
        // never dispatch individually at all.
        #expect(adapter.individualRunSchemataTokenCallCount == 1, "only the ambiguous entry should be individually recovered")

        // The recovery used a fresh RunID, never the (discarded) batch
        // attempt's own — same discipline a confirmation's RunID already
        // has, checked directly rather than assumed.
        let runIDs = adapter.runIDsSeenByToken[fixture.token(at: 1)] ?? []
        #expect(runIDs.count == 2, "expected 2 dispatches for the recovered token: the discarded batch attempt + the recovery")
        #expect(runIDs.first != runIDs.last, "the recovery must use a fresh RunID, never the discarded batch attempt's own")
    }

    @Test("""
    A batched primary's ambiguous result, recovered as a crash, \
    goes through the exact same unmodified kill path an unbatched crash would
    """)
    func ambiguousBatchResultRecoveredAsACrashSettlesNormally() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // First dispatch (the discarded batch attempt) passes; the second
        // (the recovery) crashes — proving the recovered result is read
        // fresh, not the stale first attempt's own.
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.passed(includeHit: true), .crashed]
        )
        adapter.omitFromBatchResults = [fixture.sortedPoints[1].id]

        // confirmCrashKills: false — a crash settles immediately, the same
        // shape `batchedCrashingPrimarySettlesKilledByCrash` above already
        // established for an unbatched-from-the-start crash.
        let result = try await run(
            fixture, adapter: adapter, schemataTokenBatchSize: 2,
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
            )
        )

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .killedByCrash)
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 1, "no confirmation dispatch expected — confirmCrashKills is false")
    }

    @Test("""
    A batched primary's ambiguous result, recovered as a timeout, \
    still goes through the existing, unmodified timeout-confirmation path
    """)
    func ambiguousBatchResultRecoveredAsATimeoutStillConfirms() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // Dispatch 1 (discarded batch attempt): passes. Dispatch 2 (the
        // recovery): times out — routes to `.needsConfirmation`, same as
        // any other individually-timed-out primary. Dispatch 3 (the
        // resulting confirmation): also times out — confirmed hang.
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.passed(includeHit: true), .timedOut, .timedOut]
        )
        adapter.omitFromBatchResults = [fixture.sortedPoints[1].id]

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 2)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .verifiedTimeout)
        #expect(adapter.schemataBatchCallCount == 1)
        // Two individual dispatches: the recovery itself, plus the
        // confirmation its own `.timedOut` result triggered — never a
        // third, and never routed through `runSchemataTokenBatch` again.
        #expect(adapter.individualRunSchemataTokenCallCount == 2)

        let runIDs = adapter.runIDsSeenByToken[fixture.token(at: 1)] ?? []
        #expect(runIDs.count == 3, "discarded batch attempt + recovery + confirmation")
        #expect(Set(runIDs).count == 3, "all three dispatches must carry distinct RunIDs")
    }

    @Test("A recovery attempt that itself fails to launch is final — infrastructureFailure, no second retry")
    func recoveryThatItselfFailsIsFinal() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        adapter.omitFromBatchResults = [fixture.sortedPoints[1].id]
        // Armed by the (discarded) batch attempt's own dispatch, so it
        // fires on the *next* dispatch for this token — the recovery
        // itself — never the batch attempt being omitted here.
        adapter.beforeNextRun[fixture.token(at: 1)] = { [adapter] in
            adapter.throwOnNextRun.insert(fixture.token(at: 1))
        }

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 2)

        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .infrastructureFailure)
        #expect(adapter.schemataBatchCallCount == 1)
        // Exactly one individual dispatch attempt — the recovery that
        // itself failed to launch — never a second retry of the retry.
        #expect(adapter.individualRunSchemataTokenCallCount == 1)
    }

    @Test("An ordinary batch result (no ambiguity at all) never triggers any individual recovery dispatch")
    func ordinaryBatchResultNeverRecovers() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        for index in 0 ..< 3 {
            adapter.scripts[fixture.token(at: index)] = .init(
                compilationUnitID: fixture.compilationUnitID(at: index), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
            )
        }
        // Nothing omitted, nothing scripted to fail — every batch member's
        // own result is directly usable.

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 3)

        #expect(result.results.allSatisfy { $0.outcome == .survived })
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 0, "an unambiguous batch result must never trigger a recovery dispatch")
    }
}
