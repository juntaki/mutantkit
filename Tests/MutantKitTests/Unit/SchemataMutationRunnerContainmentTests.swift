import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0008 §5 items 1, 2, 5(a), 6: the containment mechanism (Option B item
/// 1) — a forced timeout-kill (primary or confirmation) discards the current
/// chunk's sandbox/build product and rebuilds before any further process is
/// spawned against it, but an ordinary crash never triggers this, and a
/// rebuild is never spawned when there is nothing left in the chunk to
/// protect. The hang budget (Option B item 2, ADR §3.3) is deliberately not
/// exercised here — these tests keep `maxVerifiedTimeouts` effectively
/// unreachable so containment correctness is isolated from budget/overflow
/// correctness, per the implementation plan's phase sequencing.
@Suite("SchemataMutationRunner: ADR-0008 containment")
struct SchemataMutationRunnerContainmentTests {
    // MARK: - Fixture: an N-entry chunk, one bool-literal mutant per entry, all in one chunk

    private struct ChunkFixture {
        let source: String
        let relativePath: String
        let sortedPoints: [MutationPoint]
        let program: SchemataProgram
        let pointsByID: [MutationID: MutationPoint]

        static let projectIdentity = "App.xcodeproj"
        static let lowererID = "bool-literal"
        static let lowererVersion = 1
        static let target = "App"

        static func make(entryCount: Int, chunkID: String = "chunk-A") throws -> ChunkFixture {
            let relativePath = "Widget.swift"
            let source = (1 ... entryCount).map { "func flag\($0)() -> Bool { true }" }.joined(separator: "\n") + "\n"
            let discovered = try CoreOperatorExpansionTestSupport.discover(
                source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: relativePath
            )
            let sortedPoints = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
            precondition(sortedPoints.count == entryCount, "expected \(entryCount) bool-literal candidates, found \(sortedPoints.count)")

            let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))
            var entries: [SchemataPlanEntry] = []
            var pointsByID: [MutationID: MutationPoint] = [:]
            for (index, point) in sortedPoints.enumerated() {
                let token = SchemataSelectorToken(namespace: UInt64(index + 1), localIndex: 1)
                entries.append(SchemataPlanEntry(
                    mutationID: point.id,
                    placement: .embedded(placements: [
                        SchemataEmbeddedPlacement(
                            chunkID: chunkID, selectorToken: token,
                            sourceEmbeddingID: sourceEmbeddingID.rawValue, lowererID: lowererID, lowererVersion: lowererVersion,
                            projectIdentity: projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                        )
                    ]),
                    conflictGroup: nil, projectIdentity: projectIdentity, target: target, module: target, product: "\(target).app"
                ))
                pointsByID[point.id] = point
            }
            let program = SchemataProgram(
                chunkID: chunkID, sourceEmbeddingID: sourceEmbeddingID.rawValue,
                loweredSources: [SchemataSourceFile(relativePath: relativePath, contents: source)],
                entries: entries
            )
            return ChunkFixture(
                source: source, relativePath: relativePath, sortedPoints: sortedPoints, program: program, pointsByID: pointsByID
            )
        }

        func token(at index: Int) -> SchemataSelectorToken {
            SchemataSelectorToken(namespace: UInt64(index + 1), localIndex: 1)
        }

        func compilationUnitID(at index: Int) -> CompilationUnitID {
            CompilationUnitID.derive(
                projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
                sourcePath: sortedPoints[index].file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
            )
        }

        var sourceEmbeddingID: SHA256Digest { SHA256Digest.of(Data(source.utf8)) }
    }

    // MARK: - Running

    /// Confirms timeouts (needed to exercise Trigger 1/2 at all) but not
    /// crashes — `confirmCrashKills: false` keeps the crash-vs-hang test
    /// (item 5a) simple: a crash settles immediately, with no confirmation
    /// dispatch to reason about.
    private static let confirmsTimeoutsOnly = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
    )

    private func run(
        _ fixture: ChunkFixture, adapter: FakeSchemataAdapter,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = confirmsTimeoutsOnly,
        maxVerifiedTimeoutsPerChunk: Int = 3
    ) async throws -> SchemataMutationRunner.Outcome {
        try await run(
            [fixture.program], pointsByID: fixture.pointsByID, relativePath: fixture.relativePath, source: fixture.source,
            adapter: adapter, policy: policy, maxVerifiedTimeoutsPerChunk: maxVerifiedTimeoutsPerChunk
        )
    }

    private func run(
        _ programs: [SchemataProgram], pointsByID: [MutationID: MutationPoint], relativePath: String, source: String,
        adapter: FakeSchemataAdapter, policy: MutationVerdictVerifier.VerdictVerificationPolicy = confirmsTimeoutsOnly,
        maxVerifiedTimeoutsPerChunk: Int = 3
    ) async throws -> SchemataMutationRunner.Outcome {
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: pointsByID,
            originalSources: [relativePath: Data(source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-containment-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-containment-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: policy, maxVerifiedTimeoutsPerChunk: maxVerifiedTimeoutsPerChunk
        )
        return try await runner.run()
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func outcome(for mutationID: MutationID, in outcome: SchemataMutationRunner.Outcome) throws -> MutationResult {
        try #require(outcome.results.first { $0.id == mutationID })
    }

    // MARK: - Item 1: single hang, mid-chunk

    @Test("A single mid-chunk hang rebuilds once before the next entry; earlier and later entries verify correctly")
    func singleMidChunkHangRebuildsBeforeLaterEntries() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()

        // Entry 0: ordinary survivor, no confirmation needed.
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // Entry 1: primary times out, confirmation resolves normally -> .flaky
        // (schemata's own load-bearing invariant, unweakened by this ADR).
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .passed(includeHit: true)]
        )
        // Entry 2: ordinary survivor again — must run against the rebuilt state.
        adapter.scripts[fixture.token(at: 2)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 2), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        let result = try await run(fixture, adapter: adapter)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(result.results.count == 3)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .flaky)
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .survived)

        // One initial build (call 1) + exactly one Trigger-1 rebuild before
        // entry 1's confirmation (call 2). Entry 2 runs under call 2's
        // rebuilt artifact/receipt — its own clean `.survived` verdict is
        // only reachable if its transcript's image UUID and the receipt it
        // was resolved against are mutually consistent, which only holds if
        // it ran against the *same* (rebuilt) build the receipt came from.
        #expect(adapter.buildCallCount == 2)
    }

    // MARK: - Item 3: multiple hangs in one chunk, below the hang budget

    @Test("Multiple confirmed hangs below the hang budget each rebuild in bounded fashion; every non-hanging mutant still verifies")
    func multipleHangsBelowBudgetProduceBoundedRebuilds() async throws {
        let fixture = try ChunkFixture.make(entryCount: 3)
        let adapter = FakeSchemataAdapter()

        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // Entries 1 and 2: both primary AND confirmation time out -> two
        // independently reconfirmed, independently proven timeouts each ->
        // .verifiedTimeout (ADR §3.1's confirming-run-also-times-out branch).
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        adapter.scripts[fixture.token(at: 2)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 2), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )

        // Budget = 2: two confirmed hangs stays AT the budget (not exceeded).
        let result = try await run(fixture, adapter: adapter, maxVerifiedTimeoutsPerChunk: 2)

        #expect(result.isolatedFallbacks.isEmpty, "two confirmed hangs must stay within a budget of 2 — no overflow")
        #expect(result.results.count == 3)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .verifiedTimeout)
        #expect(try outcome(for: fixture.sortedPoints[2].id, in: result).outcome == .verifiedTimeout)

        // 1 initial build, + entry 1's Trigger-1 rebuild (before its
        // confirmation) and Trigger-2 rebuild (before entry 2, since entry
        // 1's own confirmation also timed out and entry 2 remains) = 2, +
        // entry 2's own Trigger-1 rebuild (before its confirmation) = 1.
        // Entry 2's confirmation also times out, but entry 2 is the chunk's
        // last entry, so Trigger 2 correctly does not fire a 4th time.
        // Total: 1 + 2 + 1 = 4 — a superset of the 2 *confirmed* hangs
        // (ADR Addendum 3), matching forced-timeout-kill count instead.
        #expect(adapter.buildCallCount == 4)
    }

    // MARK: - Item 2: hang on the last mutant — no wasted rebuild

    @Test("A hang on the chunk's last entry rebuilds once for its own confirmation, never a second wasted rebuild afterward")
    func hangOnLastEntrySkipsTheWastedTrailingRebuild() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()

        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        // Last entry: primary times out, confirmation *also* times out.
        // Trigger 1 must still fire once (before the confirmation) — but
        // since nothing remains after this entry, Trigger 2 must not fire a
        // second time.
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )

        let result = try await run(fixture, adapter: adapter)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(result.results.count == 2)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
        // Both the primary and the confirmation independently proved
        // activation and both timed out -> a real, reproducible hang.
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .verifiedTimeout)

        // Call 1 (initial) + call 2 (Trigger 1, before the last entry's
        // confirmation). If Trigger 2 wastefully fired too, this would be 3.
        #expect(adapter.buildCallCount == 2)
    }

    // MARK: - Item 5(a): a prompt crash never triggers containment

    @Test("An ordinary crash (not a timeout) never triggers containment; the sandbox is reused for the next entry")
    func promptCrashNeverTriggersContainment() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()

        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, behaviors: [.crashed]
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        let result = try await run(fixture, adapter: adapter)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(result.results.count == 2)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .killedByCrash)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .survived)

        // A crash is not a `TestRunResult.status == .timedOut` fact — ADR-0008
        // §3.2 scopes containment to forced timeout-kills only. No rebuild
        // of any kind should occur.
        #expect(adapter.buildCallCount == 1)
    }

    // MARK: - Item 6: primary timeout-kill, confirmation resolves normally

    @Test("""
    A primary timeout-kill whose confirmation resolves normally still rebuilds, but the verdict stays .flaky, never promoted, \
    and the hang budget does not increment
    """)
    func primaryTimeoutConfirmationResolvesNormallyStillRebuilds() async throws {
        let fixture = try ChunkFixture.make(entryCount: 2)
        let adapter = FakeSchemataAdapter()

        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .passed(includeHit: true)]
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )

        // Budget = 0: if a `.flaky` outcome ever incorrectly incremented the
        // hang budget, entry 1 would be swept into overflow fallback and
        // never actually run — the sharpest observable symptom available,
        // since a single-entry chunk's own overflow check is a no-op (its
        // one placement is always already "fully finalized" by the time
        // overflow would check it, per `hangBudgetOverflowClosure`'s own
        // logic), which is why this test needs a second entry to be
        // meaningful at all.
        let result = try await run(fixture, adapter: adapter, maxVerifiedTimeoutsPerChunk: 0)

        #expect(result.isolatedFallbacks.isEmpty, "a .flaky outcome must never count against the hang budget")
        #expect(result.results.count == 2)
        // The rebuild (containment) fires on the primary's own forced kill,
        // unconditionally, before the confirmation runs — independent of
        // what the confirmation later decides.
        #expect(adapter.buildCallCount == 2)
        // The confirmation resolving normally is schemata's own permanent
        // `.flaky` case (never batch-attributed) — this ADR must not weaken
        // that, and the mid-chunk rebuild introduced here must not either.
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .flaky)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .survived)
    }
}
