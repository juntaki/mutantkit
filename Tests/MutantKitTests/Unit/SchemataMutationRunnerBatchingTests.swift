import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Gate 3 Phase H5: `SchemataMutationRunner.runEntries`' upfront
/// `prepareBatchedPrimaries` pre-fetch — several entries' primary
/// observations resolved via one shared `runSchemataTokenBatch` call
/// instead of one `runSchemataToken` call each — folded back into the schemata timeout-isolation design's
/// unmodified per-entry state machine (Phase H4's split makes this
/// substitution possible without either side knowing about the other).
///
/// Reuses `FakeSchemataAdapter`'s `SchemataBatchTestable` conformance (Phase
/// H5): it dispatches every batch item through the identical
/// `runSchemataToken` script/transcript logic every other schemata suite
/// already trusts, so this suite is free to focus purely on scheduling —
/// which entries got batched, whether a confirmation still fires correctly,
/// whether an already-obtained sibling result survives a rebuild triggered
/// by someone else's timeout — not on re-proving the wire format again.
@Suite("SchemataMutationRunner: token batching (Gate 3 Phase H5)")
struct SchemataMutationRunnerBatchingTests: SchemataBatchingTestHarness {
    typealias ChunkFixture = BatchingChunkFixture

    // MARK: - Baseline: batching disabled (the default) never calls the batch method at all

