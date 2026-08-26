import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Concurrency-correctness coverage for `SchemataMutationRunner` running
/// independent chunks in parallel (`workers` > 1) — the change this suite
/// pins: chunk-level fan-out bounded by a `TaskGroup` (mirroring
/// `MutationRunner.evaluate`'s own "one in, one out" pattern), and
/// `completedPlacementsByMutationID` (ADR-0008 §4(b)) moved into
/// `CompletedPlacementsTracker`, a private actor, so a later-queued chunk's
/// own hang-budget-overflow check sees an accurate, up-to-date-as-of-now
/// count of every *other*, already-finished chunk's contribution — never a
/// data race, and never a snapshot frozen at the wrong moment.
///
/// Mirrors `SchemataMutationRunnerHangBudgetOverflowTests`'s own fixture
/// helpers (same source, same entry/program construction) rather than
/// duplicating a different shape, since the scenario this suite exercises
/// (a `MutationID` embedded in two different chunks) is the same one that
/// suite already covers sequentially — this suite's job is to prove the
/// identical invariant holds when chunks genuinely run at the same time.
@Suite("SchemataMutationRunner: concurrent chunk execution")
struct SchemataMutationRunnerConcurrencyTests {
    // MARK: - Fixture

    private static let source = """
    func flagA() -> Bool { true }
    func flagB() -> Bool { true }
    func flagC() -> Bool { true }
    func flagD() -> Bool { true }

    """
    private static let relativePath = "Widget.swift"
    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func points() throws -> [MutationPoint] {
        let discovered = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        let sorted = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
        precondition(sorted.count == 4, "expected 4 bool-literal candidates (flagA..flagD), found \(sorted.count)")
        return sorted
    }

