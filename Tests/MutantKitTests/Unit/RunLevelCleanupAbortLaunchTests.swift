import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// "Nothing new is built or tested" after a run-level abort, at the launch
/// sites `RunLevelCleanupAbortTests` does not reach: isolated batch,
/// pipelined and wave test dispatch, the baseline build in every runner, and
/// a monitor that tripped before the engine started. Each row asserts both
/// that the run aborts and that the next launch never happened.
@Suite("Run-level abort: nothing is launched after the trip", .subprocessExclusive)
struct RunLevelCleanupAbortLaunchTests {
    enum BatchPath: String, CaseIterable, Sendable {
        /// `testAndFinish` → `testOneBatch`.
        case plain
        /// Incremental build: the pipelined test lane → `testOneBatch`.
        case pipelined
        /// Wave mode with no attribution → `testUnattributed`.
        case unattributed
        /// Wave mode with attribution → `testWaveChunk`, wave after wave.
        case wave
    }

    // MARK: - Isolated batch dispatch

    @Test("Batch dispatch: an unverified batch starts no later batch", arguments: BatchPath.allCases)
    func unverifiedBatchStartsNoLaterBatch(path: BatchPath) async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: 1)
        let build = LaunchCountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) { try await Self.runIsolated(path: path, build: build, test: test) }
        #expect(await test.runBatchCallCount == 1, "no batch may be launched after the abort")
    }

    @Test("Batch dispatch control: without a trip every batch runs", arguments: BatchPath.allCases)
    func verifiedBatchesAllRun(path: BatchPath) async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: nil)
        let build = LaunchCountingBuildAdapter()

        try await Self.runIsolated(path: path, build: build, test: test)
        // Two mutants, batch size 1; waves test each of two covering tests.
        #expect(await test.runBatchCallCount == (path == .wave ? 4 : 2))
    }

    @Test("Batch dispatch: an unverified mutant build is never batch-tested")
    func unverifiedMutantBuildIsNeverBatchTested() async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: nil)
        let build = LaunchCountingBuildAdapter(unverifiedMutantBuild: true)

        await #expect(throws: RunAbortedError.self) { try await Self.runIsolated(path: .plain, build: build, test: test) }
        #expect(build.mutantBuildCount == 1)
        #expect(await test.runBatchCallCount == 0, "nothing may be tested after an uncontained build")
    }

    // MARK: - Baseline build

    @Test("Isolated baseline build: an unverified baseline build starts no baseline test")
    func isolatedUnverifiedBaselineBuild() async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: nil)
        let build = LaunchCountingBuildAdapter(unverifiedBaselineBuild: true)

        await #expect(throws: RunAbortedError.self) { try await Self.runIsolated(path: .plain, build: build, test: test) }
        #expect(await test.baselineCallCount == 0)
        #expect(build.mutantBuildCount == 0)
    }

    @Test("Hybrid baseline build: an unverified shared baseline build starts no baseline test")
    func hybridUnverifiedBaselineBuild() async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: nil)
        let build = LaunchCountingBuildAdapter(unverifiedBaselineBuild: true)

        await #expect(throws: RunAbortedError.self) { try await Self.runHybrid(build: build, test: test) }
        #expect(await test.baselineCallCount == 0)
        #expect(build.mutantBuildCount == 0)
    }

    @Test("Schemata baseline build: an unverified baseline build starts no baseline test")
    func schemataUnverifiedBaselineBuild() async throws {
        let adapter = FakeSchemataAdapter()
        adapter.baselineBuildRunsUnverifiedProcess = true

        await #expect(throws: RunAbortedError.self) { _ = try await Self.schemataRunner(adapter).run() }
        #expect(adapter.baselineTimeoutSeconds.isEmpty, "no baseline test may run after an uncontained baseline build")
    }

    // MARK: - Tripped before the engine

    @Test("Isolated: a monitor tripped before the engine builds nothing")
    func isolatedPreTrippedBuildsNothing() async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: nil)
        let build = LaunchCountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) {
            try await Self.tripped { try await Self.runIsolated(path: .plain, build: build, test: test) }
        }
        #expect(build.baselineBuildCount == 0)
        #expect(await test.baselineCallCount == 0)
    }

    @Test("Hybrid: a monitor tripped before the engine builds nothing")
    func hybridPreTrippedBuildsNothing() async throws {
        let test = CleanupBatchAdapter(unverifiedBatchCall: nil)
        let build = LaunchCountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) {
            try await Self.tripped { try await Self.runHybrid(build: build, test: test) }
        }
        #expect(build.baselineBuildCount == 0)
        #expect(await test.baselineCallCount == 0)
    }

    @Test("Schemata: a monitor tripped before the engine builds nothing")
    func schemataPreTrippedBuildsNothing() async throws {
        let adapter = FakeSchemataAdapter()

        await #expect(throws: RunAbortedError.self) {
            try await Self.tripped { _ = try await Self.schemataRunner(adapter).run() }
        }
        #expect(adapter.baselineBuildCallCount == 0)
        #expect(adapter.baselineTimeoutSeconds.isEmpty)
    }

    // MARK: - Fixtures

    /// Runs `body` inside a run scope whose monitor has already tripped, as
    /// a pre-engine helper (dependency preflight, target resolution) would
    /// leave it. The runner's own scope nests into this one.
    private static func tripped(_ body: @Sendable () async throws -> Void) async throws {
        try await RunContainmentMonitor.withRunScope { monitor in
            monitor.recordUnverifiedCleanup("injected before the engine started")
            try await body()
        }
    }

    private static let coveringTests: Set<TestIdentifier> = [
        TestIdentifier(target: "T", qualifiedName: "C/testA"), TestIdentifier(target: "T", qualifiedName: "C/testB")
    ]

    /// Two mutants on separate lines, so a per-line coverage map attributes
    /// each on its own.
    private static func plan(_ configuration: Configuration, root: URL) async throws -> MutationPlan {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A {\n    var enabled = true\n    var other = true\n}\n".utf8).write(to: url)
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: makeToolchain(), diffScope: nil
        )
        #expect(plan.mutations.count == 2)
        return plan
    }

    private static func runIsolated(path: BatchPath, build: LaunchCountingBuildAdapter, test: CleanupBatchAdapter) async throws {
        let root = makeTempDir(prefix: "mutantkit-abort-launch-project")
        let waves = path == .wave || path == .unattributed
        let configuration = Configuration(execution: ExecutionSettings(
            workers: 1, confirmCrashKills: false, confirmTimedOutMutants: false, selectCoveringTests: waves,
            incrementalBuild: path == .pipelined, earlyAbortSelectedTests: waves, testBatchSize: 1
        ))
        let plan = try await plan(configuration, root: root)
        if path == .wave {
            var lines: [String: [Int: Set<TestIdentifier>]] = [:]
            for point in plan.mutations {
                lines[point.file, default: [:]][point.line] = coveringTests
            }
            await test.setCoverage(PerTestCoverageMap(coveringTests: lines, source: "test"))
        }
        let scratch = makeTempDir(prefix: "mutantkit-abort-launch-scratch")
        _ = try await MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root, build: build, test: test,
            workspaces: try WorkspaceManager(projectRoot: root, scratchRoot: scratch),
            priorityStore: TestPriorityStore(url: scratch.appendingPathComponent("priority.json"))
        ).run()
    }

    private static func runHybrid(build: LaunchCountingBuildAdapter, test: CleanupBatchAdapter) async throws {
        let root = makeTempDir(prefix: "mutantkit-abort-launch-hybrid")
        let configuration = Configuration(execution: ExecutionSettings(workers: 1))
        let plan = try await plan(configuration, root: root)
        let adapter = LaunchProjectAdapter(buildAdapter: build, testAdapter: test)
        let context = HybridExecutionEngine.Context(
            plan: plan, configuration: configuration, projectRoot: root, adapter: adapter, testAdapter: test,
            toolchain: makeToolchain(),
            coverageCache: CoverageProfileCache(root: makeTempDir(prefix: "mutantkit-abort-launch-coverage")), coverageCacheKey: nil
        )
        _ = try await HybridExecutionEngine.runHybrid(
            context: context,
            classification: HybridExecutionEngine.SchemataClassification(
                programs: [], embeddedIDs: [], sources: [:], plannerFallbackReasons: [:]
            ),
            workspaces: try WorkspaceManager(projectRoot: root, scratchRoot: makeTempDir(prefix: "mutantkit-abort-launch-hs")),
            schemataWorkspaces: try WorkspaceManager(projectRoot: root, scratchRoot: makeTempDir(prefix: "mutantkit-abort-launch-hss")),
            startedAt: Date()
        )
    }

    private static func schemataRunner(_ adapter: FakeSchemataAdapter) throws -> SchemataMutationRunner {
        let root = makeTempDir(prefix: "mutantkit-abort-launch-schemata")
        return SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [], points: [:], originalSources: [:], build: adapter, test: adapter,
            workspaces: try WorkspaceManager(projectRoot: root, scratchRoot: makeTempDir(prefix: "mutantkit-abort-launch-ss")),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
            ),
            selectCoveringTests: false, workers: 1, coverageCache: nil, coverageCacheKey: nil
        )
    }
}

