import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `SchemataMutationRunner`'s half of the multi-target aggregation
/// policy: a MutationID embedded into two
/// targets whose placements verified, but where one placement could not be
/// scored and none killed, is never reported from schemata evidence. It is
/// dropped from `results`/`multiTargetVerdicts` and handed to isolated
/// fallback as a whole. A kill in any placement still settles it in place.
@Suite("SchemataMutationRunner: multi-target aggregation with a non-scorable placement")
struct SchemataMutationRunnerMultiTargetAggregationTests {
    private static let source = "func flag() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"
    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))
    private static let targetA = "App"
    private static let targetB = "Widget"
    private static let tokenA = SchemataSelectorToken(namespace: 1, localIndex: 1)
    private static let tokenB = SchemataSelectorToken(namespace: 2, localIndex: 1)

    private func point() throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        return try #require(points.first, "expected a bool-literal candidate")
    }

    private func entry(mutationID: MutationID, target: String, chunkID: String, token: SchemataSelectorToken) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: chunkID, selectorToken: token,
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app"
        )
    }

    private func program(chunkID: String, entry: SchemataPlanEntry) -> SchemataProgram {
        SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: [entry]
        )
    }

    private func unit(_ target: String, _ point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: target, module: target,
            sourcePath: point.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs one MutationID embedded into two targets, each scripted with its
    /// own behaviors. `adjust` runs on the adapter before `run()`.
    private func runTwoTargets(
        a: [FakeSchemataAdapter.Behavior], b: [FakeSchemataAdapter.Behavior],
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = .permissive,
        adjust: (FakeSchemataAdapter) -> Void = { _ in }
    ) async throws -> (MutationID, SchemataMutationRunner.Outcome) {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let adapter = FakeSchemataAdapter()
        adapter.scripts[Self.tokenA] = .init(
            compilationUnitID: unit(Self.targetA, mutationPoint), sourceEmbeddingID: Self.sourceEmbeddingID, behaviors: a
        )
        adapter.scripts[Self.tokenB] = .init(
            compilationUnitID: unit(Self.targetB, mutationPoint), sourceEmbeddingID: Self.sourceEmbeddingID, behaviors: b
        )
        adjust(adapter)
        let programs = [
            program(chunkID: "chunk-A", entry: entry(mutationID: mutationID, target: Self.targetA, chunkID: "chunk-A", token: Self.tokenA)),
            program(chunkID: "chunk-B", entry: entry(mutationID: mutationID, target: Self.targetB, chunkID: "chunk-B", token: Self.tokenB))
        ]
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-mt-agg-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-mt-agg-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: policy
        )
        return (mutationID, try await runner.run())
    }

    private func expectWholeMutationIDFallback(_ mutationID: MutationID, _ outcome: SchemataMutationRunner.Outcome) {
        #expect(outcome.results.isEmpty, "no schemata result may be reported for a MutationID with a non-scorable placement")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(outcome.isolatedFallbacks == [.init(mutationID: mutationID, reason: .multiTargetUnscorablePlacement)])
    }

    private static let confirmsTimeouts = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
    )

    @Test("survived in A + flaky in B sends the whole MutationID to isolated fallback")
    func survivedPlusFlakyFallsBack() async throws {
        let (id, outcome) = try await runTwoTargets(
            a: [.passed(includeHit: true)], b: [.timedOut, .passed(includeHit: true)], policy: Self.confirmsTimeouts
        )
        expectWholeMutationIDFallback(id, outcome)
    }

    @Test("survived in A + an unconfirmed timeout in B sends the whole MutationID to isolated fallback")
    func survivedPlusUnverifiedTimeoutFallsBack() async throws {
        let (id, outcome) = try await runTwoTargets(a: [.passed(includeHit: true)], b: [.timedOut])
        expectWholeMutationIDFallback(id, outcome)
    }

    @Test("survived in A + a confirmed timeout in B is verifiedTimeout in place, with no fallback")
    func survivedPlusVerifiedTimeoutIsKilled() async throws {
        let (_, outcome) = try await runTwoTargets(
            a: [.passed(includeHit: true)], b: [.timedOut, .timedOut], policy: Self.confirmsTimeouts
        )
        #expect(outcome.isolatedFallbacks.isEmpty)
        #expect(outcome.results.map(\.outcome) == [.verifiedTimeout])
    }

    @Test("survived in A + infrastructureFailure in B sends the whole MutationID to isolated fallback")
    func survivedPlusInfrastructureFailureFallsBack() async throws {
        let (id, outcome) = try await runTwoTargets(a: [.passed(includeHit: true)], b: [.passed(includeHit: true)]) {
            $0.throwOnNextRun.insert(Self.tokenB)
        }
        expectWholeMutationIDFallback(id, outcome)
    }

    @Test("The report's fallback histogram names this reason under its own key")
    func fallbackReasonReachesTheHistogram() async throws {
        let (_, outcome) = try await runTwoTargets(a: [.passed(includeHit: true)], b: [.timedOut])
        #expect(HybridExecutionEngine.fallbackReasonCounts(outcome.isolatedFallbacks) == ["multiTargetUnscorablePlacement": 1])
    }

    @Test("killed in A + flaky in B is killed in place, with no fallback")
    func killedPlusFlakyIsKilled() async throws {
        let (id, outcome) = try await runTwoTargets(
            a: [.crashed], b: [.timedOut, .passed(includeHit: true)], policy: Self.confirmsTimeouts
        )
        #expect(outcome.isolatedFallbacks.isEmpty)
        let verdict = try #require(outcome.multiTargetVerdicts.first { $0.mutationRef.mutationID == id })
        #expect(verdict.aggregateOutcome == .killedByCrash)
        #expect(outcome.results.map(\.outcome) == [.killedByCrash])
    }

    @Test("killed in A + infrastructureFailure in B is killed in place, with no fallback")
    func killedPlusInfrastructureFailureIsKilled() async throws {
        let (_, outcome) = try await runTwoTargets(a: [.crashed], b: [.passed(includeHit: true)]) {
            $0.throwOnNextRun.insert(Self.tokenB)
        }
        #expect(outcome.isolatedFallbacks.isEmpty)
        #expect(outcome.results.map(\.outcome) == [.killedByCrash])
    }

    @Test("survived in both targets aggregates normally, with no fallback")
    func bothSurvivedAggregatesNormally() async throws {
        let (_, outcome) = try await runTwoTargets(a: [.passed(includeHit: true)], b: [.passed(includeHit: true)])
        #expect(outcome.isolatedFallbacks.isEmpty)
        #expect(outcome.results.map(\.outcome) == [.survived])
    }
}
