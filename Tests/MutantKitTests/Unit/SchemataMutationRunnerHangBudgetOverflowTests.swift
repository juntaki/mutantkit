import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The timeout-isolation acceptance gate for hang-budget overflow: once a chunk's hang budget is exceeded, every
/// `MutationID` in that chunk not yet *fully* finalized across all of its
/// target placements — even one embedded into a *different* chunk that
/// hasn't run yet — is dropped from schemata scoring entirely and routed to
/// isolated-mode fallback, matching the existing all-or-nothing-per-
/// `MutationID` invariant `run()` already enforces for Group 2's no-HIT
/// fallback (`SchemataMutationRunnerDynamicFallbackTests`). The interesting
/// case this ADR's own §4(b) calls out explicitly is cross-program: a
/// `MutationID` with placements in two different `SchemataProgram`s/chunks,
/// where one placement already individually verified fine before the
/// *other* chunk's own, unrelated hang overflowed its budget.
@Suite("SchemataMutationRunner: schemata hang-budget overflow")
struct SchemataMutationRunnerHangBudgetOverflowTests {
    // MARK: - Fixture

    private static let source = "func flagX() -> Bool { true }\nfunc flagY() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"
    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func points() throws -> (x: MutationPoint, y: MutationPoint) {
        let discovered = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        let sorted = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
        precondition(sorted.count == 2, "expected 2 bool-literal candidates (flagX, flagY), found \(sorted.count)")
        return (x: sorted[0], y: sorted[1])
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

    private func run(
        _ programs: [SchemataProgram], points: [MutationID: MutationPoint], adapter: FakeSchemataAdapter,
        maxVerifiedTimeoutsPerChunk: Int
    ) async throws -> SchemataMutationRunner.Outcome {
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: points,
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-overflow-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-overflow-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, maxVerifiedTimeoutsPerChunk: maxVerifiedTimeoutsPerChunk
        )
        return try await runner.run()
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Item 4

    @Test("""
    A chunk's hang-budget overflow drops a cross-program MutationID entirely — even the placement that already \
    verified fine in this same chunk, and even the placement in a different chunk that has not run yet — while the \
    mutation that actually caused the overflow keeps its own real verdict
    """)
    func overflowDropsCrossProgramMutationIDEntirely() async throws {
        let (x, y) = try points()
        let xTargetA = "App"
        let xTargetB = "Widget"

        // X: two placements, two different chunks — chunk-B's (Widget) runs
        // first and individually verifies fine; chunk-A's (App) has not run
        // at all when chunk-B's own hang-budget overflow fires.
        let entryXA = entry(mutationID: x.id, target: xTargetA, chunkID: "chunk-A", namespace: 1)
        let entryXB = entry(mutationID: x.id, target: xTargetB, chunkID: "chunk-B", namespace: 2)
        // Y: single placement, in chunk-B, after X-B — the one that hangs
        // and triggers chunk-B's own overflow.
        let entryY = entry(mutationID: y.id, target: xTargetB, chunkID: "chunk-B", namespace: 3)

        let programA = program(chunkID: "chunk-A", entries: [entryXA])
        let programB = program(chunkID: "chunk-B", entries: [entryXB, entryY])

        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: xTargetA, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: xTargetB, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 3, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: xTargetB, point: y), sourceEmbeddingID: Self.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )

        // programs order: chunk-B (containing the hang) runs BEFORE chunk-A
        // — chunk-A's own placement for X has not happened when chunk-B's
        // overflow closes X out. Budget = 0: Y's single confirmed hang alone
        // exceeds it.
        let result = try await run(
            [programB, programA], points: [x.id: x, y.id: y], adapter: adapter, maxVerifiedTimeoutsPerChunk: 0
        )

        // Y caused the overflow but is itself fully finalized — its own
        // real .verifiedTimeout stands, never swept.
        #expect(result.results.count == 1)
        #expect(result.results.first?.id == y.id)
        #expect(result.results.first?.outcome == .verifiedTimeout)
        #expect(result.multiTargetVerdicts.count == 1)
        #expect(result.multiTargetVerdicts.first?.mutationRef.mutationID == y.id)