// MARK: - Fakes

private func makeTempDir(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds without a toolchain. The `unverified…` flags make the baseline
/// build, or the first mutant build, first run a real supervised process
/// whose post-SIGKILL cleanup cannot be verified.
private final class LaunchCountingBuildAdapter: BuildAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var baselineBuilds = 0
    private var mutantBuilds = 0
    private let unverifiedBaselineBuild: Bool
    private let unverifiedMutantBuild: Bool

    init(unverifiedBaselineBuild: Bool = false, unverifiedMutantBuild: Bool = false) {
        self.unverifiedBaselineBuild = unverifiedBaselineBuild
        self.unverifiedMutantBuild = unverifiedMutantBuild
    }

    var baselineBuildCount: Int { lock.withLock { baselineBuilds } }
    var mutantBuildCount: Int { lock.withLock { mutantBuilds } }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        lock.withLock { baselineBuilds += 1 }
        if unverifiedBaselineBuild { _ = try await UnverifiedCleanupFixture.run() }
        return artifact(hash: "baseline-hash", in: workspace)
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        let call = lock.withLock {
            mutantBuilds += 1
            return mutantBuilds
        }
        if unverifiedMutantBuild, call == 1 { _ = try await UnverifiedCleanupFixture.run() }
        return artifact(hash: "mutant-hash-\(call)", in: workspace)
    }

    private func artifact(hash: String, in workspace: URL) -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: hash, xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Every run passes. `unverifiedBatchCall` (1-based) makes that `runBatch`