    @Test("schemataTokenBatchSize's default (1) never calls runSchemataTokenBatch — every entry still runs the unbatched way")
    func defaultBatchSizeNeverBatches() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        for index in 0 ..< 3 {
            adapter.scripts[fixture.token(at: index)] = .init(
                compilationUnitID: fixture.compilationUnitID(at: index), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
            )
        }

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 1)

        #expect(result.results.count == 3)
        #expect(result.results.allSatisfy { $0.outcome == .survived })
        #expect(adapter.schemataBatchCallCount == 0)
        #expect(adapter.individualRunSchemataTokenCallCount == 3)
    }

    // MARK: - A batched primary settles exactly like an unbatched one would

    @Test("A batched passing primary settles survived, exactly as the unbatched path would — one shared batch call, no individual dispatch")
    func batchedPassingPrimarySettlesSurvived() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        for index in 0 ..< 3 {
            adapter.scripts[fixture.token(at: index)] = .init(
                compilationUnitID: fixture.compilationUnitID(at: index), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
            )
        }

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 3)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(result.results.count == 3)
        #expect(result.results.allSatisfy { $0.outcome == .survived })
        // One shared batch call covering all three, zero individual
        // dispatches — nothing needed its own confirmation.
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 0)
    }

    @Test("A batched crashing primary settles killedByCrash immediately, no confirmation, from the same batch call as its siblings")
    func batchedCrashingPrimarySettlesKilledByCrash() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID, behaviors: [.crashed]
        )
        adapter.scripts[fixture.token(at: 2)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 2), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        // confirmCrashKills: false — a crash settles immediately, matching
        // `SchemataMutationRunnerContainmentTests`'s own item 5(a) pattern.
        let result = try await run(
            fixture, adapter: adapter, schemataTokenBatchSize: 3,
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
            )
        )

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .killedByCrash)
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .survived)
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 0)
    }

    // MARK: - A batched primary timeout still routes into the existing, unmodified the schemata timeout-isolation design confirmation path

    @Test("""
    A batched primary timeout still triggers an individual confirmation (the existing timeout-confirmation path, unmodified); a confirmation \
    that resolves normally still settles flaky, never a direct verifiedTimeout
    """)
    func batchedPrimaryTimeoutStillConfirms() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // Middle entry: primary times out (via the batch), confirmation
        // (always individual — Phase H5 never batches confirmations)
        // resolves normally -> .flaky, schemata's own permanent invariant.
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .passed(includeHit: true)]
        )
        adapter.scripts[fixture.token(at: 2)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 2), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 3)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .flaky)
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .survived)

        // All three primaries came from the one shared batch call...
        #expect(adapter.schemataBatchCallCount == 1)
        // ...and exactly one individual dispatch happened afterward: entry
        // 1's own confirmation. If a sibling's already-obtained result were
        // ever incorrectly re-dispatched (e.g. as a side effect of Trigger
        // 2's rebuild before... nothing, since this is the last entry —
        // but a regression here would still show up as extra individual
        // calls), this would read higher than 1.
        #expect(adapter.individualRunSchemataTokenCallCount == 1)

        // The confirmation got its own fresh RunID, distinct from the
        // batched primary's — never reused.
        let runIDs = adapter.runIDsSeenByToken[fixture.token(at: 1)] ?? []
        #expect(runIDs.count == 2, "expected exactly 2 dispatches for the timed-out token: primary (batched) + confirmation")
        #expect(runIDs.first != runIDs.last, "the confirmation must use a fresh RunID, never its primary's")
    }

    // MARK: - A sibling's already-batched result survives a later entry's rebuild

    @Test("""
    Two siblings' batched-and-already-settled results are untouched by a later entry's own Trigger-1 rebuild — no rerun, no \
    result change, regardless of loop position
    """)
    func siblingResultsSurviveALaterEntrysRebuild() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        // Entries 0 and 2 sandwich the hang at entry 1 — both already
        // resolved via the same batch call entry 1 was part of.
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .passed(includeHit: true)]
        )
        adapter.scripts[fixture.token(at: 2)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 2), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 3)

        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .flaky)
        // Entry 2 — scheduled *after* entry 1's Trigger-1 rebuild in loop
        // order — still reads its pre-batched, pre-rebuild result rather
        // than being individually rerun against the rebuilt state.
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .survived)
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 1, "only entry 1's own confirmation should ever dispatch individually")
        // Trigger 1 still rebuilds once, for entry 1's own confirmation —
        // The schemata timeout-isolation design's rebuild mechanics are completely unmodified by batching.
        #expect(adapter.buildCallCount == 2)
    }

    // MARK: - Hang budget is unaffected by batching

    @Test("The hang budget still counts only verifier-confirmed verifiedTimeout entries, unaffected by which entries were batched")
    func hangBudgetUnaffectedByBatching() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // A confirmed (genuine) hang: primary AND confirmation both time out.
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        adapter.scripts[fixture.token(at: 2)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 2), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        // Budget = 1: exactly one confirmed hang stays at the budget, not over it.
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [fixture.program], points: fixture.pointsByID,
            originalSources: [fixture.relativePath: Data(fixture.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-hangbudget-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-hangbudget-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, maxVerifiedTimeoutsPerChunk: 1, selectCoveringTests: true,
            schemataTokenBatchSize: 3
        )
        adapter.perTestCoverageToReturn = fixture.perTestCoverage
        let result = try await runner.run()

        #expect(result.isolatedFallbacks.isEmpty, "one confirmed hang must stay within a budget of 1 — no overflow")
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .verifiedTimeout)
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .survived)
    }

    // MARK: - An unnarrowed entry (selectedTests == nil) is never batched

    @Test("An entry with no known covering-test selection is never batched, even when its siblings are — it always runs individually")
    func unnarrowedEntryIsNeverBatched() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        for index in 0 ..< 3 {
            adapter.scripts[fixture.token(at: index)] = .init(
                compilationUnitID: fixture.compilationUnitID(at: index), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
            )
        }
        // Entry 1 alone loses its attribution — present-but-empty, the real
        // shape of "covered, but no test uniquely attributed to it".
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        for (index, point) in fixture.sortedPoints.enumerated() {
            coveringTests[point.file, default: [:]][point.line] = index == 1 ? [] : [fixture.testsByPointIndex[index]]
        }
        adapter.perTestCoverageToReturn = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [fixture.program], points: fixture.pointsByID,
            originalSources: [fixture.relativePath: Data(fixture.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-unnarrowed-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-unnarrowed-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, selectCoveringTests: true, schemataTokenBatchSize: 3
        )
        let result = try await runner.run()

        #expect(result.results.count == 3)
        #expect(result.results.allSatisfy { $0.outcome == .survived })
        // Entries 0 and 2 (narrowed) share one batch call; entry 1
        // (unnarrowed) dispatches individually, unbatched.
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 1)
        #expect(adapter.selectedTestsSeen.contains(nil), "the unnarrowed entry must still run the full configured list, not an empty one")
    }

    // MARK: - An entry with more than one selected test is never batched (Gate 3 Phase H12.3)

    @Test("""
    An entry whose selection covers more than one test is never batched — even though it is narrowed, not nil — while its \
    single-test siblings still batch together normally
    """)
    func multiTestSelectionIsNeverBatched() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()
        for index in 0 ..< 3 {
            adapter.scripts[fixture.token(at: index)] = .init(
                compilationUnitID: fixture.compilationUnitID(at: index), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
            )
        }
        // Entry 1 alone has two covering tests — narrowed, non-empty, but
        // not the single-test shape Phase H12.3 requires for batch
        // eligibility (a token that can independently hang on either of two
        // tests must not share a batch's outer timeout with siblings; see
        // `prepareBatchedPrimaries`'s own doc comment).
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        for (index, point) in fixture.sortedPoints.enumerated() {
            coveringTests[point.file, default: [:]][point.line] = index == 1
                ? [fixture.testsByPointIndex[0], fixture.testsByPointIndex[1]]
                : [fixture.testsByPointIndex[index]]
        }
        adapter.perTestCoverageToReturn = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [fixture.program], points: fixture.pointsByID,
            originalSources: [fixture.relativePath: Data(fixture.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-multitest-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-multitest-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, selectCoveringTests: true, schemataTokenBatchSize: 3
        )
        let result = try await runner.run()

        #expect(result.results.count == 3)
        #expect(result.results.allSatisfy { $0.outcome == .survived })
        // Entries 0 and 2 (single-test selections) share one batch call;
        // entry 1 (two-test selection) dispatches individually, unbatched —
        // the same shape as the nil/unnarrowed case above, for a different
        // reason (a real, narrowed selection that is simply too wide to be
        // batch-safe, not a missing one).
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 1)
        #expect(
            adapter.selectedTestsSeen.contains(Set([fixture.testsByPointIndex[0], fixture.testsByPointIndex[1]])),
            "the multi-test entry must still run its own full two-test selection individually, not a batched subset"
        )
    }

    @Test("""
    A timeout in a single-test batched primary still routes through the existing individual confirmation path, \
    unchanged by Phase H12.3
    """)
    func singleTestBatchedTimeoutStillConfirmsIndividually() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        let result = try await run(fixture, adapter: adapter, schemataTokenBatchSize: 2)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .verifiedTimeout)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .survived)
        // Both single-test entries still share one batch call (Phase
        // H12.3's narrowing only excludes multi-test selections, not
        // single-test ones), and the timed-out entry's own confirmation is
        // the only individual dispatch — the exact the schemata timeout-isolation design path Phase H5
        // already proved unmodified, still true after Phase H12.3.
        #expect(adapter.schemataBatchCallCount == 1)
        #expect(adapter.individualRunSchemataTokenCallCount == 1)
    }
}
