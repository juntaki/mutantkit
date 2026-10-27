import ArgumentParser
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import Reporting
import SwiftFrontend
import Testing

/// An abort must leave nothing from the aborted run that a resume,
/// `--replay`, the next run or a reader can score or trust.
///
/// - Evidence another worker persisted while the uncontained process was
///   still alive (before that process's close-out tripped the monitor) is
///   discarded: checkpoint records and result-cache entries.
/// - A baseline that tripped the monitor never goes on to measure coverage,
///   and coverage measured in a tripped run is never cached.
/// - The CLI exits 1 with the diagnosis on stderr and publishes nothing:
///   no report file, no history entry, no manifest refresh.
/// - The CLI's containment scope covers everything `run` launches, not
///   only the part after simulator-pool provisioning.
@Suite("Run abort: nothing from the aborted run outlives it", .subprocessExclusive)
struct RunAbortEvidenceDiscardTests {
    // MARK: - Checkpoint and result cache

    @Test("Evidence a concurrent worker persisted before the trip is discarded from checkpoint and result cache")
    func concurrentWorkerEvidenceIsDiscarded() async throws {
        let fixture = try await DiscardFixture.make(workers: 2)
        let checkpointURL = fixture.scratch.appendingPathComponent("checkpoint.jsonl")
        let cacheRoot = fixture.scratch.appendingPathComponent("result-cache")
        let test = ConcurrentTaintAdapter()

        await #expect(throws: RunAbortedError.self) {
            _ = try await MutationRunner(
                plan: fixture.plan, configuration: fixture.configuration, projectRoot: fixture.root,
                build: StubBuildAdapter(), test: test,
                workspaces: try WorkspaceManager(projectRoot: fixture.root, scratchRoot: fixture.scratch),
                checkpoints: CheckpointStore(url: checkpointURL, policy: fixture.policy),
                resultCache: MutationResultCache(root: cacheRoot, policy: fixture.policy), resultCacheDigest: "digest"
            ).run()
        }
        #expect(await test.fastRunsFinished >= 1, "the scenario needs a worker that finished while the slow run was alive")

