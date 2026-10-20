import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Shared fixture and runner helpers for the schemata token-batching suites.
/// An N-entry chunk, one bool-literal mutant per entry, each with its own covering test.
struct BatchingChunkFixture {
    let source: String
    let relativePath: String
    let sortedPoints: [MutationPoint]
    let program: SchemataProgram
    let pointsByID: [MutationID: MutationPoint]
    let testsByPointIndex: [TestIdentifier]

    static let projectIdentity = "App.xcodeproj"
    static let lowererID = "bool-literal"
    static let lowererVersion = 1
    static let target = "App"

    static func make(entryCount: Int, chunkID: String = "chunk-A") throws -> BatchingChunkFixture {
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
        var testsByPointIndex: [TestIdentifier] = []
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
            testsByPointIndex.append(TestIdentifier(target: "AppTests", qualifiedName: "WidgetTests/testFlag\(index + 1)"))
        }
        let program = SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: relativePath, contents: source)],
            entries: entries
        )
        return BatchingChunkFixture(
            source: source, relativePath: relativePath, sortedPoints: sortedPoints, program: program,
            pointsByID: pointsByID, testsByPointIndex: testsByPointIndex
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

    /// A narrowed, non-empty per-entry covering-test attribution — the
    /// only shape `prepareBatchedPrimaries` ever considers eligible for
    /// batching (`selectedTests == nil` is never batched, unconditionally).
    var perTestCoverage: PerTestCoverageMap {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        for (index, point) in sortedPoints.enumerated() {
            coveringTests[point.file, default: [:]][point.line] = [testsByPointIndex[index]]
        }
        return PerTestCoverageMap(coveringTests: coveringTests, source: "test")
    }
}

/// Runner/outcome helpers the batching suites share.
protocol SchemataBatchingTestHarness {}

extension SchemataBatchingTestHarness {
    static var confirmsTimeoutsOnly: MutationVerdictVerifier.VerdictVerificationPolicy {
        MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
        )
    }

    func run(
        _ fixture: BatchingChunkFixture, adapter: FakeSchemataAdapter, schemataTokenBatchSize: Int,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = Self.confirmsTimeoutsOnly
    ) async throws -> SchemataMutationRunner.Outcome {
        adapter.perTestCoverageToReturn = fixture.perTestCoverage
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [fixture.program], points: fixture.pointsByID,
            originalSources: [fixture.relativePath: Data(fixture.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-batching-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: policy, selectCoveringTests: true, schemataTokenBatchSize: schemataTokenBatchSize
        )
        return try await runner.run()
    }

    static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func outcome(for mutationID: MutationID, in outcome: SchemataMutationRunner.Outcome) throws -> MutationResult {
        try #require(outcome.results.first { $0.id == mutationID })
    }
}