    private func entry(
        mutationID: MutationID, target: String, chunkID: String, namespace: UInt64
    ) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: chunkID, selectorToken: SchemataSelectorToken(namespace: namespace, localIndex: 1),
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app"
        )
    }

    private func program(chunkID: String, entries: [SchemataPlanEntry]) -> SchemataProgram {
        SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: entries
        )
    }

    private func compilationUnitID(target: String, point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: target, module: target,
            sourcePath: point.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )
    }

    private static let confirmsTimeoutsOnly = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
    )

    private func makeRunner(
        _ programs: [SchemataProgram], points: [MutationID: MutationPoint], adapter: FakeSchemataAdapter,
        maxVerifiedTimeoutsPerChunk: Int = 3, workers: Int
    ) throws -> SchemataMutationRunner {
        SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: points,
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-concurrency-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-concurrency-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, maxVerifiedTimeoutsPerChunk: maxVerifiedTimeoutsPerChunk,
            workers: workers
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - (a) Every chunk's entries present exactly once under real concurrency

    @Test("workers: 2 across four independent single-entry chunks — every mutation scored exactly once, none lost or duplicated")
    func allChunksEntriesPresentExactlyOnceUnderConcurrency() async throws {
        let allPoints = try points()
        let targets = ["TA", "TB", "TC", "TD"]
        let namespaces: [UInt64] = [1, 2, 3, 4]

        let adapter = FakeSchemataAdapter()
        var entries: [MutationID: MutationPoint] = [:]
        var programs: [SchemataProgram] = []
        for (index, point) in allPoints.enumerated() {
            let target = targets[index]
            let namespace = namespaces[index]
            let chunkID = "chunk-\(index)"
            let planEntry = entry(mutationID: point.id, target: target, chunkID: chunkID, namespace: namespace)
            programs.append(program(chunkID: chunkID, entries: [planEntry]))
            entries[point.id] = point
            adapter.scripts[SchemataSelectorToken(namespace: namespace, localIndex: 1)] = .init(
                compilationUnitID: compilationUnitID(target: target, point: point), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
            )
        }

        let runner = try makeRunner(programs, points: entries, adapter: adapter, workers: 2)
        let outcome = try await runner.run()

        // No loss, no duplication: every one of the 4 independent chunks'
        // single entry is scored exactly once, nothing routed to fallback.
        #expect(outcome.results.count == 4)
        #expect(outcome.isolatedFallbacks.isEmpty)
        #expect(Set(outcome.results.map(\.id)) == Set(allPoints.map(\.id)))
        // Each build happened exactly once — no chunk was silently
        // skipped, retried, or run twice under the bounded `TaskGroup`.
        #expect(adapter.buildCallCount == 4)
    }

    // MARK: - (b) Cross-chunk multi-target accounting under genuine concurrency

    /// The scenario `SchemataMutationRunnerHangBudgetOverflowTests` covers
    /// sequentially (a `MutationID` embedded in two chunks, one of which
    /// overflows its hang budget), run here so the two chunks involved
    /// actually execute *concurrently* under a real `TaskGroup`
    /// (`workers: 2`), with `FakeSchemataAdapter.delayNanosecondsBeforeRun`
    /// forcing a deterministic interleaving: chunk A (X's other placement)
    /// is made to finish, and fold its contribution into the shared
    /// `CompletedPlacementsTracker` actor, *before* chunk C — queued behind
    /// a deliberately slow filler chunk B so it starts only once a worker
    /// slot frees up — takes its own snapshot and hits its own overflow.
    /// If the tracker were an unsynchronized shared dictionary (a data
    /// race) or if the snapshot were taken at the wrong logical point, this
    /// would either crash/corrupt under concurrent mutation or incorrectly
    /// drop X even though its other placement had, in fact, already fully
    /// finalized by the time chunk C's overflow fired.
    @Test("""
    Under real chunk concurrency (workers: 2), a later-queued chunk's hang-budget-overflow check accurately reflects \
    an already-finished sibling chunk's contribution to a cross-chunk MutationID, keeping it out of the fallback set
    """)
    func laterQueuedChunkSeesAlreadyFinishedSiblingsContribution() async throws {
        let allPoints = try points()
        let x = allPoints[0]
        let w = allPoints[1]
        let y = allPoints[2]

        let targetA = "TA"
        let targetB = "TB"
        let targetC = "TC"

        // Chunk A: X's first placement. Fast — no delay — so it always wins
        // the race to free a worker slot ahead of chunk B.
        let entryXA = entry(mutationID: x.id, target: targetA, chunkID: "chunk-A", namespace: 1)
        // Chunk B: unrelated filler, deliberately slow, occupying the
        // second worker slot so chunk C is queued (not launched
        // simultaneously with A) — forcing C's tracker snapshot to be taken
        // strictly after A has already fully returned and folded in.
        let entryWB = entry(mutationID: w.id, target: targetB, chunkID: "chunk-B", namespace: 2)
        // Chunk C: X's second placement, followed by Y, which triggers C's
        // own hang-budget overflow (budget = 0, one confirmed hang alone
        // exceeds it).
        let entryXC = entry(mutationID: x.id, target: targetC, chunkID: "chunk-C", namespace: 3)
        let entryYC = entry(mutationID: y.id, target: targetC, chunkID: "chunk-C", namespace: 4)

        let programA = program(chunkID: "chunk-A", entries: [entryXA])
        let programB = program(chunkID: "chunk-B", entries: [entryWB])
        let programC = program(chunkID: "chunk-C", entries: [entryXC, entryYC])

        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetA, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetB, point: w), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 3, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetC, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 4, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetC, point: y), sourceEmbeddingID: Self.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        // Chunk B's own entry is deliberately slow (well past the time
        // chunk A and chunk C's own entries need) so it never wins the race
        // to free a slot before chunk C is queued behind it, and never
        // finishes before chunk C's own overflow fires either.
        adapter.delayNanosecondsBeforeRun[SchemataSelectorToken(namespace: 2, localIndex: 1)] = 300_000_000

        let runner = try makeRunner(
            [programA, programB, programC], points: [x.id: x, w.id: w, y.id: y], adapter: adapter,
            maxVerifiedTimeoutsPerChunk: 0, workers: 2
        )
        let outcome = try await runner.run()

        // Y caused chunk C's own overflow but is itself fully finalized —
        // its own real .verifiedTimeout stands.
        #expect(outcome.results.contains { $0.id == y.id && $0.outcome == .verifiedTimeout })

        // X is NOT dropped: chunk A (its other placement) had already fully
        // returned — and folded its contribution into the shared tracker —
        // before chunk C, queued behind the slow filler chunk B, ever took
        // its own snapshot. Both of X's placements verified fine, so X is
        // fully finalized and keeps its real schemata result.
        #expect(!outcome.isolatedFallbacks.contains { $0.mutationID == x.id })
        #expect(outcome.results.contains { $0.id == x.id })
        #expect(outcome.multiTargetVerdicts.first { $0.mutationRef.mutationID == x.id }?.perTarget.count == 2)

        // W (chunk B's own unrelated entry) is unaffected by any of this.
        #expect(outcome.results.contains { $0.id == w.id })
    }

    // MARK: - (b2) Freshness: a chunk that is already running must not act on a stale start-of-chunk snapshot

    /// Distinct from `laterQueuedChunkSeesAlreadyFinishedSiblingsContribution`
    /// above: that test forces chunk C to be *queued* behind a slow filler
    /// chunk B, so chunk A has already fully returned and folded in
    /// *before* chunk C is even launched — C's start-of-chunk snapshot (the
    /// pre-fix behaviour) would already have been correct in that scenario,
    /// since nothing changes between C's start and C's overflow.
    ///
    /// This test instead launches chunk A and chunk C *simultaneously*
    /// (`workers: 2`, only two programs, no filler needed — both win a
    /// worker slot in the very first batch). Chunk C's own first entry is
    /// deliberately slowed (`delayNanosecondsBeforeRun`) so that chunk A —
    /// fast, undelayed — completes and folds its contribution into the
    /// shared tracker *while chunk C is already mid-run*, strictly after
    /// whatever snapshot chunk C might have taken at its own start. Chunk
    /// C's own hang-budget overflow only fires afterwards, once it finishes
    /// processing its second entry. A snapshot frozen at chunk C's start
    /// cannot see A's fold-in; a value read fresh at the moment overflow
    /// fires can. This is the exact staleness the fix in `runEntries`
    /// (fetching `tracker.snapshot()` immediately before calling
    /// `hangBudgetOverflowClosure`, instead of threading a value captured
    /// once in `runChunkTracked` before the chunk began) targets.
    @Test("""
    Under real chunk concurrency (workers: 2), a chunk already mid-run when a sibling finishes sees that sibling's \
    fold-in by the time its own hang-budget overflow fires, not a snapshot frozen at its own start
    """)
    func chunkAlreadyRunningSeesSiblingsMidRunFoldIn() async throws {
        let allPoints = try points()
        let x = allPoints[0]
        let z = allPoints[1]

        let targetA = "TA"
        let targetC = "TC"

        // Chunk A: X's first placement. No delay — completes (and folds
        // into the shared tracker) as fast as possible, guaranteed to
        // finish well before chunk C's own delayed first entry does.
        let entryXA = entry(mutationID: x.id, target: targetA, chunkID: "chunk-A", namespace: 1)

        // Chunk C: X's second placement first (deliberately slow, so chunk
        // C is still mid-run, past its own hypothetical start-of-chunk
        // snapshot point, when chunk A finishes), then Z, whose forced
        // timeout is what actually triggers chunk C's own hang-budget
        // overflow (budget = 0, one confirmed hang alone exceeds it).
        let entryXC = entry(mutationID: x.id, target: targetC, chunkID: "chunk-C", namespace: 2)
        let entryZC = entry(mutationID: z.id, target: targetC, chunkID: "chunk-C", namespace: 3)

        let programA = program(chunkID: "chunk-A", entries: [entryXA])
        let programC = program(chunkID: "chunk-C", entries: [entryXC, entryZC])

        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetA, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetC, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 3, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: targetC, point: z), sourceEmbeddingID: Self.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        // Chunk C's own first entry (X) is deliberately slow so chunk A —
        // undelayed — reliably finishes and folds in while chunk C is still
        // working through its own entries, well before chunk C's own
        // overflow (triggered by Z, its second entry) ever fires.
        adapter.delayNanosecondsBeforeRun[SchemataSelectorToken(namespace: 2, localIndex: 1)] = 300_000_000

        let runner = try makeRunner(
            [programA, programC], points: [x.id: x, z.id: z], adapter: adapter,
            maxVerifiedTimeoutsPerChunk: 0, workers: 2
        )
        let outcome = try await runner.run()

        // Z caused chunk C's own overflow but is itself fully finalized —
        // its own real .verifiedTimeout stands (only one placement, this
        // chunk's own, so it never needed anyone else's contribution).
        #expect(outcome.results.contains { $0.id == z.id && $0.outcome == .verifiedTimeout })

        // X is NOT dropped: chunk A (its other placement) finished and
        // folded into the shared tracker while chunk C was still mid-run —
        // strictly after any snapshot chunk C might have taken at its own
        // start, strictly before chunk C's own overflow fired. A fresh read
        // at overflow time sees it; a start-of-chunk snapshot would not
        // have.
        #expect(!outcome.isolatedFallbacks.contains { $0.mutationID == x.id })
        #expect(outcome.results.contains { $0.id == x.id })
        #expect(outcome.multiTargetVerdicts.first { $0.mutationRef.mutationID == x.id }?.perTarget.count == 2)
    }

    // MARK: - (c) workers: 1 regression backstop

    /// `workers: 1` must reproduce today's fully-sequential scheduling and
    /// output exactly: with concurrency capped at one chunk in flight, the
    /// bounded `TaskGroup` degenerates to "launch the next chunk only once
    /// the previous one's `group.next()` has returned" — the same snapshot
    /// point, the same fold-in point, and the same `entryOutcomes`
    /// accumulation order as the pre-parallel `for program in programs`
    /// loop. Constructing the runner two ways — once relying on the
    /// default (omitting `workers` entirely, exactly like every pre-existing
    /// call site in this codebase) and once passing `workers: 1` explicitly
    /// — and asserting they produce the same result is the direct proof
    /// that the new parameter's default did not change any existing
    /// caller's behavior.
    @Test("workers: 1 (the default) reproduces identical sequential output to explicitly passing workers: 1")
    func workersOneMatchesDefaultSequentialBehavior() async throws {
        let allPoints = try points()
        let x = allPoints[0]
        let y = allPoints[1]

        let targetA = "App"
        let targetB = "Widget"

        let entryXA = entry(mutationID: x.id, target: targetA, chunkID: "chunk-A", namespace: 1)
        let entryXB = entry(mutationID: x.id, target: targetB, chunkID: "chunk-B", namespace: 2)
        let entryY = entry(mutationID: y.id, target: targetB, chunkID: "chunk-B", namespace: 3)

        let programA = program(chunkID: "chunk-A", entries: [entryXA])
        let programB = program(chunkID: "chunk-B", entries: [entryXB, entryY])

        func makeAdapter() -> FakeSchemataAdapter {
            let adapter = FakeSchemataAdapter()
            adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
                compilationUnitID: compilationUnitID(target: targetA, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
            )
            adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
                compilationUnitID: compilationUnitID(target: targetB, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
            )
            adapter.scripts[SchemataSelectorToken(namespace: 3, localIndex: 1)] = .init(
                compilationUnitID: compilationUnitID(target: targetB, point: y), sourceEmbeddingID: Self.sourceEmbeddingID,
                behaviors: [.timedOut, .timedOut]
            )
            return adapter
        }

        // programs order: chunk-B (containing the hang) runs BEFORE
        // chunk-A — the exact fixture
        // `SchemataMutationRunnerHangBudgetOverflowTests
        // .overflowDropsCrossProgramMutationIDEntirely` already pins
        // sequentially; reproduced here under both the implicit default and
        // an explicit `workers: 1` to prove the two are identical.
        let defaultRunner = try makeRunner(
            [programB, programA], points: [x.id: x, y.id: y], adapter: makeAdapter(), maxVerifiedTimeoutsPerChunk: 0, workers: 1
        )
        let explicitRunner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [programB, programA], points: [x.id: x, y.id: y],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: makeAdapter(), test: makeAdapter(),
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-concurrency-default-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-concurrency-default-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, maxVerifiedTimeoutsPerChunk: 0
            // `workers` omitted entirely — proves the default (1) behaves
            // identically to passing it explicitly.
        )

        let defaultOutcome = try await defaultRunner.run()
        let explicitOutcome = try await explicitRunner.run()

        #expect(defaultOutcome.results.map(\.id) == explicitOutcome.results.map(\.id))
        #expect(defaultOutcome.results.map(\.outcome) == explicitOutcome.results.map(\.outcome))
        #expect(defaultOutcome.isolatedFallbacks == explicitOutcome.isolatedFallbacks)
        #expect(defaultOutcome.multiTargetVerdicts.map(\.mutationRef.mutationID) == explicitOutcome.multiTargetVerdicts.map(\.mutationRef.mutationID))

        // And matches the known-correct sequential expectation itself
        // (mirrors `overflowDropsCrossProgramMutationIDEntirely`): Y keeps
        // its real verdict, X is dropped to isolated fallback entirely.
        #expect(defaultOutcome.results.count == 1)
        #expect(defaultOutcome.results.first?.id == y.id)
        #expect(defaultOutcome.results.first?.outcome == .verifiedTimeout)
        #expect(defaultOutcome.isolatedFallbacks.count == 1)
        #expect(defaultOutcome.isolatedFallbacks.first?.mutationID == x.id)
        #expect(defaultOutcome.isolatedFallbacks.first?.reason == .hangBudgetExceeded)
    }
}
