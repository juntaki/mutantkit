import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend
import Testing

/// Direct unit tests for `SharedBaselineEstablisher` — the component
/// `SchemataRunOrchestration` uses to establish one baseline and share it
/// between the schemata and isolated-fallback passes (Gate 3 found the
/// previous "each pass builds and tests its own" shape cost ~104s, ~9.5%
/// of total wall, on a real iOS project). No process spawn: `build`/`test`
/// here are in-memory fakes, so these assert exactly what
/// `establish(...)` did and how many times, not what a real `xcodebuild`
/// happened to report.
@Suite("Shared baseline establisher")
struct SharedBaselineEstablisherTests {
    private let sandbox = URL(fileURLWithPath: "/tmp/shared-baseline-establisher-tests")

    private func command(_ exe: String) -> CommandRecord {
        CommandRecord(executable: exe, arguments: [], workingDirectory: sandbox.path)
    }

    private func passingArtifact() -> BuildArtifact {
        BuildArtifact(productsDirectory: sandbox, productHash: "sha256:stub", xctestrunPath: nil, command: command("build"))
    }

    @Test("A passing baseline with selectCoveringTests off establishes without measuring coverage, and builds exactly once")
    func passingBaselineNoCoverage() async throws {
        let build = SpyBuildAdapter(buildBaselineResult: .success(passingArtifact()))
        let test = SpyTestAdapter(
            baselineResult: TestRunResult(status: .passed, summary: nil, command: command("test"), resultArtifactPath: nil, diagnosis: "ok")
        )
        let configuration = Configuration(execution: ExecutionSettings(selectCoveringTests: false))

        let outcome = await SharedBaselineEstablisher.establish(
            build: build, test: test, in: sandbox, configuration: configuration, projectRoot: sandbox,
            coverageCache: nil, coverageCacheKey: nil
        )

        guard case let .established(baseline) = outcome else {
            Issue.record("expected .established, got \(outcome)")
            return
        }
        #expect(baseline.record.passed)
        #expect(baseline.perTestCoverage == nil)
        let buildCalls = await build.buildBaselineCallCount
        #expect(buildCalls == 1)
        let measureCalls = await test.measurePerTestCoverageCallCount
        #expect(measureCalls == 0, "selectCoveringTests is off, so coverage must never be measured")
    }

