import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0008 Addendum 4: a typed `BuildFailure` from a shared schemata chunk
/// build is chunk-level evidence only — it must not directly establish
/// `.unviable` for any individual `MutationID` the chunk represents.
/// Instead every affected `MutationID` (whole-`MutationID`, all target
/// placements, discarding anything already produced) falls back to
/// isolated mode via `.isolatedFallback(reason: .sharedChunkBuildFailure)`,
/// joining the existing all-or-nothing dynamic-fallback mechanism
/// `SchemataMutationRunnerDynamicFallbackTests` already pins for Group 2
/// (no-HIT/no-STARTUP) and `SchemataMutationRunnerHangBudgetOverflowTests`
/// already pins for hang-budget overflow. The recovery-rebuild sub-case of
/// this same rule is pinned separately in
/// `SchemataMutationRunnerRecoveryRebuildFailureTests`; this file covers the
/// *initial* per-chunk build failure and the multi-target interaction.
@Suite("SchemataMutationRunner: ADR-0008 Addendum 4 shared chunk build-failure attribution")
struct SchemataMutationRunnerSharedChunkBuildFailureTests {
    // MARK: - Fixture: a 3-entry single chunk, no scripts needed (the build fails before any entry ever spawns a process)

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

    private func entry(mutationID: MutationID, target: String, chunkID: String, localIndex: UInt32, namespace: UInt64) -> SchemataPlanEntry {
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
                projectRoot: Self.makeTempDir(prefix: "mutantkit-shared-build-failure-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-shared-build-failure-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args", policy: .permissive
        )
        return try await runner.run()
    }

    // MARK: - Initial shared typed BuildFailure

    @Test("""
    A chunk whose initial build throws a typed BuildFailure routes every one of its entries to .sharedChunkBuildFailure fallback, \
    and reports exactly one aggregate event with the affected count and diagnostic reference (ADR-0008 Addendum 4 observability)
    """)
    func initialSharedTypedBuildFailureFallsBackEveryEntry() async throws {
        let points = try threePoints()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let entries = points.enumerated().map { index, point in
            entry(mutationID: point.id, target: Self.target, chunkID: "chunk-A", localIndex: UInt32(index + 1), namespace: 1)
        }
        let adapter = FakeSchemataAdapter()
        adapter.buildFailureScript[1] = .throwBuildFailure(kind: .compilationError, diagnosis: "synthetic shared-chunk compile error")

        let outcome = try await run(points: pointsByID, programs: [program(chunkID: "chunk-A", entries: entries)], adapter: adapter)

        #expect(outcome.results.isEmpty, "a shared build-failure fallback must not leave any schemata-scored result behind")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(Set(outcome.isolatedFallbacks.map(\.mutationID)) == Set(points.map(\.id)))
        for fallback in outcome.isolatedFallbacks {
            #expect(fallback.reason == .sharedChunkBuildFailure)
        }

        // Observability: one aggregate event, not three individual ones.
        let event = try #require(outcome.sharedChunkBuildFailureEvents.first)
        #expect(outcome.sharedChunkBuildFailureEvents.count == 1)
        #expect(event.chunkID == "chunk-A")
        #expect(event.affectedMutationCount == 3)
        #expect(event.diagnosticReference == "synthetic shared-chunk compile error")
    }

    // MARK: - Genuine unviable, surviving fallback (end-to-end: SchemataMutationRunner's fallback signal, chained into the real isolated MutationRunner)

