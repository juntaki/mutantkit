import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Schemata mode's participation in the *existing* `CoverageProfileCache` —
/// the same cache, key type, and consult-then-store shape isolated mode's
/// `MutationRunner.establishBaseline` has always used, now reached from
/// `SchemataMutationRunner` too (the sibling of the isolated-mode coverage
/// cache suite).
///
/// The fact under test is specifically that the *expensive pass is skipped*,
/// not merely that the right map comes out: `measurePerTestCoverage` on a
/// real project is the single most expensive thing a baseline does, so every
/// assertion here reads `FakeSchemataAdapter.measurePerTestCoverageCallCount`
/// rather than inferring a hit from the resulting selection alone. To keep
/// "which map was used" honest, the cached entry and the adapter's scripted
/// measurement attribute *different* tests, so a run that silently measured
/// anyway could not accidentally produce the cache's answer.
///
/// No process is spawned anywhere in this suite; the cache is a real
/// `CoverageProfileCache` rooted in a temp directory.
@Suite("SchemataMutationRunner: per-test coverage cache")
struct SchemataMutationRunnerCoverageCacheTests {
    private static let source = "func flag() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))
    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let target = "App"
    private static let token = SchemataSelectorToken(namespace: 1, localIndex: 1)
    /// What a *cache hit* attributes to the mutated line.
    private static let cachedTest = TestIdentifier(target: "AppTests", qualifiedName: "WidgetTests/testFromCache")
    /// What a *fresh measurement* attributes to it — deliberately different,
    /// so the two are never confusable in an assertion.
    private static let measuredTest = TestIdentifier(target: "AppTests", qualifiedName: "WidgetTests/testFromMeasurement")

    private static let key = CoverageProfileCache.Key(contextDigest: "context-digest-for-this-suite")

    private func point() throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        return try #require(points.first, "expected a bool-literal candidate")
    }

    private func entry(mutationID: MutationID) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: "chunk-A", selectorToken: Self.token,
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target, product: "\(Self.target).app",
                    expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            product: "\(Self.target).app"
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func coverage(attributing test: TestIdentifier, at point: MutationPoint) -> PerTestCoverageMap {
        PerTestCoverageMap(coveringTests: [point.file: [point.line: [test]]], source: "test")
    }

    private struct RunResult {
        let adapter: FakeSchemataAdapter
        let cache: CoverageProfileCache
    }

    /// One embedded mutation through the runner. `cache`/`key` are handed to
    /// the runner exactly as `SchemataRunOrchestration` now does; passing
    /// `nil` for either reproduces the pre-cache call shape.
    private func run(
        cache: CoverageProfileCache?,
        key: CoverageProfileCache.Key?,
        prepopulate: Bool,
        selectCoveringTests: Bool = true
    ) async throws -> RunResult {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let unit = CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            sourcePath: mutationPoint.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )

        let adapter = FakeSchemataAdapter()
        adapter.scripts[Self.token] = .init(
            compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.perTestCoverageToReturn = coverage(attributing: Self.measuredTest, at: mutationPoint)

        let cache = cache ?? CoverageProfileCache(root: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-unused"))
        if prepopulate, let key {
            await cache.store(coverage(attributing: Self.cachedTest, at: mutationPoint), for: key)
        }

        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [SchemataProgram(
                chunkID: "chunk-A", sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
                loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
                entries: [entry(mutationID: mutationID)]
            )],
            points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false
            ),
            selectCoveringTests: selectCoveringTests,
            coverageCache: cache,
            coverageCacheKey: key
        )
        let outcome = try await runner.run()
        #expect(outcome.results.count == 1)
        return RunResult(adapter: adapter, cache: cache)
    }

    @Test("Cache hit: the profiling pass is never dispatched, and the cached attribution is what narrows the run")
    func cacheHitSkipsProfilingEntirely() async throws {
        let result = try await run(
            cache: CoverageProfileCache(root: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-hit")),
            key: Self.key, prepopulate: true
        )

        #expect(result.adapter.measurePerTestCoverageCallCount == 0)
        // The *cached* test, not the one a fresh measurement would have
        // attributed — a run that quietly re-measured could not produce this.
        #expect(result.adapter.selectedTestsSeen == [[Self.cachedTest]])
    }

    @Test("Cache miss: the profiling pass runs once, and its result is stored back under the key for the next run")
    func cacheMissMeasuresAndStores() async throws {
        let result = try await run(
            cache: CoverageProfileCache(root: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-miss")),
            key: Self.key, prepopulate: false
        )

        #expect(result.adapter.measurePerTestCoverageCallCount == 1)
        #expect(result.adapter.selectedTestsSeen == [[Self.measuredTest]])

        let stored = try #require(await result.cache.load(Self.key), "a miss must leave the measured attribution behind")
        let mutationPoint = try point()
        #expect(stored.testsCovering(file: mutationPoint.file, line: mutationPoint.line) == [Self.measuredTest])
    }

    @Test("No cache key (the CLI's digest computation failed): measured every run, nothing consulted, nothing stored")
    func nilKeyBehavesExactlyAsBeforeTheCache() async throws {
        let cache = CoverageProfileCache(root: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-nilkey"))
        // Pre-populated under the key the run would have used *if* it had
        // one: a run that fell back to some other lookup would be caught.
        await cache.store(coverage(attributing: Self.cachedTest, at: try point()), for: Self.key)

        let result = try await run(cache: cache, key: nil, prepopulate: false)

        #expect(result.adapter.measurePerTestCoverageCallCount == 1)
        #expect(result.adapter.selectedTestsSeen == [[Self.measuredTest]])
        // Untouched: without a key there is nothing to store the fresh
        // measurement under, so the pre-existing entry stays as it was.
        let mutationPoint = try point()
        let stored = try #require(await cache.load(Self.key))
        #expect(stored.testsCovering(file: mutationPoint.file, line: mutationPoint.line) == [Self.cachedTest])
    }

    @Test("No cache configured at all (every pre-existing call site): measured every run, exactly as before this parameter existed")
    func nilCacheBehavesExactlyAsBeforeTheCache() async throws {
        let mutationPoint = try point()
        let adapter = FakeSchemataAdapter()
        let mutationID = mutationPoint.id
        adapter.scripts[Self.token] = .init(
            compilationUnitID: CompilationUnitID.derive(
                projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
                sourcePath: mutationPoint.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
            ),
            sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.perTestCoverageToReturn = coverage(attributing: Self.measuredTest, at: mutationPoint)

        // Constructed without either coverage-cache argument — the literal
        // pre-change call shape every existing call site still uses.
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [SchemataProgram(
                chunkID: "chunk-A", sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
                loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
                entries: [entry(mutationID: mutationID)]
            )],
            points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-nocache-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-nocache-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false
            ),
            selectCoveringTests: true
        )
        let outcome = try await runner.run()

        #expect(outcome.results.count == 1)
        #expect(adapter.measurePerTestCoverageCallCount == 1)
        #expect(adapter.selectedTestsSeen == [[Self.measuredTest]])
    }

    @Test("selectCoveringTests off: the cache is not consulted either, hit or not — no attribution is wanted at all")
    func flagOffNeverConsultsTheCache() async throws {
        let result = try await run(
            cache: CoverageProfileCache(root: Self.makeTempDir(prefix: "mutantkit-schemata-coverage-cache-flagoff")),
            key: Self.key, prepopulate: true, selectCoveringTests: false
        )

        #expect(result.adapter.measurePerTestCoverageCallCount == 0)
        // Unrestricted, despite a populated cache entry sitting right there.
        #expect(result.adapter.selectedTestsSeen == [nil])
    }
}
