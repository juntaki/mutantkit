import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0008 §5 item 8 / §4(d), amended by Addendum 4: a mid-chunk recovery
/// rebuild (triggered by a forced timeout-kill) can itself fail in the same
/// four shapes the *initial* per-chunk build already handles — sandbox-
/// creation error, untyped build error, a typed `BuildFailure`, and a
/// swallowed receipt-resolution failure — and each must route through the
/// *same* handler the initial build already uses for every not-yet-finalized
/// entry the rebuild was protecting, never a manufactured shortcut. Three of
/// the four still must never automatically fall back to isolated mode
/// (sandbox-creation error, untyped build error, receipt-resolution
/// failure); the fourth — a typed `BuildFailure`, chunk-level evidence only —
/// now does fall back to isolated mode as of Addendum 4, joining hang-budget
/// overflow as a second, independent dynamic-fallback trigger, never a
/// manufactured `.unviable`.
@Suite("SchemataMutationRunner: ADR-0008 recovery-rebuild failure parity")
struct SchemataMutationRunnerRecoveryRebuildFailureTests {
    // MARK: - Fixture: a 2-entry chunk, entry 0 always primary-times-out to trigger Trigger 1's mandatory rebuild

    private struct ChunkFixture {
        let source: String
        let relativePath: String
        let sortedPoints: [MutationPoint]
        let program: SchemataProgram
        let pointsByID: [MutationID: MutationPoint]
        let projectRoot: URL
        let scratchRoot: URL

        static let projectIdentity = "App.xcodeproj"
        static let lowererID = "bool-literal"
        static let lowererVersion = 1
        static let target = "App"

        static func make() throws -> ChunkFixture {
            let relativePath = "Widget.swift"
            let source = "func flag1() -> Bool { true }\nfunc flag2() -> Bool { true }\n"
            let discovered = try CoreOperatorExpansionTestSupport.discover(
                source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: relativePath
            )
            let sortedPoints = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
            precondition(sortedPoints.count == 2)

            let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))
            var entries: [SchemataPlanEntry] = []
            var pointsByID: [MutationID: MutationPoint] = [:]
            for (index, point) in sortedPoints.enumerated() {
                let token = SchemataSelectorToken(namespace: UInt64(index + 1), localIndex: 1)
                entries.append(SchemataPlanEntry(
                    mutationID: point.id,
                    placement: .embedded(placements: [
                        SchemataEmbeddedPlacement(
                            chunkID: "chunk-A", selectorToken: token,
                            sourceEmbeddingID: sourceEmbeddingID.rawValue, lowererID: lowererID, lowererVersion: lowererVersion,
                            projectIdentity: projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                        )
                    ]),
                    conflictGroup: nil, projectIdentity: projectIdentity, target: target, module: target, product: "\(target).app"
                ))
                pointsByID[point.id] = point
            }
            let program = SchemataProgram(
                chunkID: "chunk-A", sourceEmbeddingID: sourceEmbeddingID.rawValue,
                loweredSources: [SchemataSourceFile(relativePath: relativePath, contents: source)],
                entries: entries
            )
            return ChunkFixture(
                source: source, relativePath: relativePath, sortedPoints: sortedPoints, program: program,
                pointsByID: pointsByID, projectRoot: makeTempDir(prefix: "mutantkit-recovery-project"),
                scratchRoot: makeTempDir(prefix: "mutantkit-recovery-scratch")
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

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let confirmsTimeoutsOnly = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
    )

    private func run(_ fixture: ChunkFixture, adapter: FakeSchemataAdapter) async throws -> SchemataMutationRunner.Outcome {
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [fixture.program], points: fixture.pointsByID,
            originalSources: [fixture.relativePath: Data(fixture.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(projectRoot: fixture.projectRoot, scratchRoot: fixture.scratchRoot),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: Self.confirmsTimeoutsOnly
        )
        return try await runner.run()
    }

    private func outcome(for mutationID: MutationID, in outcome: SchemataMutationRunner.Outcome) throws -> MutationResult {
        try #require(outcome.results.first { $0.id == mutationID })
    }

    /// Entry 0 always primary-times-out and needs confirmation, mandatorily
    /// triggering Trigger 1's rebuild before that confirmation runs —
    /// protecting `embeddedEntries[0...]`, i.e. *both* entries. Entry 1
    /// never itself needs to run for the build-failure sub-cases (the
    /// rebuild fails before any further process spawns), but is scripted
    /// anyway so the receipt-resolution sub-case — where the rebuild
    /// *succeeds* and entries proceed — has something real to execute.
    private func scriptEntry0TimesOut(_ fixture: ChunkFixture, adapter: FakeSchemataAdapter) {
        adapter.scripts[fixture.token(at: 0)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 0), sourceEmbeddingID: fixture.sourceEmbeddingID,
            behaviors: [.timedOut, .passed(includeHit: true)]
        )
        adapter.scripts[fixture.token(at: 1)] = .init(
            compilationUnitID: fixture.compilationUnitID(at: 1), sourceEmbeddingID: fixture.sourceEmbeddingID, includeHit: true
        )
    }

