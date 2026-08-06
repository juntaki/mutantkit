import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for the `CoverageProfileCache` wiring inside
/// `MutationRunner.establishBaseline`: a run with a cached attribution must
/// not call `measurePerTestCoverage` at all, and a run that measures must
/// store the result so the next run against the same key skips measurement.
///
/// The same fakes and fixture shape as `MutationRunnerTestSelectionTests`,
/// with an added call counter on the selective adapter and a real (temp-dir)
/// cache the two runs share.
@Suite("Mutation runner: coverage profile cache")
struct MutationRunnerCoverageCacheTests {
    private let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-cache-project-\(UUID().uuidString)")
    private let scratchRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-cache-scratch-\(UUID().uuidString)")
    private let cacheRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-cache-store-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )
    private let cacheKey = CoverageProfileCache.Key(contextDigest: "test-digest")

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    private func makeRunner(adapter: CountingSelectiveTestAdapter, plan: MutationPlan) throws -> MutationRunner {
        let configuration = Configuration(
            execution: ExecutionSettings(selectCoveringTests: true)
        )
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        return MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            coverageCache: CoverageProfileCache(root: cacheRoot),
            coverageCacheKey: cacheKey
        )
    }

    @Test("A cold run measures coverage and stores it in the cache")
    func coldRunMeasuresAndStores() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration(execution: ExecutionSettings(selectCoveringTests: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)
        let measured = PerTestCoverageMap(
            coveringTests: [point.file: [point.line: [TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testSomething")]]],
            source: "test"
        )
        let adapter = CountingSelectiveTestAdapter(perTestCoverage: measured)
        let runner = try makeRunner(adapter: adapter, plan: plan)

        _ = try await runner.run()

        let measureCount = await adapter.measurePerTestCoverageCallCount
        #expect(measureCount == 1, "a cold run with selectCoveringTests must measure once")

        let cached = await CoverageProfileCache(root: cacheRoot).load(cacheKey)
        #expect(cached == measured, "the measured map must be stored back for the next run")
    }

    @Test("A warm run reuses the cached map and skips measurement entirely")
    func warmRunReusesCacheAndSkipsMeasurement() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration(execution: ExecutionSettings(selectCoveringTests: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)
        let cached = PerTestCoverageMap(
            coveringTests: [point.file: [point.line: [TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testSomething")]]],
            source: "test"
        )
        let cache = CoverageProfileCache(root: cacheRoot)
        await cache.store(cached, for: cacheKey)

        let adapter = CountingSelectiveTestAdapter(perTestCoverage: nil)
        let runner = try makeRunner(adapter: adapter, plan: plan)

        let report = try await runner.run()

        let measureCount = await adapter.measurePerTestCoverageCallCount
        #expect(measureCount == 0, "a warm run must not call measurePerTestCoverage at all")

        let selections = await adapter.recordedSelections
        #expect(
            selections.first??.count == 1,
            "the cached attribution must still drive selection on the mutant run"
        )
        #expect(report.results.first?.outcome == .killedByAssertion)
    }

    @Test("A run with no cache key always measures, even when a cache is supplied")
    func noKeyAlwaysMeasures() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration(execution: ExecutionSettings(selectCoveringTests: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)
        let measured = PerTestCoverageMap(
            coveringTests: [point.file: [point.line: [TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testSomething")]]],
            source: "test"
        )
        let adapter = CountingSelectiveTestAdapter(perTestCoverage: measured)
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            coverageCache: CoverageProfileCache(root: cacheRoot),
            coverageCacheKey: nil
        )

        _ = try await runner.run()

        let measureCount = await adapter.measurePerTestCoverageCallCount
        #expect(measureCount == 1, "no key means the cache is inert")
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Same shape as `MutationRunnerTestSelectionTests`'s adapter, with a call
/// counter on `measurePerTestCoverage` so a test can tell whether the
/// cache short-circuited the baseline profiling pass.
private actor CountingSelectiveTestAdapter: TestSelecting {
    private var mutantStatus: TestRunStatus = .failed
    private let perTestCoverage: PerTestCoverageMap?
    private(set) var measurePerTestCoverageCallCount = 0
    private(set) var recordedSelections: [Set<TestIdentifier>?] = []

    init(perTestCoverage: PerTestCoverageMap?) {
        self.perTestCoverage = perTestCoverage
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        measurePerTestCoverageCallCount += 1
        return perTestCoverage
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, selectedTests: nil)
    }

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        recordedSelections.append(selectedTests)
        return Self.result(mutantStatus)
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)"
        )
    }
}