        // X is dropped entirely — not fully finalized across both target
        // placements at the moment chunk-B's overflow fired — exactly one
        // fallback entry, reason .hangBudgetExceeded, and X appears nowhere
        // in `results`/`multiTargetVerdicts` (never double-ledgered: X's
        // final record comes from exactly one mode — isolated, not schemata
        // — even though its Widget placement individually verified fine).
        #expect(result.isolatedFallbacks.count == 1)
        let fallback = try #require(result.isolatedFallbacks.first)
        #expect(fallback.mutationID == x.id)
        #expect(fallback.reason == .hangBudgetExceeded)
        #expect(!result.results.contains { $0.id == x.id })
    }

    @Test("""
    A chunk's hang-budget overflow never discards a cross-program MutationID whose placement in that chunk already \
    killed it: the kill settles the MutationID and no fallback is recorded for it
    """)
    func overflowKeepsCrossProgramMutationIDThatAlreadyKilled() async throws {
        let (x, y) = try points()
        let xTargetA = "App"
        let xTargetB = "Widget"

        let entryXA = entry(mutationID: x.id, target: xTargetA, chunkID: "chunk-A", namespace: 1)
        let entryXB = entry(mutationID: x.id, target: xTargetB, chunkID: "chunk-B", namespace: 2)
        let entryY = entry(mutationID: y.id, target: xTargetB, chunkID: "chunk-B", namespace: 3)

        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: xTargetA, point: x), sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        // X's Widget placement crashes: a kill, settled before Y's hang.
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: xTargetB, point: x), sourceEmbeddingID: Self.sourceEmbeddingID,
            behaviors: [.crashed]
        )
        adapter.scripts[SchemataSelectorToken(namespace: 3, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(target: xTargetB, point: y), sourceEmbeddingID: Self.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )

        let result = try await run(
            [program(chunkID: "chunk-B", entries: [entryXB, entryY]), program(chunkID: "chunk-A", entries: [entryXA])],
            points: [x.id: x, y.id: y], adapter: adapter, maxVerifiedTimeoutsPerChunk: 0
        )

        #expect(result.isolatedFallbacks.isEmpty, "a proven kill must not be sent to isolated mode")
        #expect(result.results.first { $0.id == x.id }?.outcome == .killedByCrash)
        #expect(result.results.first { $0.id == y.id }?.outcome == .verifiedTimeout)
        let xVerdict = try #require(result.multiTargetVerdicts.first { $0.mutationRef.mutationID == x.id })
        #expect(xVerdict.aggregateOutcome == .killedByCrash)
    }

    // MARK: - The entries after the overflowing one

    /// The overflow fires on the chunk's FIRST entry, so the remaining-entries
    /// half of `hangBudgetOverflowClosure` and the early return after it are
    /// both exercised: every later entry falls back as `.hangBudgetExceeded`,
    /// none is dispatched or rebuilt for, and with batching on (size 3) the
    /// later entries' prefetched batch outcomes are discarded, never scored.
    @Test(
        "An overflow on a chunk's first entry falls every later entry back, unrun and unscored",
        arguments: [1, 3]
    )
    func overflowFallsEveryLaterEntryBack(schemataTokenBatchSize: Int) async throws {
        let source = "func flagA() -> Bool { true }\nfunc flagB() -> Bool { true }\nfunc flagC() -> Bool { true }\n"
        let embeddingID = SHA256Digest.of(Data(source.utf8))
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        ).sorted { $0.utf8Range.start < $1.utf8Range.start }
        try #require(points.count == 3)
        let tokens = (1 ... 3).map { SchemataSelectorToken(namespace: UInt64($0), localIndex: 1) }
        let entries = zip(points, tokens).map { point, token in
            SchemataPlanEntry(
                mutationID: point.id,
                placement: .embedded(placements: [SchemataEmbeddedPlacement(
                    chunkID: "chunk-A", selectorToken: token, sourceEmbeddingID: embeddingID.rawValue, lowererID: Self.lowererID,
                    lowererVersion: Self.lowererVersion, projectIdentity: Self.projectIdentity, target: "App", module: "App",
                    product: "App.app", expectedImages: []
                )]),
                conflictGroup: nil, projectIdentity: Self.projectIdentity, target: "App", module: "App", product: "App.app"
            )
        }
        let adapter = FakeSchemataAdapter()
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        for (index, point) in points.enumerated() {
            adapter.scripts[tokens[index]] = .init(
                compilationUnitID: compilationUnitID(target: "App", point: point), sourceEmbeddingID: embeddingID,
                behaviors: index == 0 ? [.timedOut, .timedOut] : [.passed(includeHit: true)]
            )
            coveringTests[point.file, default: [:]][point.line] = [TestIdentifier(target: "AppTests", qualifiedName: "T/test\(index)")]
        }
        adapter.perTestCoverageToReturn = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let result = try await SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1",
            programs: [SchemataProgram(
                chunkID: "chunk-A", sourceEmbeddingID: embeddingID.rawValue,
                loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: source)], entries: entries
            )],
            points: Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) }),
            originalSources: [Self.relativePath: Data(source.utf8)], build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-overflow-first-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-overflow-first-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly, maxVerifiedTimeoutsPerChunk: 0, selectCoveringTests: true,
            schemataTokenBatchSize: schemataTokenBatchSize
        ).run()

        #expect(result.results.map(\.id) == [points[0].id], "only the overflowing entry keeps a schemata verdict")
        #expect(result.results.first?.outcome == .verifiedTimeout)
        #expect(Set(result.isolatedFallbacks.map(\.mutationID)) == [points[1].id, points[2].id])
        #expect(result.isolatedFallbacks.allSatisfy { $0.reason == .hangBudgetExceeded })
        // The initial build and the rebuild before the confirmation (batched:
        // plus the rebuild after the killed batch), and none after the overflow.
        #expect(adapter.buildCallCount == (schemataTokenBatchSize == 1 ? 2 : 3))
        if schemataTokenBatchSize == 1 {
            #expect(adapter.runIDsSeenByToken[tokens[1]] == nil && adapter.runIDsSeenByToken[tokens[2]] == nil)
        }
    }
}
