import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// A chunk whose shared build genuinely succeeds but whose own build
/// receipt cannot be resolved (`SchemataBuildable.resolveSchemataBuildReceipt`
/// throwing, per its own fail-closed protocol contract) used to be silently
/// absorbed by `prepareChunkState`'s bare `try?`, scoring every entry against
/// an unproven `receipt: nil`. That is now a whole-chunk
/// `.isolatedFallback(reason: .buildReceiptUnavailable)`, joining the same
/// all-or-nothing dynamic-fallback discipline
/// `SchemataMutationRunnerSharedChunkBuildFailureTests` already pins for a
/// typed `BuildFailure` — this file is that suite's direct counterpart for
/// the receipt-resolution failure trigger, reusing its fixture shape.
@Suite("SchemataMutationRunner: build-receipt-unavailable fallback attribution")
struct SchemataMutationRunnerReceiptUnavailableFallbackTests {
    // MARK: - Fixture (mirrors SchemataMutationRunnerSharedChunkBuildFailureTests' own 3-entry chunk)

    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let target = "App"
    private static let relativePath = "Widget.swift"
    private static let source = "func a() -> Bool { true }\nfunc b() -> Bool { true }\nfunc c() -> Bool { true }\n"
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func threePoints() throws -> [MutationPoint] {
        let discovered = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        let sorted = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
        precondition(sorted.count == 3)
        return sorted
    }

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