        let resumable = try await CheckpointStore(url: checkpointURL, policy: fixture.policy).loadAll(plan: fixture.plan)
        #expect(resumable.isEmpty, "a resume must not score evidence from the aborted run: \(resumable.map(\.outcome))")
        let cache = MutationResultCache(root: cacheRoot, policy: fixture.policy)
        for point in fixture.plan.mutations {
            let hit = await cache.load(
                MutationResultCache.Key(mutationID: point.id, contextDigest: "digest"),
                point: point, planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID
            )
            #expect(hit == nil, "the next run must not reuse \(point.id) from the aborted run")
        }
    }

    @Test("Discarding an aborted session's checkpoint records keeps the records earlier sessions left")
    func checkpointDiscardKeepsEarlierSessions() async throws {
        let earlierPoint = try makeAnchoredPoint(file: "Sources/A.swift")
        let abortedPoint = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [earlierPoint, abortedPoint])
        let url = makeTempDir(prefix: "mutantkit-abort-checkpoint").appendingPathComponent("checkpoint.jsonl")

        try await CheckpointStore(url: url, policy: .permissive)
            .record(
                makeObservations(point: earlierPoint, outcome: .killedByAssertion, workUnitID: plan.workUnitID), durationSeconds: 1
            )
        let aborted = CheckpointStore(url: url, policy: .permissive)
        try await aborted.record(
            makeObservations(point: abortedPoint, outcome: .survived, workUnitID: plan.workUnitID), durationSeconds: 1
        )
        let beforeDiscard = try await CheckpointStore(url: url, policy: .permissive).loadAll(plan: plan)
        #expect(beforeDiscard.count == 2, "control: both sessions' records load before the discard")
        await aborted.discardRecordsFromThisSession()

        let resumable = try await CheckpointStore(url: url, policy: .permissive).loadAll(plan: plan)
        #expect(resumable.map(\.id) == [earlierPoint.id])
    }

    // MARK: - Baseline coverage

    @Test("Isolated: a baseline that tripped the monitor measures no coverage and caches none")
    func isolatedBaselineTripSkipsCoverage() async throws {
        let fixture = try await DiscardFixture.make(workers: 1, selectCoveringTests: true)
        let test = CoverageSelectingAdapter(baselineVerified: false, coverageTripsMonitor: false)
        let cache = CoverageProfileCache(root: fixture.scratch.appendingPathComponent("coverage"))
        let key = CoverageProfileCache.Key(contextDigest: "coverage-digest")

        await #expect(throws: RunAbortedError.self) {
            _ = try await fixture.runner(test: test, coverageCache: cache, coverageCacheKey: key).run()
        }
        #expect(await test.measureCalls == 0, "no new process may be launched after the baseline tripped the monitor")
        #expect(await cache.load(key) == nil)
    }

    @Test("Isolated: coverage measured by a pass that tripped the monitor is never cached")
    func isolatedCoverageTripIsNotCached() async throws {
        let fixture = try await DiscardFixture.make(workers: 1, selectCoveringTests: true)
        let test = CoverageSelectingAdapter(baselineVerified: true, coverageTripsMonitor: true)
        let cache = CoverageProfileCache(root: fixture.scratch.appendingPathComponent("coverage"))
        let key = CoverageProfileCache.Key(contextDigest: "coverage-digest")

        await #expect(throws: RunAbortedError.self) {
            _ = try await fixture.runner(test: test, coverageCache: cache, coverageCacheKey: key).run()
        }
        #expect(await test.measureCalls == 1)
        #expect(await cache.load(key) == nil, "the next run would reuse attribution taken while a stray was alive")
    }

    @Test("Hybrid: a shared baseline that tripped the monitor measures no coverage and caches none")
    func hybridSharedBaselineTripSkipsCoverage() async throws {
        let fixture = try await DiscardFixture.make(workers: 1, selectCoveringTests: true)
        let test = CoverageSelectingAdapter(baselineVerified: false, coverageTripsMonitor: false)
        let cache = CoverageProfileCache(root: fixture.scratch.appendingPathComponent("coverage"))
        let key = CoverageProfileCache.Key(contextDigest: "coverage-digest")
        let context = HybridExecutionEngine.Context(
            plan: fixture.plan, configuration: fixture.configuration, projectRoot: fixture.root,
            adapter: CoverageProjectAdapter(testAdapter: test), testAdapter: test, toolchain: makeToolchain(),
            coverageCache: cache, coverageCacheKey: key
        )

        await #expect(throws: RunAbortedError.self) {
            _ = try await HybridExecutionEngine.runHybrid(
                context: context,
                classification: HybridExecutionEngine.SchemataClassification(
                    programs: [], embeddedIDs: [], sources: [:], plannerFallbackReasons: [:]
                ),
                workspaces: try WorkspaceManager(projectRoot: fixture.root, scratchRoot: fixture.scratch),
                schemataWorkspaces: try WorkspaceManager(
                    projectRoot: fixture.root, scratchRoot: fixture.scratch.appendingPathComponent("schemata")
                ),
                startedAt: Date()
            )
        }
        #expect(await test.measureCalls == 0)
        #expect(await cache.load(key) == nil)
        #expect(await test.mutantCalls == 0)
    }

    // MARK: - CLI

    @Test("CLI: an abort exits 1 with the diagnosis on stderr and writes no report, history or manifest refresh")
    func cliAbortPublishesNothing() async throws {
        let scenario = try CLIScenario()
        let stderr = TextBox()
        let refreshed = FlagBox()

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await RunCommand.failClosedOnAbort(stderr: { stderr.append($0) }, {
                RunContainmentMonitor.current?.recordUnverifiedCleanup("injected: pid 42")
                try await scenario.publish { refreshed.set() }
            })
        }
        #expect(stderr.text.hasPrefix("Error: Run aborted: injected: pid 42"), "stderr: \(stderr.text)")
        #expect(!FileManager.default.fileExists(atPath: scenario.output.path), "--output must not be written")
        #expect(!FileManager.default.fileExists(atPath: scenario.runDirectory.appendingPathComponent("report.html").path))
        #expect(!FileManager.default.fileExists(atPath: scenario.runDirectory.appendingPathComponent("history").path))
        #expect(!refreshed.isSet, "the manifest must not be refreshed")
    }

    @Test("CLI control: without a trip the same publication writes the report, history and manifest")
    func cliControlPublishes() async throws {
        let scenario = try CLIScenario()
        let refreshed = FlagBox()

        try? await RunCommand.failClosedOnAbort {
            try await scenario.publish { refreshed.set() }
        }
        #expect(FileManager.default.fileExists(atPath: scenario.output.path))
        #expect(FileManager.default.fileExists(atPath: scenario.runDirectory.appendingPathComponent("report.html").path))
        #expect(FileManager.default.fileExists(atPath: scenario.runDirectory.appendingPathComponent("history").path))
        #expect(refreshed.isSet)
    }

    @Test("CLI: run() opens the containment scope before it resolves adapters, prepares simulators or provisions a pool")
    func cliScopeCoversTheWholeRun() throws {
        typealias Support = V2InvariantsAuditRegressionSupport
        let text = try Support.read("CLI/Commands/RunCommand.swift")
        let body = try #require(Support.span(in: text, startMarker: "    func run() async throws {", endLinePrefix: "    }"))
        let statements = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        #expect(
            statements.dropFirst().first?.hasPrefix("try await Self.failClosedOnAbort") == true,
            "run()'s first statement must open the scope: \(statements.prefix(3))"
        )
        for launcher in ["resolveAdapterAndLayout", "prepareSimulatorForRun", "provisionSimulatorWorkerPoolIfNeeded"] {
            #expect(!body.contains(launcher), "\(launcher) must run inside the scope, not in run() before it")
        }
    }
}

