import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.incrementalBuild` and
/// `Configuration.execution.testBatchSize` set together — the one
/// combination `MutationRunnerIncrementalBuildTests` and
/// `MutationRunnerBatchTestingTests` cannot exercise independently, since
/// each sets only its own flag.
///
/// The property this suite exists to prove: a worker keeps reusing one
/// sandbox across mutants (real incremental compilation, unblocked) while
/// still getting its mutants tested through `runBatch` (real batching) —
/// which only works if each `.readyToTest` mutant's build gets cloned out
/// to its own independent location before the worker moves on, per
/// `WorkspaceManager.cloneProducts`. `workers: 1` throughout, same reason
/// `MutationRunnerIncrementalBuildTests` gives: it makes sandbox reuse (or
/// its absence) deterministic to assert on.
@Suite("Mutation runner: incremental build + batch testing")
struct MutationRunnerIncrementalBatchTestingTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-incr-batch-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-incr-batch-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// Same shape as `MutationRunnerBatchTestingTests`'s fixture: three
    /// independent bool-literal sites, one per line, two of which will be
    /// given a known narrowed selection (batchable) and one left unnarrowed
    /// (runs individually, same as the unbatched path).
    private func writeThreeMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        struct A {
            var a = true
            var b = false
            var c = true
        }
        """.utf8).write(to: url)
    }

    private func run(
        batchOutcomeOverrides: [Int: TestRunStatus] = [:],
        retestKilledMutants: Bool = false,
        failCloneForPointIndex: Int? = nil
    ) async throws -> (
        report: RunReport, build: SpyIncrementalBuildAdapter, test: SpyIncrementalBatchAdapter,
        points: [MutationPoint], log: CallLog
    ) {
        try writeThreeMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(
                workers: 1,
                retestKilledMutants: retestKilledMutants,
                selectCoveringTests: true,
                incrementalBuild: true,
                testBatchSize: 10
            )
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 3)
        let points = plan.mutations.sorted { $0.id < $1.id }

        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        coveringTests[points[0].file, default: [:]][points[0].line] = [testA]
        coveringTests[points[1].file, default: [:]][points[1].line] = [testB]
        coveringTests[points[2].file, default: [:]][points[2].line] = []
        let coverage = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let log = CallLog()
        let build = SpyIncrementalBuildAdapter(
            log: log,
            brokenProductsDirectoryFor: failCloneForPointIndex.map { points[$0].id.rawValue }
        )
        let test = SpyIncrementalBatchAdapter(
            log: log,
            buildSpy: build,
            perTestCoverage: coverage,
            batchOutcomes: Dictionary(uniqueKeysWithValues: batchOutcomeOverrides.map { (points[$0].id, $1) })
        )
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: build,
            test: test,
            workspaces: workspaces
        )
        let report = try await runner.run()
        return (report, build, test, points, log)
    }

    @Test("Mutants build in the same reused sandbox and are still tested through runBatch together")
    func sameSandboxBuildStillBatchesTests() async throws {
        let (report, build, test, _, _) = try await run()

        #expect(report.results.count == 3)
        #expect(report.integrity.violations.isEmpty)

        let buildWorkspaces = await build.buildMutantCalls.map(\.workspace)
        #expect(buildWorkspaces.count == 3)
        #expect(Set(buildWorkspaces).count == 1, "expected one shared, reused sandbox, got \(buildWorkspaces)")

        let batchCalls = await test.runBatchCalls
        #expect(batchCalls.count == 1, "expected exactly one batch call covering both narrowed mutants")
        #expect(batchCalls.first?.count == 2)
    }

    @Test("No batch call happens before every build on the shared worker has finished")
    func batchingWaitsForAllBuildsOnTheWorker() async throws {
        // The concrete guard against a future change reintroducing
        // per-mutant build-then-test interleaving, which would corrupt the
        // fixed, reused DerivedData path the whole design depends on (see
        // `WorkspaceManager.cloneProducts`'s doc comment).
        let (_, _, _, _, log) = try await run()

        let events = await log.events
        let lastBuildIndex = events.lastIndex { if case .build = $0 { true } else { false } }
        let firstBatchIndex = events.firstIndex { if case .batch = $0 { true } else { false } }
        let lastBuild = try #require(lastBuildIndex)
        let firstBatch = try #require(firstBatchIndex)
        #expect(lastBuild < firstBatch, "a batch call happened before this worker's builds all finished: \(events)")
    }

    @Test("A killed mutant's confirmation retest runs against its clone, not the reused worker sandbox")
    func confirmKillRetestsAgainstTheCloneNotTheWorkerSandbox() async throws {
        let (report, build, test, points, _) = try await run(
            batchOutcomeOverrides: [0: .failed, 1: .passed], retestKilledMutants: true
        )

        let killedResult = try #require(report.results.first { $0.id == points[0].id })
        #expect(killedResult.outcome == .killedByAssertion)

        let workerSandboxes = Set(await build.buildMutantCalls.map(\.workspace))
        #expect(workerSandboxes.count == 1)
        let workerSandbox = try #require(workerSandboxes.first)

        let retestWorkspaces = await test.individualRunMutantCalls
            .filter { $0.id == points[0].id }
            .map(\.workspace)
        #expect(!retestWorkspaces.isEmpty, "expected at least one confirmation retest for the killed mutant")
        #expect(
            retestWorkspaces.allSatisfy { $0 != workerSandbox },
            "confirmKill retested against the worker's own sandbox (\(workerSandbox)) instead of the clone"
        )
    }

    @Test("A mutant missing from the batch's returned results is still infrastructureFailure, not dropped")
    func missingFromBatchResultsIsInfrastructureFailure() async throws {
        let (report, _, _, points, _) = try await run(batchOutcomeOverrides: [0: .passed])

        let sorted = report.results.sorted { $0.id < $1.id }
        let missing = try #require(sorted.first { $0.id == points[1].id })
        #expect(missing.outcome == .infrastructureFailure)
    }

    @Test("A cloneProducts failure for one mutant doesn't stall or lose the rest of the worker's queue")
    func cloneFailureDoesNotStallTheWorker() async throws {
        let (report, _, _, points, _) = try await run(
            batchOutcomeOverrides: [1: .passed], failCloneForPointIndex: 0
        )

        #expect(report.results.count == 3, "all three mutants must still be reported, none lost")
        let sorted = report.results.sorted { $0.id < $1.id }
        let broken = try #require(sorted.first { $0.id == points[0].id })
        #expect(broken.outcome == .infrastructureFailure)

        // The other two mutants — one batched, one individual — still went
        // through normally despite point 0's clone failing.
        #expect(sorted.contains { $0.id == points[1].id && $0.outcome == .survived })
        #expect(sorted.contains { $0.id == points[2].id })
    }

    /// The sandbox-lifetime bug this suite exists to pin: found via
    /// `xcresulttool` inspection of a real 100-mutant benchmark run whose
    /// `execution.testBatchSize` and `execution.incrementalBuild` were both
    /// set, `workers: 1`. Several tests that resolve a fixture through a
    /// source-relative path baked in at compile time (`URL(fileURLWithPath:
    /// #filePath)`, an ordinary pattern also seen in real-world project test
    /// suites) were silently reported
    /// `Skipped` rather than run for real, because
    /// `runIncrementalBuildWorker` destroyed its own persistent sandbox the
    /// moment its build queue drained — which, with one worker, happens
    /// before `testAndFinish`'s batch test call ever runs at all — deleting
    /// the fixture out from under the cloned-products test that still
    /// needed it.
    ///
    /// `SpyIncrementalBatchAdapter.runBatch` checks, at the moment it is
    /// called, whether the worker's own persistent sandbox (a real,
    /// deterministically-named directory under `scratchRoot` — see
    /// `WorkspaceManager.directoryName(for:)`) still exists on disk. Before
    /// the fix this is `false`: the worker (there is only one) has already
    /// destroyed its sandbox before `testAndFinish` is even reached. After
    /// the fix it must be `true`.
    @Test("A worker's own persistent sandbox is still alive when the batch test call runs, and is destroyed only after")
    func workerSandboxOutlivesTheBatchTestCall() async throws {
        let (_, build, _, _, log) = try await run(batchOutcomeOverrides: [0: .passed, 1: .passed])

        let workerSandbox = try #require(await build.buildMutantCalls.map(\.workspace).first)
        #expect(
            FileManager.default.fileExists(atPath: workerSandbox.path) == false,
            "the worker's sandbox must be torn down again once the run has fully finished, not leaked"
        )

        let events = await log.events
        let sawSandboxAliveDuringBatch = events.contains { event in
            if case let .batchObservedWorkerSandboxAlive(alive) = event { return alive }
            return false
        }
        #expect(
            sawSandboxAliveDuringBatch,
            "the worker's own sandbox must still exist when the batch test call runs, not be destroyed before it: \(events)"
        )
    }
}