    /// `SchemataMutationRunner`'s own responsibility ends at "route
    /// uniformly to isolated fallback, fabricate no verdict" — it has no
    /// visibility into whether a given `MutationID` will turn out genuinely
    /// unviable once isolated mode actually attempts it. This test proves
    /// the full chain, not just this runner's own half: the fallback ID
    /// `SchemataMutationRunner` produces, when actually run through the
    /// real, unmodified isolated `MutationRunner` -> `MutationVerdictVerifier`
    /// path (a fake `BuildAdapter` whose `buildMutant` genuinely throws a
    /// typed `BuildFailure`, simulating a mutation that truly does not
    /// compile on its own), ends up `.unviable` — never lost, never
    /// silently dropped, and not because this runner guessed it.
    @Test("A MutationID that falls back via .sharedChunkBuildFailure ends up .unviable once genuinely run through isolated mode")
    func fallbackMutationIDResolvesToUnviableThroughRealIsolatedRunner() async throws {
        let points = try threePoints()
        let point = points[0]
        let pointsByID = [point.id: point]
        let schemataEntry = entry(mutationID: point.id, target: Self.target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let schemataAdapter = FakeSchemataAdapter()
        schemataAdapter.buildFailureScript[1] = .throwBuildFailure(
            kind: .compilationError, diagnosis: "synthetic shared-chunk compile error"
        )

        let schemataOutcome = try await run(
            points: pointsByID, programs: [program(chunkID: "chunk-A", entries: [schemataEntry])], adapter: schemataAdapter
        )
        let fallback = try #require(schemataOutcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == point.id)
        #expect(fallback.reason == .sharedChunkBuildFailure)
        #expect(schemataOutcome.results.isEmpty, "no verdict must be fabricated by the schemata runner itself")

        // `SchemataRunOrchestration` (untested here) is what actually
        // re-plans and re-runs `isolatedFallbacks`' MutationIDs through
        // isolated mode; this test exercises that downstream half directly,
        // with a fake BuildAdapter/TestAdapter pair matching the existing
        // `MutationRunner` unit-test convention (see
        // `MutationRunnerTimeoutConfirmationTests`'s `StubBuildAdapter`/
        // `ScriptedTestAdapter`).
        let projectRoot = Self.makeTempDir(prefix: "mutantkit-isolated-fallback-project")
        try Data(Self.source.utf8).write(to: projectRoot.appendingPathComponent(Self.relativePath))
        let plan = MutationPlan(
            planID: "plan-1", createdAt: Date(), projectRoot: projectRoot.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "test", toolCommitSHA: nil, swiftVersion: "test", swiftSyntaxVersion: "test", xcodeVersion: nil
            ),
            configurationHash: "config-hash", sourceFileHashes: [Self.relativePath: "hash"],
            mutations: [point], skipped: [], operators: []
        )
        let runner = MutationRunner(
            plan: plan, configuration: Configuration(), projectRoot: projectRoot,
            build: GenuinelyUnviableBuildAdapter(), test: NeverCalledPastBaselineTestAdapter(),
            workspaces: try WorkspaceManager(
                projectRoot: projectRoot, scratchRoot: Self.makeTempDir(prefix: "mutantkit-isolated-fallback-scratch")
            )
        )
        let report = try await runner.run()
        let result = try #require(report.results.first { $0.id == point.id })
        #expect(result.outcome == .unviable, "\(result.diagnosis)")
    }

    // MARK: - Multi-target all-or-nothing discard