    @Test("A build failure returns .failed with a build-specific diagnosis, and the test adapter is never called")
    func buildFailureReturnsFailed() async throws {
        let build = SpyBuildAdapter(buildBaselineResult: .failure(
            BuildFailure(kind: .compilationError, diagnosis: "syntax error", command: command("build"), output: "")
        ))
        let test = SpyTestAdapter(
            baselineResult: TestRunResult(status: .passed, summary: nil, command: command("test"), resultArtifactPath: nil, diagnosis: "ok")
        )
        let configuration = Configuration()

        let outcome = await SharedBaselineEstablisher.establish(
            build: build, test: test, in: sandbox, configuration: configuration, projectRoot: sandbox,
            coverageCache: nil, coverageCacheKey: nil
        )

        guard case let .failed(record, diagnosis) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!record.passed)
        #expect(diagnosis.contains("does not build unmutated"))
        let runCalls = await test.runBaselineCallCount
        #expect(runCalls == 0, "a build that never succeeds must never reach the test adapter")
    }

    @Test("A failing test suite returns .failed with a suite-specific diagnosis")
    func testFailureReturnsFailed() async throws {
        let build = SpyBuildAdapter(buildBaselineResult: .success(passingArtifact()))
        let test = SpyTestAdapter(
            baselineResult: TestRunResult(
                status: .failed, summary: TestOutcomeSummary(total: 10, passed: 8, failed: 2, failingTests: [], durationSeconds: nil),
                command: command("test"), resultArtifactPath: nil, diagnosis: "2 tests failed"
            )
        )
        let configuration = Configuration()

        let outcome = await SharedBaselineEstablisher.establish(
            build: build, test: test, in: sandbox, configuration: configuration, projectRoot: sandbox,
            coverageCache: nil, coverageCacheKey: nil
        )

        guard case let .failed(record, diagnosis) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!record.passed)
        #expect(diagnosis.contains("did not pass"))
    }

    @Test("selectCoveringTests on, cache miss: measures via TestSelecting and stores the result")
    func coverageMissMeasuresAndStores() async throws {
        let build = SpyBuildAdapter(buildBaselineResult: .success(passingArtifact()))
        let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
        let measured = PerTestCoverageMap(coveringTests: ["A.swift": [1: [addTest]]], source: "test")
        let test = SpyTestAdapter(
            baselineResult: TestRunResult(status: .passed, summary: nil, command: command("test"), resultArtifactPath: nil, diagnosis: "ok"),
            coverageResult: measured
        )
        let configuration = Configuration(execution: ExecutionSettings(selectCoveringTests: true))
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("shared-baseline-cache-\(UUID().uuidString)")
        let cache = CoverageProfileCache(root: cacheRoot)
        let key = CoverageProfileCache.Key(contextDigest: "digest-1")

        let outcome = await SharedBaselineEstablisher.establish(
            build: build, test: test, in: sandbox, configuration: configuration, projectRoot: sandbox,
            coverageCache: cache, coverageCacheKey: key
        )

        guard case let .established(baseline) = outcome else {
            Issue.record("expected .established, got \(outcome)")
            return
        }
        #expect(baseline.perTestCoverage == measured)
        let measureCalls = await test.measurePerTestCoverageCallCount
        #expect(measureCalls == 1)
        let cached = await cache.load(key)
        #expect(cached == measured, "a miss must store the freshly-measured map for the next run")
    }

    @Test("selectCoveringTests on, cache hit: never calls measurePerTestCoverage")
    func coverageHitSkipsMeasurement() async throws {
        let build = SpyBuildAdapter(buildBaselineResult: .success(passingArtifact()))
        let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
        let cachedMap = PerTestCoverageMap(coveringTests: ["A.swift": [1: [addTest]]], source: "test")
        let test = SpyTestAdapter(
            baselineResult: TestRunResult(status: .passed, summary: nil, command: command("test"), resultArtifactPath: nil, diagnosis: "ok")
        )
        let configuration = Configuration(execution: ExecutionSettings(selectCoveringTests: true))
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("shared-baseline-cache-\(UUID().uuidString)")
        let cache = CoverageProfileCache(root: cacheRoot)
        let key = CoverageProfileCache.Key(contextDigest: "digest-2")
        await cache.store(cachedMap, for: key)

        let outcome = await SharedBaselineEstablisher.establish(
            build: build, test: test, in: sandbox, configuration: configuration, projectRoot: sandbox,
            coverageCache: cache, coverageCacheKey: key
        )

        guard case let .established(baseline) = outcome else {
            Issue.record("expected .established, got \(outcome)")
            return
        }
        #expect(baseline.perTestCoverage == cachedMap)
        let measureCalls = await test.measurePerTestCoverageCallCount
        #expect(measureCalls == 0, "a cache hit must never re-measure")
    }
}

// MARK: - Fakes

private actor SpyBuildAdapter: BuildAdapter {
    private(set) var buildBaselineCallCount = 0
    private let buildBaselineResult: Result<BuildArtifact, Error>

    init(buildBaselineResult: Result<BuildArtifact, Error>) {
        self.buildBaselineResult = buildBaselineResult
    }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        buildBaselineCallCount += 1
        return try buildBaselineResult.get()
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        fatalError("SharedBaselineEstablisher never builds a mutant")
    }
}

private actor SpyTestAdapter: TestAdapter, TestSelecting {
    private(set) var runBaselineCallCount = 0
    private(set) var measurePerTestCoverageCallCount = 0
    private let baselineResult: TestRunResult
    private let coverageResult: PerTestCoverageMap?

    init(baselineResult: TestRunResult, coverageResult: PerTestCoverageMap? = nil) {
        self.baselineResult = baselineResult
        self.coverageResult = coverageResult
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        runBaselineCallCount += 1
        return baselineResult
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("SharedBaselineEstablisher never runs a mutant")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        fatalError("SharedBaselineEstablisher never runs a mutant")
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        measurePerTestCoverageCallCount += 1
        return coverageResult
    }
}
