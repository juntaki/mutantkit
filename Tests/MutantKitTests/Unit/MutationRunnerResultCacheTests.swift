import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `MutationResultCache` wiring inside
/// `MutationRunner.run()`: a mutant whose MutationID was evaluated against
/// an identical execution context is reused without rebuilding or
/// retesting; a mutant that is evaluated fresh is stored back for the
/// next run.
///
/// The cache stores only reportable, integrity-safe verdicts —
/// infrastructure failures and other environmental state are never cached.
/// Checkpoint hits take priority over cache hits, so a mutant already
/// recorded in a checkpoint is never also served from the cache.
@Suite("Mutation runner: cross-run result cache")
struct MutationRunnerResultCacheTests {
    private let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-result-cache-project-\(UUID().uuidString)")
    private let scratchRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-result-cache-scratch-\(UUID().uuidString)")
    private let cacheRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-result-cache-store-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil,
        swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )
    private let digest = "test-result-cache-digest"

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    private func makeRunner(
        adapter: CountingTestAdapter,
        plan: MutationPlan,
        cache: MutationResultCache? = nil,
        digest: String? = nil
    ) throws -> MutationRunner {
        let configuration = Configuration()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        return MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            resultCache: cache,
            resultCacheDigest: digest
        )
    }

    @Test("A cold run evaluates every mutant and stores results in the cache")
    func coldRunEvaluatesAndStores() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)
        let adapter = CountingTestAdapter()
        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        let runner = try makeRunner(adapter: adapter, plan: plan, cache: cache, digest: digest)

        let report = try await runner.run()

        // The mutant was evaluated (buildMutant + runMutant called once).
        let runCalls = await adapter.runMutantCalls
        #expect(runCalls == 1, "cold run must evaluate the mutant")

        // The freshly-evaluated result is recorded as fresh, not as a reuse.
        let fresh = try #require(report.results.first)
        #expect(fresh.origin == .fresh, "a freshly evaluated mutant is not a checkpoint or cache reuse")

        // The result was stored in the cache under the right key.
        let cached = await cache.load(
            MutationResultCache.Key(mutationID: point.id, contextDigest: digest),
            point: point, planID: plan.planID, workUnitID: plan.workUnitID
        )
        #expect(cached != nil, "cold run must store the result in the cache")
        #expect(cached?.origin == .crossRunCache, "a stored entry is a cross-run reuse when read back")
    }

    @Test("A warm run skips evaluation entirely for cached mutants")
    func warmRunSkipsEvaluation() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)

        // Pre-seed the cache with a known verdict's observations — `store`
        // re-verifies and rejects anything that does not prove source
        // application, so a phantom verdict would never be stored and
        // never be served.
        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        await cache.store(
            makeObservations(point: point, outcome: .killedByAssertion, planID: plan.planID, workUnitID: plan.workUnitID),
            durationSeconds: 2,
            for: MutationResultCache.Key(mutationID: point.id, contextDigest: digest)
        )

        let adapter = CountingTestAdapter()
        let runner = try makeRunner(adapter: adapter, plan: plan, cache: cache, digest: digest)

        let report = try await runner.run()

        // The mutant was NOT evaluated — the cache served the verdict.
        let runCalls = await adapter.runMutantCalls
        let buildCalls = await adapter.buildMutantCalls
        #expect(runCalls == 0, "warm run must not call runMutant")
        #expect(buildCalls == 0, "warm run must not call buildMutant")

        // The cached verdict appears in the report.
        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
        #expect(result.origin == .crossRunCache, "a cache hit must read as a cross-run reuse, not a checkpoint resume")
    }

    @Test("A run with no digest always evaluates, even when a cache is supplied")
    func noDigestAlwaysEvaluates() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let adapter = CountingTestAdapter()
        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        let runner = try makeRunner(adapter: adapter, plan: plan, cache: cache, digest: nil)

        _ = try await runner.run()

        let runCalls = await adapter.runMutantCalls
        #expect(runCalls == 1, "no digest means the cache is inert")
    }

    @Test("A run with no cache supplied evaluates fresh even when a matching entry already exists")
    func noCacheSuppliedIgnoresExistingEntry() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)

        // Pre-seed the cache with a valid, matching verdict for this exact
        // mutant/digest pair — the same state a warm run would hit against.
        // `--no-resume` (RunCommand.swift) responds to this by not
        // constructing/passing a `MutationResultCache` into `MutationRunner`
        // at all for that run, which this test simulates directly: the
        // pre-existing on-disk entry below must never be consulted, even
        // though it would otherwise be a hit.
        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        await cache.store(
            makeObservations(point: point, outcome: .survived, planID: plan.planID, workUnitID: plan.workUnitID),
            durationSeconds: 2,
            for: MutationResultCache.Key(mutationID: point.id, contextDigest: digest)
        )

        // Simulate `--no-resume`: neither a cache nor a digest reaches the
        // runner, exactly as RunCommand now wires it when the flag is set.
        let adapter = CountingTestAdapter()
        let runner = try makeRunner(adapter: adapter, plan: plan)

        let report = try await runner.run()

        let runCalls = await adapter.runMutantCalls
        #expect(runCalls == 1, "no-resume must re-evaluate rather than reuse a pre-existing cache entry")
        let result = try #require(report.results.first)
        #expect(result.origin == .fresh, "no-resume must not serve the pre-existing cache entry")
    }

    @Test("Checkpoint hits take priority over cache hits")
    func checkpointPriorityOverCache() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)

        // Set up a checkpoint with one verdict, and a cache with a different
        // verdict for the same mutant. The checkpoint's verdict must win.
        let checkpointRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-checkpoint-\(UUID().uuidString)")
        let checkpointURL = checkpointRoot.appendingPathComponent("checkpoint.jsonl")
        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        await cache.store(
            makeObservations(point: point, outcome: .killedByAssertion, planID: plan.planID, workUnitID: plan.workUnitID),
            durationSeconds: 2,
            for: MutationResultCache.Key(mutationID: point.id, contextDigest: digest)
        )
        let checkpoints = CheckpointStore(url: checkpointURL, policy: .permissive)
        try await checkpoints.record(
            makeObservations(point: point, outcome: .survived, planID: plan.planID, workUnitID: plan.workUnitID), durationSeconds: 2
        )

        let adapter = CountingTestAdapter()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            checkpoints: checkpoints,
            resultCache: cache,
            resultCacheDigest: digest
        )

        let report = try await runner.run()

        // Neither adapter method was called — both stores hit.
        let buildCalls = await adapter.buildMutantCalls
        let runCalls = await adapter.runMutantCalls
        #expect(buildCalls == 0)
        #expect(runCalls == 0)

        // The checkpoint's verdict won.
        let result = try #require(report.results.first)
        #expect(result.outcome == .survived)
        #expect(result.origin == .checkpoint, "a checkpoint resume is distinct from a cross-run cache hit")
    }

    @Test("Infrastructure failures are evaluated fresh and not served from cache")
    func infrastructureFailuresNotCached() async throws {
        try writeSingleMutantProject()
        let configuration = Configuration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let point = try #require(plan.mutations.first)

        // Pre-seed the cache with an infrastructure failure. The cache's
        // store() filters this out, but even if it didn't, load() should
        // not serve it — an infrastructure failure is environmental, not a
        // reusable verdict.
        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        await cache.store(
            makeObservations(point: point, outcome: .infrastructureFailure, planID: plan.planID, workUnitID: plan.workUnitID),
            durationSeconds: 2,
            for: MutationResultCache.Key(mutationID: point.id, contextDigest: digest)
        )

        let adapter = CountingTestAdapter()
        let runner = try makeRunner(adapter: adapter, plan: plan, cache: cache, digest: digest)

        _ = try await runner.run()

        // The mutant must be re-evaluated, because the infra failure was
        // not cached (store() rejects it).
        let runCalls = await adapter.runMutantCalls
        #expect(runCalls == 1, "infra failure must not short-circuit evaluation")
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "baseline-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "mutant-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private actor CountingTestAdapter: TestAdapter {
    private(set) var buildMutantCalls = 0
    private(set) var runMutantCalls = 0

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        runMutantCalls += 1
        return Self.result(.failed)
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)"
        )
    }
}
