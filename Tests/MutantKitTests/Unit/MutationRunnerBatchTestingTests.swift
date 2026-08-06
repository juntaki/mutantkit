import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.testBatchSize`: does
/// the runner build every mutant the ordinary way and then group the ones
/// with a known, narrowed test selection into `runBatch` calls, does a
/// mutant with no known selection still run individually rather than being
/// silently dropped, does a mutant missing from a batch's returned results
/// become `.infrastructureFailure` rather than vanishing, and does a
/// batched mutant's crash confirmation still get its own independent,
/// unbatched rebuild.
@Suite("Mutation runner: batch testing")
struct MutationRunnerBatchTestingTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-batch-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-batch-scratch")
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

    /// Three independent bool-literal mutation sites, one per line — two
    /// will be given a known, narrowed selection (batchable), one will be
    /// left with no attribution at all (must run individually). Each on its
    /// own line deliberately: on one shared line they would all report the
    /// same `point.line`, and a coverage map keyed by file+line could not
    /// tell them apart.
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
        testBatchSize: Int,
        batchOutcomeOverrides: [Int: TestRunStatus] = [:],
        confirmCrashKills: Bool = false
    ) async throws -> (RunReport, SpyBatchAdapter) {
        try writeThreeMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(
                workers: 1,
                confirmCrashKills: confirmCrashKills,
                selectCoveringTests: true,
                testBatchSize: testBatchSize
            )
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 3)
        let points = plan.mutations.sorted { $0.id < $1.id }

        // Points 0 and 1 get a real, narrowed attribution; point 2 gets none
        // at all — the map has nothing to say about its file/line, which
        // `testsCovering` reports as `nil`, the same "unknown" case a real
        // coverage gap produces.
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        // Built with `default:`, not a dictionary literal: all three
        // mutations land in the same file, so a literal keying both points
        // by `.file` directly would collide.
        // Point 2 is present but empty, not absent: absent would make the
        // aggregate coverage map report the line as never executed at all,
        // fast-pathing it to `.noCoverage` before it ever reaches test
        // selection. Present-but-empty is the real shape of "this line was
        // covered, but no individual test's profiling run was uniquely
        // attributed to it" — the case this test means to exercise.
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        coveringTests[points[0].file, default: [:]][points[0].line] = [testA]
        coveringTests[points[1].file, default: [:]][points[1].line] = [testB]
        coveringTests[points[2].file, default: [:]][points[2].line] = []
        let coverage = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let adapter = SpyBatchAdapter(
            perTestCoverage: coverage,
            batchOutcomes: Dictionary(uniqueKeysWithValues: batchOutcomeOverrides.map { (points[$0].id, $1) })
        )
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces
        )
        let report = try await runner.run()
        return (report, adapter)
    }

    @Test("Narrowed mutants are grouped into one batch; the unnarrowed one runs individually")
    func narrowedMutantsAreBatchedUnnarrowedRunsAlone() async throws {
        let (report, adapter) = try await run(testBatchSize: 10)

        #expect(report.results.count == 3)
        #expect(report.integrity.violations.isEmpty)

        let batchCalls = await adapter.runBatchCalls
        #expect(batchCalls.count == 1, "expected exactly one batch call, got \(batchCalls.count)")
        #expect(batchCalls.first?.count == 2, "expected the batch to cover both narrowed mutants")

        let individualCalls = await adapter.individualRunMutantCalls
        #expect(individualCalls.count == 1, "expected exactly one individually-run mutant")
    }

    @Test("A batch size smaller than the batchable count splits into multiple batch calls")
    func batchSizeSplitsIntoMultipleCalls() async throws {
        let (_, adapter) = try await run(testBatchSize: 1)

        let batchCalls = await adapter.runBatchCalls
        #expect(batchCalls.count == 2, "two batchable mutants, batch size 1, expected two batch calls")
        #expect(batchCalls.allSatisfy { $0.count == 1 })
    }

    @Test("A mutant missing from the batch's returned results is infrastructureFailure, not dropped")
    func missingFromBatchResultsIsInfrastructureFailure() async throws {
        // batchOutcomeOverrides intentionally covers only mutant 0 — mutant
        // 1 is batchable but the fake never reports a result for it, the
        // same shape a real batch losing a configuration would produce.
        let (report, _) = try await run(testBatchSize: 10, batchOutcomeOverrides: [0: .passed])

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .survived)
        #expect(sorted[1].outcome == .infrastructureFailure)
    }

    @Test("A batched mutant's crash confirmation still gets its own independent, unbatched rebuild")
    func crashConfirmationStaysIndependentOfTheBatch() async throws {
        let (report, adapter) = try await run(
            testBatchSize: 10,
            batchOutcomeOverrides: [0: .crashed, 1: .passed],
            confirmCrashKills: true
        )

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .killedByCrash)

        // The confirmation rebuild is never routed through runBatch — it is
        // an individual `runMutant` call in its own fresh sandbox, the same
        // guarantee `MutationRunnerIncrementalBuildTests` proves for the
        // incremental-build path.
        let individualCalls = await adapter.individualRunMutantCalls
        #expect(individualCalls.contains(sorted[0].id))
    }

    /// Five independent bool-literal mutation sites, one per line — enough
    /// mutants for `batchSize: 2` to prove real chunking (2, 2, 1) rather
    /// than a coincidental count.
    private func writeFiveMutantProject() throws {
        let url = root.appendingPathComponent("Sources/B.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        struct B {
            var a = true
            var b = true
            var c = true
            var d = true
            var e = true
        }
        """.utf8).write(to: url)
    }

    @Test("batchExecution reports the true batch count, total configurations, and average per batch")
    func batchExecutionSummaryReflectsRealChunking() async throws {
        try writeFiveMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(workers: 1, selectCoveringTests: true, testBatchSize: 2)
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 5)
        let points = plan.mutations.sorted { $0.id < $1.id }

        // Every mutant here gets its own real, narrow attribution — this test
        // means to exercise batch-size chunking arithmetic for genuinely
        // batchable mutants, which an unattributed (nil) mutant is not: see
        // `narrowedMutantsAreBatchedUnnarrowedRunsAlone` for that case.
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        for (index, point) in points.enumerated() {
            let test = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/test\(index)")
            coveringTests[point.file, default: [:]][point.line] = [test]
        }
        let coverage = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let adapter = SpyBatchAdapter(perTestCoverage: coverage, batchOutcomes: [:])
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces
        )
        let report = try await runner.run()

        #expect(report.results.count == 5)
        // 5 ready-to-test mutants, batch size 2: chunks of 2, 2, 1 — three
        // batches, five configurations total, average 5/3.
        let summary = try #require(report.batchExecution)
        #expect(summary.batchCount == 3)
        #expect(summary.totalConfigurations == 5)
        #expect(summary.averageConfigurationsPerBatch == 5.0 / 3.0)

        // One real measured duration per chunk that actually reached
        // `runBatch` — three chunks, three durations, not one per mutant.
        #expect(summary.batchDurations.count == 3)
        #expect(summary.batchDurations.allSatisfy { $0 >= 0 })

        // Every mutant here actually built and was tested (through the
        // batch), so both timings must be recorded.
        for result in report.results {
            let buildDuration = try #require(result.buildDurationSeconds)
            let testDuration = try #require(result.testDurationSeconds)
            #expect(buildDuration >= 0)
            #expect(testDuration >= 0)
        }
    }

    /// Real-world regression, found via a 100-mutant benchmark: a batch that
    /// happened to bundle several mutants with no attributed test (each
    /// falling back to the full suite) alongside a few genuinely narrowed
    /// ones ran for far longer than `batchTimeout` budgeted — enough to
    /// exceed it and mark every mutant in that batch `.flaky`, including the
    /// narrowed ones that would otherwise have classified cleanly and fast.
    /// Unattributed mutants must never share a chunk with each other (or
    /// with narrowed ones): each gets its own, so its own generous
    /// per-mutant timeout budget is never diluted by riding along with
    /// others that also need the full suite.
    @Test("Unattributed mutants never share a batch with each other, even when batchSize allows it")
    func unattributedMutantsAreNeverBundledTogether() async throws {
        try writeFiveMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(workers: 1, selectCoveringTests: true, testBatchSize: 10)
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 5)
        let points = plan.mutations.sorted { $0.id < $1.id }

        // Points 0 and 1 get real, narrow attribution; points 2, 3, and 4 get
        // none at all — three separate mutants that would each fall back to
        // the full suite, the exact shape the real benchmark hit.
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        coveringTests[points[0].file, default: [:]][points[0].line] = [
            TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/test0")
        ]
        coveringTests[points[1].file, default: [:]][points[1].line] = [
            TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/test1")
        ]
        for point in points[2...] {
            coveringTests[point.file, default: [:]][point.line] = []
        }
        let coverage = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let adapter = SpyBatchAdapter(perTestCoverage: coverage, batchOutcomes: [:])
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces
        )
        let report = try await runner.run()

        #expect(report.results.count == 5)
        // testBatchSize is 10 — large enough that a naive sequential chunker
        // would have bundled all 3 unattributed mutants into one chunk
        // together (and even alongside the 2 narrowed ones, in a single
        // chunk of 5). Instead: one chunk of 2 for the narrowed pair, plus
        // three separate chunks of 1 for the unattributed ones — four
        // chunks, never fewer.
        let summary = try #require(report.batchExecution)
        #expect(summary.batchCount == 4)
        #expect(summary.totalConfigurations == 5)

        let batchCalls = await adapter.runBatchCalls
        #expect(batchCalls.count == 1, "only the narrowed pair should ever reach the adapter as a real batch")
        #expect(batchCalls.first?.count == 2)
    }

    @Test("batchExecution is nil when batching is not configured")
    func batchExecutionIsNilWithoutBatching() async throws {
        try writeThreeMutantProject()

        let configuration = Configuration(execution: ExecutionSettings(workers: 1))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: SpyBatchAdapter(perTestCoverage: nil, batchOutcomes: [:]),
            workspaces: workspaces
        )
        let report = try await runner.run()

        #expect(report.batchExecution == nil)
    }

    @Test("A mutant classified .noCoverage from baseline coverage alone never builds, so buildDurationSeconds stays nil")
    func noCoverageMutantNeverBuilds() async throws {
        try writeThreeMutantProject()

        let configuration = Configuration(execution: ExecutionSettings(workers: 1, selectCoveringTests: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 3)
        let points = plan.mutations.sorted { $0.id < $1.id }

        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        // Only points 0 and 2's lines appear in the aggregated coverage map
        // at all — point 1's line is entirely absent from its file's entry,
        // which is the "this file's coverage is known, but this exact line
        // was never touched" case that makes `isKnownUncovered` true and
        // fast-paths the mutant to `.noCoverage` without ever building it.
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        coveringTests[points[0].file, default: [:]][points[0].line] = [testA]
        coveringTests[points[2].file, default: [:]][points[2].line] = [testA]
        let coverage = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let adapter = SpyBatchAdapter(perTestCoverage: coverage, batchOutcomes: [:])
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces
        )
        let report = try await runner.run()

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[1].outcome == .noCoverage)
        #expect(sorted[1].buildDurationSeconds == nil)
        #expect(sorted[1].testDurationSeconds == nil)

        // The other two mutants were actually covered, so they built and
        // tested normally.
        #expect(sorted[0].buildDurationSeconds != nil)
        #expect(sorted[2].buildDurationSeconds != nil)
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: workspace.appendingPathComponent("baseline.xctestrun"),
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash-\(mutation.point.id.rawValue)",
            xctestrunPath: workspace.appendingPathComponent("mutant.xctestrun"),
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private actor SpyBatchAdapter: TestSelecting, BatchTestable {
    private let perTestCoverage: PerTestCoverageMap?
    /// What `runBatch` reports for a given mutant, when scripted; anything
    /// batchable but not present here is silently omitted from the
    /// returned dictionary, simulating a batch that lost a configuration.
    private let batchOutcomes: [MutationID: TestRunStatus]
    private(set) var runBatchCalls: [[MutationID]] = []
    private(set) var individualRunMutantCalls: [MutationID] = []

    init(perTestCoverage: PerTestCoverageMap?, batchOutcomes: [MutationID: TestRunStatus]) {
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
        individualRunMutantCalls.append(point.id)
        // A crash-confirmation rebuild of an already-scripted-crashed mutant
        // confirms it, keeping this suite's crash verdict stable.
        let status = batchOutcomes[point.id] ?? .passed
        return Self.result(status)
    }

    /// Mirrors `XcodeBuildAdapter.runBatch`'s real contract: `MutationRunner`
    /// hands every ready-to-test mutant to the adapter regardless of
    /// whether it was narrowed, and the adapter itself is responsible for
    /// routing an unnarrowed one to an individual run instead of joining
    /// the batch — see that type's doc comment for why an unnarrowed item
    /// cannot be batched safely. A fake that skipped this split would not
    /// be exercising what this suite means to test.
    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double
    ) async -> [MutationID: TestRunResult] {
        let batchable = items.filter { $0.selectedTests?.isEmpty == false }
        let individual = items.filter { $0.selectedTests?.isEmpty != false }

        var results: [MutationID: TestRunResult] = [:]
        for item in individual {
            individualRunMutantCalls.append(item.id)
            results[item.id] = Self.result(batchOutcomes[item.id] ?? .passed)
        }

        guard !batchable.isEmpty else { return results }
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