    private func program(chunkID: String, entries: [SchemataPlanEntry]) -> SchemataProgram {
        SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: entries
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        points: [MutationID: MutationPoint], programs: [SchemataProgram], adapter: FakeSchemataAdapter
    ) async throws -> SchemataMutationRunner.Outcome {
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: points,
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-receipt-unavailable-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-receipt-unavailable-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args", policy: .permissive
        )
        return try await runner.run()
    }

    // MARK: - Initial receipt-resolution failure

    @Test("""
    A chunk whose build succeeds but whose receipt resolution throws routes every one of its entries to .buildReceiptUnavailable \
    fallback, never scoring a result against an unproven receipt, and reports exactly one aggregate infrastructure event
    """)
    func receiptResolutionFailureFallsBackEveryEntry() async throws {
        let points = try threePoints()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let entries = points.enumerated().map { index, point in
            entry(mutationID: point.id, target: Self.target, chunkID: "chunk-A", localIndex: UInt32(index + 1), namespace: 1)
        }
        let adapter = FakeSchemataAdapter()
        adapter.buildFailureScript[1] = .throwOnReceiptResolution

        let outcome = try await run(points: pointsByID, programs: [program(chunkID: "chunk-A", entries: entries)], adapter: adapter)

        #expect(outcome.results.isEmpty, "a receipt-unavailable fallback must never leave a schemata-scored result behind")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(Set(outcome.isolatedFallbacks.map(\.mutationID)) == Set(points.map(\.id)))
        for fallback in outcome.isolatedFallbacks {
            #expect(fallback.reason == .buildReceiptUnavailable)
        }

        // Observability: one aggregate event, not three individual ones.
        let event = try #require(outcome.infrastructureFallbackEvents.first)
        #expect(outcome.infrastructureFallbackEvents.count == 1)
        #expect(event.chunkID == "chunk-A")
        #expect(event.reason == .buildReceiptUnavailable)
        #expect(event.affectedMutationCount == 3)
        #expect(!event.diagnosis.isEmpty)
        // Never a compile-failure-shaped event for a build that genuinely succeeded.
        #expect(outcome.sharedChunkBuildFailureEvents.isEmpty)
    }

    // MARK: - Multi-target all-or-nothing discard

    /// Mirrors `SchemataMutationRunnerSharedChunkBuildFailureTests
    /// .multiTargetSharedBuildFailureDiscardsAlreadyVerifiedPlacement` for
    /// this trigger: the same `MutationID` embedded in two targets, one
    /// already schemata-verified, the other's chunk receipt unresolvable.
    @Test("""
    Multi-target: one target's receipt-unavailable failure discards the whole MutationID, including the other target's \
    already-verified result
    """)
    func multiTargetReceiptUnavailableDiscardsAlreadyVerifiedPlacement() async throws {
        let points = try threePoints()
        let point = points[0]
        let targetA = "App"
        let targetB = "Widget"
        let unitA = CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: targetA, module: targetA,
            sourcePath: point.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )

        let adapter = FakeSchemataAdapter()
        // Target A's own token scores a genuine, valid verdict.
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unitA, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        // Target B's chunk is the *second* program `run()` processes, so its
        // build/receipt-resolution is FakeSchemataAdapter's call 2 — its
        // receipt resolution fails.
        adapter.buildFailureScript[2] = .throwOnReceiptResolution

        let entryA = entry(mutationID: point.id, target: targetA, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let entryB = entry(mutationID: point.id, target: targetB, chunkID: "chunk-B", localIndex: 1, namespace: 2)
        let outcome = try await run(
            points: [point.id: point],
            programs: [program(chunkID: "chunk-A", entries: [entryA]), program(chunkID: "chunk-B", entries: [entryB])],
            adapter: adapter
        )

        #expect(
            outcome.results.isEmpty,
            """
            target A's individually-valid schemata result must be discarded once target B's receipt-unavailable failure forces \
            this MutationID to fall back as a whole
            """
        )
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(outcome.isolatedFallbacks.count == 1)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == point.id)
        #expect(fallback.reason == .buildReceiptUnavailable)
    }

    // MARK: - Observability: one event per failed chunk, never merged or duplicated across chunks

    @Test("Two independently receipt-unavailable chunks each report their own event — never merged into one, never duplicated per entry")
    func multipleIndependentReceiptFailuresEachReportTheirOwnEvent() async throws {
        let points = try threePoints()
        let pointA = points[0]
        let pointB = points[1]
        let entryA = entry(mutationID: pointA.id, target: Self.target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let entryB = entry(mutationID: pointB.id, target: Self.target, chunkID: "chunk-B", localIndex: 1, namespace: 2)

        let adapter = FakeSchemataAdapter()
        // `run()` processes programs in order, so chunk-A's build/receipt is
        // call 1 and chunk-B's is call 2 — fail both receipt resolutions.
        adapter.buildFailureScript[1] = .throwOnReceiptResolution
        adapter.buildFailureScript[2] = .throwOnReceiptResolution

        let outcome = try await run(
            points: [pointA.id: pointA, pointB.id: pointB],
            programs: [program(chunkID: "chunk-A", entries: [entryA]), program(chunkID: "chunk-B", entries: [entryB])],
            adapter: adapter
        )

        #expect(outcome.infrastructureFallbackEvents.count == 2, "one event per failed chunk, never merged into one")
        let byChunk = Dictionary(uniqueKeysWithValues: outcome.infrastructureFallbackEvents.map { ($0.chunkID, $0) })
        #expect(byChunk["chunk-A"]?.affectedMutationCount == 1)
        #expect(byChunk["chunk-B"]?.affectedMutationCount == 1)
        #expect(Set(outcome.isolatedFallbacks.map(\.mutationID)) == Set([pointA.id, pointB.id]))
    }

    @Test("""
    A chunk whose build genuinely fails (never even reaching receipt resolution) reports a build-failure event, never a \
    receipt-unavailable one
    """)
    func genuineBuildFailureIsNeverMisattributedAsReceiptUnavailable() async throws {
        let points = try threePoints()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let entries = points.enumerated().map { index, point in
            entry(mutationID: point.id, target: Self.target, chunkID: "chunk-A", localIndex: UInt32(index + 1), namespace: 1)
        }
        let adapter = FakeSchemataAdapter()
        adapter.buildFailureScript[1] = .throwBuildFailure(kind: .compilationError, diagnosis: "synthetic shared-chunk compile error")

        let outcome = try await run(points: pointsByID, programs: [program(chunkID: "chunk-A", entries: entries)], adapter: adapter)

        #expect(outcome.infrastructureFallbackEvents.isEmpty)
        #expect(outcome.sharedChunkBuildFailureEvents.count == 1)
        for fallback in outcome.isolatedFallbacks {
            #expect(fallback.reason == .sharedChunkBuildFailure)
        }
    }
}