/// call report every member's cleanup unverified, as `XcodeBuildAdapter`
/// does when its supervisor could not verify the batch's descendants.
private actor CleanupBatchAdapter: TestSelecting, BatchTestable, SchemataTestable {
    private let unverifiedBatchCall: Int?
    private var coverage: PerTestCoverageMap?
    private(set) var runBatchCallCount = 0
    private(set) var baselineCallCount = 0

    init(unverifiedBatchCall: Int?) {
        self.unverifiedBatchCall = unverifiedBatchCall
    }

    func setCoverage(_ map: PerTestCoverageMap) {
        coverage = map
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        baselineCallCount += 1
        return Self.passed(cleanupVerified: true)
    }

    func measurePerTestCoverage(artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async -> PerTestCoverageMap? {
        coverage
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        Self.passed(cleanupVerified: true)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        Self.passed(cleanupVerified: true)
    }

    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double, nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        runBatchCallCount += 1
        let verified = runBatchCallCount != unverifiedBatchCall
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, Self.passed(cleanupVerified: verified)) })
    }

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        Issue.record("no schemata token may run in this test")
        return Self.passed(cleanupVerified: true)
    }

    private static func passed(cleanupVerified: Bool) -> TestRunResult {
        TestRunResult(
            status: .passed, summary: nil, command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted pass",
            cleanupVerified: cleanupVerified, cleanupDiagnosis: cleanupVerified ? nil : "injected unverified batch cleanup"
        )
    }
}

private struct LaunchProjectAdapter: ProjectAdapter {
    let buildAdapter: LaunchCountingBuildAdapter
    let testAdapter: CleanupBatchAdapter
    private let schemataBuilder = FakeSchemataAdapter()

    var kind: ProjectKind { .swiftPackageMacOS }
    var build: any BuildAdapter { buildAdapter }
    var test: any TestAdapter { testAdapter }
    var schemataBuild: (any SchemataBuildable)? { schemataBuilder }
    var schemataTest: (any SchemataTestable)? { testAdapter }
}