// MARK: - Fakes

/// Records build and batch-test calls in one shared, ordered timeline —
/// what `MutationRunnerBatchTestingTests`/`MutationRunnerIncrementalBuildTests`
/// each track independently in their own spies, but this suite needs
/// interleaved to assert ordering between the two.
private actor CallLog {
    enum Event: Equatable {
        case build(String)
        case batch([String])
        /// Recorded from inside `SpyIncrementalBatchAdapter.runBatch`: whether
        /// the worker's own persistent sandbox still existed on disk at the
        /// moment the batch test call ran — the direct, on-disk check for the
        /// sandbox-lifetime bug this suite pins down.
        case batchObservedWorkerSandboxAlive(Bool)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

private actor SpyIncrementalBuildAdapter: BuildAdapter {
    private let log: CallLog
    /// The one mutation ID, if any, whose reported `productsDirectory`
    /// points at a path that does not exist — forcing a real
    /// `WorkspaceManager.cloneProducts` failure downstream, rather than
    /// mocking the failure directly.
    private let brokenProductsDirectoryFor: String?
    private(set) var buildMutantCalls: [(workspace: URL, mutationID: String)] = []

    init(log: CallLog, brokenProductsDirectoryFor: String?) {
        self.log = log
        self.brokenProductsDirectoryFor = brokenProductsDirectoryFor
    }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: workspace.appendingPathComponent("baseline.xctestrun"),
            command: CommandRecord(executable: "xcodebuild", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        let mutationID = mutation.point.id.rawValue
        buildMutantCalls.append((workspace, mutationID))
        await log.record(.build(mutationID))

        let productsDirectory = mutationID == brokenProductsDirectoryFor
            ? workspace.appendingPathComponent("does-not-exist-\(mutationID)")
            : workspace
        return BuildArtifact(
            productsDirectory: productsDirectory,
            productHash: "mutant-hash-\(mutationID)",
            xctestrunPath: workspace.appendingPathComponent("mutant.xctestrun"),
            command: CommandRecord(executable: "xcodebuild", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private actor SpyIncrementalBatchAdapter: TestSelecting, BatchTestable {
    private let log: CallLog
    /// The build spy, read (never written) only to look up the worker's
    /// own persistent sandbox path so `runBatch` can check whether it is
    /// still alive on disk at batch time.
    private let buildSpy: SpyIncrementalBuildAdapter
    private let perTestCoverage: PerTestCoverageMap?
    private let batchOutcomes: [MutationID: TestRunStatus]
    private(set) var runBatchCalls: [[MutationID]] = []
    private(set) var individualRunMutantCalls: [(id: MutationID, workspace: URL)] = []

    init(
        log: CallLog,
        buildSpy: SpyIncrementalBuildAdapter,
        perTestCoverage: PerTestCoverageMap?,
        batchOutcomes: [MutationID: TestRunStatus]
    ) {
        self.log = log
        self.buildSpy = buildSpy
        self.perTestCoverage = perTestCoverage
        self.batchOutcomes = batchOutcomes
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        perTestCoverage
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
        individualRunMutantCalls.append((point.id, workspace))
        let status = batchOutcomes[point.id] ?? .passed
        return Self.result(status)
    }

    /// Same routing contract `MutationRunnerBatchTestingTests`'s spy
    /// documents: an unnarrowed item is routed to an individual run rather
    /// than joining the batch, mirroring `XcodeBuildAdapter.runBatch`'s
    /// real behavior.
    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double
    ) async -> [MutationID: TestRunResult] {
        // The direct, on-disk check for the sandbox-lifetime bug: by this
        // point (batching only starts once every build on every worker has
        // finished — see `batchingWaitsForAllBuildsOnTheWorker`), the build
        // spy's calls are fully recorded, so the worker's own persistent
        // sandbox path is known. It must still exist right now.
        if let workerSandbox = await buildSpy.buildMutantCalls.map(\.workspace).first {
            let alive = FileManager.default.fileExists(atPath: workerSandbox.path)
            await log.record(.batchObservedWorkerSandboxAlive(alive))
        }

        let batchable = items.filter { $0.selectedTests?.isEmpty == false }
        let individual = items.filter { $0.selectedTests?.isEmpty != false }

        var results: [MutationID: TestRunResult] = [:]
        for item in individual {
            individualRunMutantCalls.append((item.id, workspace))
            results[item.id] = Self.result(batchOutcomes[item.id] ?? .passed)
        }

        guard !batchable.isEmpty else { return results }
        await log.record(.batch(batchable.map { $0.id.rawValue }))
        runBatchCalls.append(batchable.map(\.id))
        for item in batchable {
            guard let status = batchOutcomes[item.id] else { continue }
            results[item.id] = Self.result(status)
        }
        return results
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "xcodebuild", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)"
        )
    }
}
