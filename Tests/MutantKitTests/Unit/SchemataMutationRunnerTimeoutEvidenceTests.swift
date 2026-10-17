import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Schemata mode must leave the same verifier-visible evidence isolated mode does:
/// a confirmed timeout carries its `TimeoutConfirmation` (`verify-run` requires
/// `timedOutAgain == true` for any `verifiedTimeout`), and with `evidence.archive`
/// on, the raw observations are archived so Tier B can re-derive the verdict offline.
@Suite("SchemataMutationRunner: timeout evidence and evidence archive")
struct SchemataMutationRunnerTimeoutEvidenceTests {
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

    /// Confirms timeouts (needed to exercise the timeout confirmation at all) but not
    /// crashes — `confirmCrashKills: false` keeps the crash-vs-hang test
    /// simple: a crash settles immediately, with no confirmation
    /// dispatch to reason about.
    private static let confirmsTimeoutsOnly = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
    )

    private func run(
        _ fixture: ChunkFixture, adapter: FakeSchemataAdapter,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = confirmsTimeoutsOnly,
        maxVerifiedTimeoutsPerChunk: Int = 3,
        evidenceArchive: EvidenceArchiveWriter? = nil
    ) async throws -> SchemataMutationRunner.Outcome {
        try await run(
            [fixture.program], pointsByID: fixture.pointsByID, relativePath: fixture.relativePath, source: fixture.source,
            adapter: adapter, policy: policy, maxVerifiedTimeoutsPerChunk: maxVerifiedTimeoutsPerChunk,
            evidenceArchive: evidenceArchive
        )
    }

    private func run(
        _ programs: [SchemataProgram], pointsByID: [MutationID: MutationPoint], relativePath: String, source: String,
        adapter: FakeSchemataAdapter, policy: MutationVerdictVerifier.VerdictVerificationPolicy = confirmsTimeoutsOnly,
        maxVerifiedTimeoutsPerChunk: Int = 3, evidenceArchive: EvidenceArchiveWriter? = nil
    ) async throws -> SchemataMutationRunner.Outcome {
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: pointsByID,
            originalSources: [relativePath: Data(source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-timeout-evidence-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-timeout-evidence-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: policy, maxVerifiedTimeoutsPerChunk: maxVerifiedTimeoutsPerChunk,
            evidenceArchive: evidenceArchive
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

    private func archive(for fixture: ChunkFixture) throws -> (EvidenceArchiveWriter, URL) {
        let root = Self.makeTempDir(prefix: "mutantkit-timeout-evidence-archive")
        let plan = makePlan(mutations: fixture.sortedPoints)
        let writer = EvidenceArchiveWriter(
            evidenceRoot: root.appendingPathComponent("evidence"), runID: "run-schemata", plan: plan,
            policy: Self.confirmsTimeoutsOnly
        )
        return (writer, root)
    }

    // MARK: - timeoutConfirmation on the result

    @Test("A confirmed schemata timeout carries timeoutConfirmation.timedOutAgain == true")
    func verifiedTimeoutCarriesTimeoutConfirmation() async throws {
        let fixture = try ChunkFixture.make(entryCount: 1)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )

        let result = try await run(fixture, adapter: adapter)
        let mutation = try outcome(for: fixture.sortedPoints[0].id, in: result)

        #expect(mutation.outcome == .verifiedTimeout)
        let confirmation = try #require(mutation.evidence?.timeoutConfirmation, "a verifiedTimeout must record its confirmation")
        #expect(confirmation.timedOutAgain == true)
    }

    @Test("A timeout whose confirmation finishes normally is flaky and records timedOutAgain == false")
    func flakyTimeoutRecordsUnreproducedConfirmation() async throws {
        let fixture = try ChunkFixture.make(entryCount: 1)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .passed(includeHit: true)]
        )

        let result = try await run(fixture, adapter: adapter)
        let mutation = try outcome(for: fixture.sortedPoints[0].id, in: result)

        #expect(mutation.outcome == .flaky)
        #expect(mutation.evidence?.timeoutConfirmation?.timedOutAgain == false)
    }

    // MARK: - evidence archive

    @Test("With an evidence archive, the primary and the confirmation observation are archived, with distinct RunIDs")
    func archivesPrimaryAndConfirmation() async throws {
        let fixture = try ChunkFixture.make(entryCount: 1)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        let (writer, root) = try archive(for: fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await run(fixture, adapter: adapter, evidenceArchive: writer)

        #expect(writer.recordedCount == 1)
        _ = try writer.seal()
        let loaded = EvidenceArchiveReader.load(directory: writer.directory)
        #expect(loaded.problems.isEmpty)
        let entry = try #require(loaded.entries[fixture.sortedPoints[0].id.rawValue])
        let observations = entry.observations
        guard case let .schemata(primary)? = observations.test?.applicationEvidence else {
            Issue.record("the archived primary observation must be a schemata observation")
            return
        }
        let confirmation = try #require(observations.confirmations.first, "the confirmation observation must be archived")
        let confirming = try #require(confirmation.schemataObservation)
        #expect(confirming.expectation.runID != primary.expectation.runID, "a confirmation is its own independent run")
    }

    @Test("The archived observations re-derive the same verifiedTimeout offline (Tier B)")
    func archivedObservationsReproduceTheVerdict() async throws {
        let fixture = try ChunkFixture.make(entryCount: 1)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .timedOut]
        )
        let (writer, root) = try archive(for: fixture)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await run(fixture, adapter: adapter, evidenceArchive: writer)
        let live = try outcome(for: fixture.sortedPoints[0].id, in: result)
        _ = try writer.seal()
        let entry = try #require(EvidenceArchiveReader.load(directory: writer.directory).entries[live.id.rawValue])

        let replayed = MutationVerdictVerifier.verify(entry.observations, policy: Self.confirmsTimeoutsOnly)
        #expect(replayed.outcome == .verifiedTimeout)
        #expect(replayed.outcome == live.outcome)
    }

    @Test("Without an evidence archive nothing is written and results are unchanged")
    func noArchiveNoWrites() async throws {
        let fixture = try ChunkFixture.make(entryCount: 1)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
        let result = try await run(fixture, adapter: adapter)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .survived)
    }
}
