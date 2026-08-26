import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `SchemataMutationRunner`'s Group 2 routing (ADR-0006): a mutation
/// whose schemata attempt has a passing test but no runtime activation
/// proof (`MutationVerdictVerifier.schemataIsolatedFallbackReason`) is
/// dropped from `Outcome.results`/`.multiTargetVerdicts` entirely and
/// surfaced in `Outcome.isolatedFallbacks` instead — never scored as
/// `infrastructureFailure` from schemata evidence alone. `SchemataRunOrchestration`
/// (untested here) is what actually re-runs these through isolated mode;
/// this suite only pins the runner's own half: what it keeps, what it drops.
///
/// A fake `SchemataBuildable`/`SchemataTestable` writes real v3 binary
/// transcript records (the same wire format `SchemataEvidenceCollectorTests`
/// pins) so `MutationVerdictVerifier.verifySchemataChain` runs unmodified
/// against genuine bytes, never a shortcut that assumes what the runner
/// will decide.
@Suite("SchemataMutationRunner: Group 2 dynamic isolated fallback")
struct SchemataMutationRunnerDynamicFallbackTests {
    // MARK: - Fixture: one real MutationPoint (BoolLiteralInversion, simplest discoverable candidate)

    private static let source = "func flag() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"

    private func point() throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        return try #require(points.first, "expected a bool-literal candidate")
    }

    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1

    private func entry(
        mutationID: MutationID, target: String, chunkID: String, localIndex: UInt32, namespace: UInt64
    ) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: chunkID, selectorToken: SchemataSelectorToken(namespace: namespace, localIndex: localIndex),
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app"
        )
    }

    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func program(chunkID: String, entry: SchemataPlanEntry) -> SchemataProgram {
        SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: [entry]
        )
    }

    private func compilationUnitID(target: String, point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: target, module: target,
            sourcePath: point.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )
    }

    // MARK: - Running

    private func run(
        _ mutationID: MutationID, programs: [SchemataProgram], adapter: FakeSchemataAdapter,
        preEstablishedBaseline: SharedBaselineEstablisher.Outcome? = nil
    ) async throws -> SchemataMutationRunner.Outcome {
        let mutationPoint = try point()
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-fallback-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-fallback-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: .permissive, preEstablishedBaseline: preEstablishedBaseline
        )
        return try await runner.run()
    }

    /// A trivially-passing baseline record — every field beyond `passed`
    /// is irrelevant to the tests using this, which only care about what
    /// happens *after* `run()`'s `guard baseline.passed` succeeds.
    private static func passingBaselineRecord() -> BaselineRecord {
        BaselineRecord(
            passed: true, testSummary: nil, durationSeconds: 1, buildProductHash: "sha256:stub",
            buildCommand: nil, testCommand: nil
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tests

    @Test("A single-target mutation with no runtime HIT falls back to isolated, never scored as schemata infrastructureFailure")
    func singleTargetNoHitFallsBackDynamically() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let target = "App"
        let unit = compilationUnitID(target: target, point: mutationPoint)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: false
        )

        let entry = entry(mutationID: mutationID, target: target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let outcome = try await run(mutationID, programs: [program(chunkID: "chunk-A", entry: entry)], adapter: adapter)

        #expect(outcome.results.isEmpty, "a no-HIT mutation must never appear in results")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == mutationID)
        #expect(fallback.reason == .activation(.noHit))
    }

    @Test("A single-target mutation with a valid chain scores normally, no fallback")
    func singleTargetValidChainNeedsNoFallback() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let target = "App"
        let unit = compilationUnitID(target: target, point: mutationPoint)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )

        let entry = entry(mutationID: mutationID, target: target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let outcome = try await run(mutationID, programs: [program(chunkID: "chunk-A", entry: entry)], adapter: adapter)

        #expect(outcome.isolatedFallbacks.isEmpty)
        #expect(outcome.results.count == 1)
        #expect(outcome.multiTargetVerdicts.count == 1)
    }

    /// The Group 2 multi-target regression (Step 16): the same MutationID
    /// embedded into two targets, one with a valid chain, the other
    /// passing but with no HIT. All-or-nothing — the *whole* MutationID
    /// falls back, including the target that individually verified fine,
    /// never a partial schemata/isolated split for the same MutationID.
    @Test("Multi-target: one target's no-HIT drags the whole MutationID to fallback, even though the other target verified fine")
    func multiTargetAllOrNothingFallback() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let targetA = "App"
        let targetB = "Widget"
        let unitA = compilationUnitID(target: targetA, point: mutationPoint)
        let unitB = compilationUnitID(target: targetB, point: mutationPoint)

        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unitA, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: unitB, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: false
        )

        let entryA = entry(mutationID: mutationID, target: targetA, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let entryB = entry(mutationID: mutationID, target: targetB, chunkID: "chunk-B", localIndex: 1, namespace: 2)
        let outcome = try await run(
            mutationID, programs: [program(chunkID: "chunk-A", entry: entryA), program(chunkID: "chunk-B", entry: entryB)], adapter: adapter
        )

        #expect(outcome.results.isEmpty, "no partial schemata result may survive for a MutationID with any fallback placement")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(outcome.isolatedFallbacks.count == 1)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == mutationID)
        #expect(fallback.reason == .activation(.noHit))
    }

    /// Gate 3 finding (`Research/benchmarks/gate3-ios-schemata-2026-08-23`):
    /// a mutation on a line the shared baseline's own coverage map already
    /// proves unreached previously still paid for a full schemata token
    /// attempt before discovering the identical fact via `noStartup` —
    /// wasted cost isolated mode's own `.noCoverage` pre-build check never
    /// pays. `runPrimary`'s `coverage.isKnownUncovered(point)` fast path
    /// exists to skip that attempt entirely; this pins it never even
    /// dispatches `runSchemataToken` for the skipped entry (chunk `build`
    /// still happens — that cost is unavoidably shared across the whole
    /// chunk regardless of any one entry's own coverage).
    @Test("A mutation the shared baseline already proves uncovered never gets a token attempt, and falls back with .knownUncovered")
    func knownUncoveredSkipsTokenAttemptEntirely() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let target = "App"
        // No script registered for this token at all — if `runPrimary`
        // ever actually dispatched `runSchemataToken`, `FakeSchemataAdapter`
        // would `fatalError` on the missing script, failing this test loudly
        // rather than silently passing for the wrong reason.
        let adapter = FakeSchemataAdapter()
        let coverage = CoverageMap(executedLines: [Self.relativePath: [mutationPoint.line + 1000]], source: "test")

        let entry = entry(mutationID: mutationID, target: target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let outcome = try await run(
            mutationID, programs: [program(chunkID: "chunk-A", entry: entry)], adapter: adapter,
            preEstablishedBaseline: .established(EstablishedBaseline(
                record: Self.passingBaselineRecord(), testDurationSeconds: 1, perTestCoverage: nil, coverage: coverage
            ))
        )

        #expect(outcome.results.isEmpty)
        #expect(outcome.multiTargetVerdicts.isEmpty)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == mutationID)
        #expect(fallback.reason == .knownUncovered)
        #expect(adapter.selectedTestsSeen.isEmpty, "runSchemataToken must never be dispatched for a known-uncovered entry")
        #expect(adapter.buildCallCount == 1, "the chunk build itself is still shared/unavoidable regardless of this one entry's coverage")
    }
}