// MARK: - Fixtures

private func makeTempDir(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct DiscardFixture {
    let root: URL
    let scratch: URL
    let configuration: Configuration
    let plan: MutationPlan

    var policy: MutationVerdictVerifier.VerdictVerificationPolicy {
        MutationVerdictVerifier.VerdictVerificationPolicy(configuration.execution)
    }

    static func make(workers: Int, selectCoveringTests: Bool = false) async throws -> DiscardFixture {
        let root = makeTempDir(prefix: "mutantkit-abort-discard-project")
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var enabled = true; var other = true }".utf8).write(to: url)
        let configuration = Configuration(execution: ExecutionSettings(
            workers: workers, retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false,
            selectCoveringTests: selectCoveringTests
        ))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: makeToolchain(), diffScope: nil
        )
        #expect(plan.mutations.count >= 2)
        return DiscardFixture(
            root: root, scratch: makeTempDir(prefix: "mutantkit-abort-discard-scratch"), configuration: configuration, plan: plan
        )
    }

    func runner(
        test: any TestAdapter, coverageCache: CoverageProfileCache, coverageCacheKey: CoverageProfileCache.Key
    ) throws -> MutationRunner {
        MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root, build: StubBuildAdapter(), test: test,
            workspaces: try WorkspaceManager(projectRoot: root, scratchRoot: scratch),
            coverageCache: coverageCache, coverageCacheKey: coverageCacheKey
        )
    }
}

private struct CLIScenario {
    let command: RunCommand
    let report: RunReport
    let settings: Configuration
    let runDirectory: URL
    let output: URL