    /// Mirrors `SchemataMutationRunnerDynamicFallbackTests
    /// .multiTargetAllOrNothingFallback` (Group 2's own multi-target
    /// regression) for this addendum's new trigger: the same `MutationID`
    /// embedded in two targets, one already schemata-verified, the other's
    /// chunk build failing outright. The whole `MutationID` — including the
    /// already-produced, individually-valid verdict from the first target —
    /// must fall back, never a partial schemata/isolated split.
    @Test("Multi-target: one target's shared build failure discards the whole MutationID, including the other target's already-verified result")
    func multiTargetSharedBuildFailureDiscardsAlreadyVerifiedPlacement() async throws {
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
        // build is FakeSchemataAdapter's build call 2 — fail it outright.
        adapter.buildFailureScript[2] = .throwBuildFailure(kind: .compilationError, diagnosis: "synthetic target-B chunk compile error")

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
            target A's individually-valid schemata result must be discarded once target B's shared build failure forces this \
            MutationID to fall back as a whole
            """
        )
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(outcome.isolatedFallbacks.count == 1)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == point.id)
        #expect(fallback.reason == .sharedChunkBuildFailure)
    }

    // MARK: - Observability: one event per failed chunk, never merged or duplicated across chunks

    @Test("Two independently-failing chunks each report their own event — never merged into one, never duplicated per entry")
    func multipleIndependentFailedChunksEachReportTheirOwnEvent() async throws {
        let points = try threePoints()
        let pointA = points[0]
        let pointB = points[1]
        let entryA = entry(mutationID: pointA.id, target: Self.target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let entryB = entry(mutationID: pointB.id, target: Self.target, chunkID: "chunk-B", localIndex: 1, namespace: 2)

        let adapter = FakeSchemataAdapter()
        // `run()` processes programs in order, so chunk-A's build is call 1
        // and chunk-B's is call 2 — fail both, with distinguishable diagnoses.
        adapter.buildFailureScript[1] = .throwBuildFailure(kind: .compilationError, diagnosis: "chunk-A compile error")
        adapter.buildFailureScript[2] = .throwBuildFailure(kind: .compilationError, diagnosis: "chunk-B compile error")

        let outcome = try await run(
            points: [pointA.id: pointA, pointB.id: pointB],
            programs: [program(chunkID: "chunk-A", entries: [entryA]), program(chunkID: "chunk-B", entries: [entryB])],
            adapter: adapter
        )

        #expect(outcome.sharedChunkBuildFailureEvents.count == 2, "one event per failed chunk, never merged into one")
        let byChunk = Dictionary(uniqueKeysWithValues: outcome.sharedChunkBuildFailureEvents.map { ($0.chunkID, $0) })
        let eventA = try #require(byChunk["chunk-A"])
        let eventB = try #require(byChunk["chunk-B"])
        #expect(eventA.affectedMutationCount == 1)
        #expect(eventA.diagnosticReference == "chunk-A compile error")
        #expect(eventB.affectedMutationCount == 1)
        #expect(eventB.diagnosticReference == "chunk-B compile error")
        #expect(Set(outcome.isolatedFallbacks.map(\.mutationID)) == Set([pointA.id, pointB.id]))
    }

    @Test("A chunk whose build fails with an untyped error or a nil product hash reports no observability event — only a typed BuildFailure does")
    func nonTypedBuildFailuresReportNoEvent() async throws {
        let points = try threePoints()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let entries = points.enumerated().map { index, point in
            entry(mutationID: point.id, target: Self.target, chunkID: "chunk-A", localIndex: UInt32(index + 1), namespace: 1)
        }

        for injection: FakeSchemataAdapter.BuildFailureInjection in [.throwUntypedError, .nilProductHash] {
            let adapter = FakeSchemataAdapter()
            adapter.buildFailureScript[1] = injection
            let outcome = try await run(points: pointsByID, programs: [program(chunkID: "chunk-A", entries: entries)], adapter: adapter)

            #expect(outcome.sharedChunkBuildFailureEvents.isEmpty, "\(injection) must not report a shared-chunk-build-failure event")
            #expect(outcome.isolatedFallbacks.isEmpty, "\(injection) is an infrastructure signal, not a dynamic fallback trigger")
        }
    }
}

// MARK: - Fakes for the real isolated MutationRunner (end-to-end fallback test only)

/// Baseline builds fine; any mutant build genuinely throws a typed
/// `BuildFailure` — simulating a mutation that truly does not compile on
/// its own, independent of anything schemata-specific.
private struct GenuinelyUnviableBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "baseline-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        throw BuildFailure(
            kind: .compilationError, diagnosis: "synthetic: this mutant genuinely does not compile",
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path), output: ""
        )
    }
}

/// `runBaseline` passes; `runMutant` is never reached (the build fails
/// first), so it fails loudly if that assumption ever stops holding.
private struct NeverCalledPastBaselineTestAdapter: TestAdapter {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        TestRunResult(
            status: .passed, summary: nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: workspace.path),
            resultArtifactPath: nil, diagnosis: "diag:passed"
        )
    }

    func runMutant(_ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("unreachable: buildMutant always throws before any test runs")
    }
}