    // MARK: - Sub-case 1: sandbox recreation itself throws

    @Test("A recovery rebuild whose sandbox recreation itself fails routes every protected entry to infrastructureFailure")
    func sandboxRecreationFailureRoutesToInfrastructureFailure() async throws {
        let fixture = try ChunkFixture.make()
        let adapter = FakeSchemataAdapter()
        scriptEntry0TimesOut(fixture, adapter: adapter)

        // Deletes the real WorkspaceManager's projectRoot the moment entry
        // 0's primary run executes — by the time Trigger 1's rebuild calls
        // `createSandbox` again, `populate` can no longer read it, so
        // `createSandbox` itself throws (WorkspaceManager.swift:146, an
        // uncaught `populate` error propagating out of `createSandbox`).
        adapter.beforeNextRun[fixture.token(at: 0)] = { [projectRoot = fixture.projectRoot] in
            try? FileManager.default.removeItem(at: projectRoot)
        }

        let result = try await run(fixture, adapter: adapter)

        #expect(
            result.isolatedFallbacks.isEmpty, "a rebuild-failure of any of these four shapes must never auto-route to isolated fallback"
        )
        #expect(result.results.count == 2)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .infrastructureFailure)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .infrastructureFailure)
        #expect(result.sharedChunkBuildFailureEvents.isEmpty, "only a typed BuildFailure reports an observability event")
    }

    // MARK: - Sub-case 2: untyped build error during the rebuild

    @Test("A recovery rebuild whose build throws an untyped error routes every protected entry to infrastructureFailure")
    func untypedBuildErrorDuringRebuildRoutesToInfrastructureFailure() async throws {
        let fixture = try ChunkFixture.make()
        let adapter = FakeSchemataAdapter()
        scriptEntry0TimesOut(fixture, adapter: adapter)
        // Build call 1 = the initial chunk build (succeeds); call 2 = the
        // mid-chunk recovery rebuild Trigger 1 causes.
        adapter.buildFailureScript[2] = .throwUntypedError

        let result = try await run(fixture, adapter: adapter)

        #expect(result.isolatedFallbacks.isEmpty)
        #expect(result.results.count == 2)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .infrastructureFailure)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .infrastructureFailure)
        #expect(result.sharedChunkBuildFailureEvents.isEmpty, "only a typed BuildFailure reports an observability event")
    }

    // MARK: - Sub-case 3: a typed BuildFailure during the rebuild

    @Test("""
    A recovery rebuild that throws a typed BuildFailure routes every protected entry to dynamic isolated fallback \
    (.sharedChunkBuildFailure), not .unviable — ADR-0008 Addendum 4
    """)
    func typedBuildFailureDuringRebuildRoutesToIsolatedFallback() async throws {
        let fixture = try ChunkFixture.make()
        let adapter = FakeSchemataAdapter()
        scriptEntry0TimesOut(fixture, adapter: adapter)
        adapter.buildFailureScript[2] = .throwBuildFailure(
            kind: .compilationError, diagnosis: "synthetic compile error during recovery rebuild"
        )

        let result = try await run(fixture, adapter: adapter)

        #expect(result.results.isEmpty, "a shared build-failure fallback must not also leave a schemata-scored result behind")
        #expect(Set(result.isolatedFallbacks.map(\.mutationID)) == Set(fixture.sortedPoints.map(\.id)))
        for fallback in result.isolatedFallbacks {
            #expect(fallback.reason == .sharedChunkBuildFailure)
        }

        let event = try #require(result.sharedChunkBuildFailureEvents.first)
        #expect(result.sharedChunkBuildFailureEvents.count == 1, "one aggregate event, not one per affected entry")
        #expect(event.chunkID == "chunk-A")
        #expect(event.affectedMutationCount == 2)
        #expect(event.diagnosticReference == "synthetic compile error during recovery rebuild")
    }

    // MARK: - Sub-case 3b: a typed BuildFailure during the rebuild leaves an already-fully-finalized, unrelated entry untouched

    /// Addendum 4 acceptance item 12: recovery-rebuild fallback must be
    /// scoped to not-yet-fully-finalized `MutationID`s only. A third entry
    /// that already finalized with a real schemata verdict *before* the
    /// rebuild-triggering timeout must keep that verdict, never swept into
    /// the same fallback the still-in-flight entries receive.
    @Test("""
    A recovery rebuild's typed BuildFailure only falls back the not-yet-finalized entries it was protecting — an entry that \
    already finalized earlier in the same chunk keeps its own real schemata verdict
    """)
    func typedBuildFailureDuringRebuildLeavesAnAlreadyFinalizedEntryUntouched() async throws {
        let source = "func a() -> Bool { true }\nfunc b() -> Bool { true }\nfunc c() -> Bool { true }\n"
        let relativePath = "ThreeFlags.swift"
        let discovered = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: relativePath
        )
        let points = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
        precondition(points.count == 3)
        let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

        func entry(at index: Int) -> SchemataPlanEntry {
            let point = points[index]
            let token = SchemataSelectorToken(namespace: UInt64(index + 1), localIndex: 1)
            return SchemataPlanEntry(
                mutationID: point.id,
                placement: .embedded(placements: [
                    SchemataEmbeddedPlacement(
                        chunkID: "chunk-A", selectorToken: token,
                        sourceEmbeddingID: sourceEmbeddingID.rawValue, lowererID: ChunkFixture.lowererID,
                        lowererVersion: ChunkFixture.lowererVersion, projectIdentity: ChunkFixture.projectIdentity,
                        target: ChunkFixture.target, module: ChunkFixture.target, product: "\(ChunkFixture.target).app", expectedImages: []
                    )
                ]),
                conflictGroup: nil, projectIdentity: ChunkFixture.projectIdentity, target: ChunkFixture.target,
                module: ChunkFixture.target, product: "\(ChunkFixture.target).app"
            )
        }

        func compilationUnitID(at index: Int) -> CompilationUnitID {
            CompilationUnitID.derive(
                projectIdentity: ChunkFixture.projectIdentity, target: ChunkFixture.target, module: ChunkFixture.target,
                sourcePath: points[index].file, lowererID: ChunkFixture.lowererID, lowererVersion: ChunkFixture.lowererVersion
            )
        }

        let program = SchemataProgram(
            chunkID: "chunk-A", sourceEmbeddingID: sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: relativePath, contents: source)],
            entries: [entry(at: 0), entry(at: 1), entry(at: 2)]
        )
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })

        let adapter = FakeSchemataAdapter()
        // Entry 0 passes cleanly, with no confirmation required, and
        // finalizes before entry 1 ever runs — genuinely "already finalized"
        // by the time the rebuild below happens.
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(at: 0), sourceEmbeddingID: sourceEmbeddingID, includeHit: true
        )
        // Entry 1 times out, triggering Trigger 1's mandatory rebuild before
        // its own confirmation — protecting entries 1 and 2, never entry 0.
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: compilationUnitID(at: 1), sourceEmbeddingID: sourceEmbeddingID, behaviors: [.timedOut]
        )
        // Build call 1 = the initial chunk build (succeeds, entry 0 and
        // entry 1's primary run both happen against it); call 2 = Trigger
        // 1's rebuild, which fails.
        adapter.buildFailureScript[2] = .throwBuildFailure(
            kind: .compilationError, diagnosis: "synthetic compile error during recovery rebuild"
        )

        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [program], points: pointsByID,
            originalSources: [relativePath: Data(source.utf8)], build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-recovery-finalized-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-recovery-finalized-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args", policy: Self.confirmsTimeoutsOnly
        )
        let result = try await runner.run()

        let entry0Result = try #require(result.results.first { $0.id == points[0].id }, "entry 0 must keep its own real verdict")
        #expect(entry0Result.outcome != .infrastructureFailure && entry0Result.outcome != .unviable)
        #expect(Set(result.isolatedFallbacks.map(\.mutationID)) == Set([points[1].id, points[2].id]))
        for fallback in result.isolatedFallbacks {
            #expect(fallback.reason == .sharedChunkBuildFailure)
        }
    }

    // MARK: - Sub-case 4: build-receipt resolution fails during the rebuild (swallowed, not thrown)

    @Test("""
    A recovery rebuild whose receipt resolution fails is absorbed as a nil receipt — entries proceed and are not auto-routed \
    to fallback
    """)
    func receiptResolutionFailureDuringRebuildIsAbsorbedAsNilReceipt() async throws {
        let fixture = try ChunkFixture.make()
        let adapter = FakeSchemataAdapter()
        scriptEntry0TimesOut(fixture, adapter: adapter)
        adapter.buildFailureScript[2] = .throwOnReceiptResolution

        let result = try await run(fixture, adapter: adapter)

        // Not a `.failed` `ChunkPreparationOutcome` at all — the rebuild's
        // build step succeeds, only receipt resolution fails, swallowed via
        // `try?` exactly like the initial build's own path. Both entries
        // proceed and actually run against the rebuilt (receiptless)
        // artifact, landing on the *same* "missing build receipt ->
        // infrastructureFailure, no fallback" classification an existing,
        // unrelated verifier-level test already pins for this exact chain
        // shape (`MutationVerdictVerifierSchemataChainTests`, "G: passed +
        // missing build receipt -> no fallback, stays infrastructureFailure").
        #expect(result.isolatedFallbacks.isEmpty)
        #expect(result.results.count == 2)
        #expect(try outcome(for: fixture.sortedPoints[0].id, in: result).outcome == .infrastructureFailure)
        #expect(try outcome(for: fixture.sortedPoints[1].id, in: result).outcome == .infrastructureFailure)
        #expect(result.sharedChunkBuildFailureEvents.isEmpty, "receipt resolution failure is not a build failure and reports no event")
    }
}