    init() throws {
        let dir = makeTempDir(prefix: "mutantkit-abort-cli")
        runDirectory = dir.appendingPathComponent(".mutantkit")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        output = dir.appendingPathComponent("out.json")
        command = try RunCommand.parse(["--output", output.path, "--project-root", dir.path])
        report = makeReport(plan: makePlan(mutations: []), results: [])
        var settings = Configuration()
        settings.reports = [.json, .html]
        self.settings = settings
    }

    func publish(refreshManifest: () -> Void) async throws {
        try await command.publish(
            report, stop: nil, checkpointURL: runDirectory.appendingPathComponent("checkpoint.jsonl"),
            settings: settings, runDirectory: runDirectory, refreshManifest: refreshManifest
        )
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String { lock.withLock { value } }
    func append(_ more: String) { lock.withLock { value += more } }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private struct StubBuildAdapter: BuildAdapter {
    private static let counter = CallCounter()

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        artifact(hash: "baseline-hash", in: workspace)
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        artifact(hash: "mutant-hash-\(Self.counter.next())", in: workspace)
    }

    private func artifact(hash: String, in workspace: URL) -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: hash, xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private func scriptedRun(_ status: TestRunStatus, verified: Bool) -> TestRunResult {
    TestRunResult(
        status: status,
        summary: status == .failed
            ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
            : nil,
        command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
        resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)",
        cleanupVerified: verified, cleanupDiagnosis: verified ? nil : "injected unverified cleanup"
    )
}

/// The first mutant run stays alive for 1.5 s and then reports an
/// unverified cleanup. Every other run fails (a kill) at once, so with two
/// workers a second mutant is finalized, and persisted, while the first
/// run's process is still alive.
private actor ConcurrentTaintAdapter: TestAdapter {
    private var calls = 0
    private(set) var fastRunsFinished = 0

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        scriptedRun(.passed, verified: true)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        calls += 1
        if calls == 1 {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return scriptedRun(.passed, verified: false)
        }
        fastRunsFinished += 1
        return scriptedRun(.failed, verified: true)
    }
}

/// A `TestSelecting` adapter for the baseline-coverage rows. Also
/// `SchemataTestable`, only so the hybrid engine's capability guard
/// accepts it; no token is ever run.
private actor CoverageSelectingAdapter: TestSelecting, SchemataTestable {
    private let baselineVerified: Bool
    private let coverageTripsMonitor: Bool
    private(set) var measureCalls = 0
    private(set) var mutantCalls = 0

    init(baselineVerified: Bool, coverageTripsMonitor: Bool) {
        self.baselineVerified = baselineVerified
        self.coverageTripsMonitor = coverageTripsMonitor
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        scriptedRun(.passed, verified: baselineVerified)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        mutantCalls += 1
        return scriptedRun(.failed, verified: true)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        mutantCalls += 1
        return scriptedRun(.failed, verified: true)
    }

    func measurePerTestCoverage(artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async -> PerTestCoverageMap? {
        measureCalls += 1
        if coverageTripsMonitor {
            // What `ProcessSupervisor.run` does for the coverage pass's own
            // process when its post-SIGKILL cleanup cannot be verified.
            RunContainmentMonitor.current?.recordUnverifiedCleanup("injected: coverage pass")
        }
        let test = TestIdentifier(target: "ATests", qualifiedName: "ATests/testA")
        return PerTestCoverageMap(coveringTests: ["Sources/A.swift": [1: [test]]], source: "test")
    }

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        Issue.record("no schemata token may run in this test")
        return scriptedRun(.infrastructureFailure, verified: true)
    }
}

private struct CoverageProjectAdapter: ProjectAdapter {
    let testAdapter: CoverageSelectingAdapter
    private let schemataBuilder = FakeSchemataAdapter()

    var kind: ProjectKind { .swiftPackageMacOS }
    var build: any BuildAdapter { StubBuildAdapter() }
    var test: any TestAdapter { testAdapter }
    var schemataBuild: (any SchemataBuildable)? { schemataBuilder }
    var schemataTest: (any SchemataTestable)? { testAdapter }
}
