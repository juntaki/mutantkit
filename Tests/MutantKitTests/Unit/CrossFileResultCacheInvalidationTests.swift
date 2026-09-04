@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Competitive-proof corpus C2: `MutationResultCache`'s own doc comment
/// (`Sources/MutationExecution/MutationResultCache.swift`) claims its
/// per-context identity is "a function of the bytes of every non-ignored
/// file in the worktree and of nothing else" — computed by
/// `RunContextProbe.computeContextDigest`, a whole-worktree content digest,
/// not a per-mutated-file one. This is the end-to-end proof of that claim
/// against the exact scenario a path-only or single-file-only cache key
/// would get wrong: `A.swift` calls `dependency()`, defined in a separate
/// `B.swift`; `A.swift` and its own mutation site never change, but
/// `B.swift`'s behavior does, and a real build/test run of `A.swift`'s own
/// mutant can legitimately depend on it.
///
/// `RunContextProbeContentIdentityTests.testTrackedNonSourceChangeStillMissesConservatively`
/// already proves the digest itself moves for *any* tracked file (even
/// `README.md`, deliberately not a build input) at the `RunContextProbe`
/// level alone; `MutationRunnerResultCacheTests` already proves the
/// runner+cache wiring honors whatever digest it is given, using one
/// hand-supplied literal digest string throughout. Neither composes them:
/// this test is the one place a real two-file fixture, a real git-backed
/// digest computed from actual file content, and a real `MutationRunner`
/// run are all exercised together, so a regression that narrowed the
/// digest's scope (e.g. back to a per-mutant or per-file key) would be
/// caught here even though it would sail through both of those in
/// isolation.
///
/// Real `git` subprocess calls throughout (`GitFixture`,
/// `RunContextProbe.computeContextDigest`'s default `ProcessRunner`) —
/// `.subprocessExclusive` keeps this from overlapping any other real-
/// subprocess test in the binary.
@Suite(
    "Cross-file cache invalidation: a change to an unmutated dependency file must invalidate the cache",
    .subprocessExclusive
)
struct CrossFileResultCacheInvalidationTests {
    private let scratchRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-crossfile-scratch-\(UUID().uuidString)")
    private let cacheRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-crossfile-cache-\(UUID().uuidString)")
    private let toolchain = makeToolchain()

    /// `A.swift`'s own mutation site — `enabled = true`, the identical
    /// proven single-`bool-literal`-candidate shape
    /// `MutationRunnerResultCacheTests.writeSingleMutantProject` uses — has
    /// nothing textually to do with `dependency()`. `isReady()` exists
    /// purely to give `A.swift` a real, ordinary call into `B.swift`, the
    /// way two production files are actually coupled, not just co-located
    /// in the same run. A bare, non-literal, non-discarded call like this
    /// matches none of the default-profile operators (`return-value-
    /// replacement` needs an explicit `return` of a *literal*;
    /// `side-effect-call-removal` is experimental-only and, even enabled,
    /// only matches a discarded standalone call statement, not a returned
    /// value) — so it contributes no mutation candidate of its own,
    /// confirmed below by filtering `discoveredPlan1.mutations` (the
    /// unnarrowed plan) down to A.swift and checking the count is exactly
    /// 1 — narrowed()'s own `plan1.mutations` is always a single-element
    /// array by construction and so proves nothing about how many
    /// candidates A.swift actually offered.
    private func writeA(in repo: URL) throws {
        try GitFixture.write(
            """
            struct A {
                var enabled = true

                func isReady() -> Bool {
                    dependency()
                }
            }

            """,
            at: repo.appendingPathComponent("Sources/A.swift")
        )
    }

    private func writeB(in repo: URL, dependencyReturns: Bool) throws {
        try GitFixture.write(
            """
            func dependency() -> Bool {
                \(dependencyReturns)
            }

            """,
            at: repo.appendingPathComponent("Sources/B.swift")
        )
    }

    private func makeRunner(
        adapter: CountingTestAdapter, plan: MutationPlan, cache: MutationResultCache, digest: String, projectRoot: URL
    ) throws -> MutationRunner {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        return MutationRunner(
            plan: plan,
            configuration: Configuration(),
            projectRoot: projectRoot,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            resultCache: cache,
            resultCacheDigest: digest
        )
    }

    @Test(
        """
        Changing only B.swift invalidates the cache for A.swift's own untouched mutant, and the \
        run re-verifies instead of reusing the stale verdict
        """
    )
    func changingOnlyTheDependencyFileInvalidatesTheCache() async throws {
        let repo = try GitFixture.makeRepository(named: "MutantKit-CrossFileCache")
        defer { try? FileManager.default.removeItem(at: repo) }

        // --- Run 1: dependency() returns false. ---
        try writeA(in: repo)
        try writeB(in: repo, dependencyReturns: false)
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "state 1: dependency() returns false"], in: repo)

        let configuration = Configuration()
        let discoveredPlan1 = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: repo, toolchain: toolchain, diffScope: nil
        )
        // `dependency()`'s own literal (`false`) is itself a legitimate,
        // independently-discovered `bool-literal` candidate in B.swift —
        // real, expected, and irrelevant to what this test is proving.
        // `point1` is narrowed to A.swift's own site specifically so the
        // rest of this test tracks exactly one mutant across both states,
        // not "whatever `.first` happens to return."
        let point1 = try #require(discoveredPlan1.mutations.first { $0.file.hasSuffix("A.swift") })
        let aSwiftMutationCount = discoveredPlan1.mutations.filter { $0.file.hasSuffix("A.swift") }.count
        #expect(
            aSwiftMutationCount == 1,
            """
            isReady()'s bare call to dependency() must not itself contribute a mutation candidate -- \
            only A.swift's own `enabled = true` literal should
            """
        )
        let plan1 = narrowed(discoveredPlan1, to: point1)

        let digest1 = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: configuration, toolchain: toolchain, purpose: "resultCache2"
        )

        let cache = MutationResultCache(root: cacheRoot, policy: .permissive)
        // dependency() false: stands in for "the real suite, run against a
        // real build where dependency() returns false" the same way every
        // other test in this codebase stands in for a real build/test
        // outcome with a scripted fake — the mutant is killed.
        let adapter1 = CountingTestAdapter(mutantStatus: .failed)
        let runner1 = try makeRunner(adapter: adapter1, plan: plan1, cache: cache, digest: digest1, projectRoot: repo)
        let report1 = try await runner1.run()

        #expect(report1.results.count == 1)
        let result1 = try #require(report1.results.first)
        #expect(result1.outcome == .killedByAssertion)
        #expect(result1.origin == .fresh)
        #expect(await adapter1.mutantCallCount == 1)

        // Positive control: run 1 must have actually cached a verdict
        // under its own digest. Without this, "run 2 misses under
        // digest2" (asserted below via `staleLookup`) is equally
        // consistent with nothing ever having been cached at all -- the
        // miss would prove nothing about the digest moving.
        let freshLookup = await cache.load(
            MutationResultCache.Key(mutationID: point1.id, contextDigest: digest1),
            point: point1, planID: plan1.planID, workUnitID: plan1.workUnitID
        )
        #expect(
            freshLookup != nil,
            """
            run 1 must have cached a verdict retrievable under its own digest1 -- the baseline the \
            digest2 miss below is contrasted against
            """
        )

        // --- Run 2: ONLY B.swift changes. A.swift, including its own
        // mutation site, is byte-for-byte untouched. ---
        try writeB(in: repo, dependencyReturns: true)
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "state 2: dependency() returns true -- A.swift untouched"], in: repo)

        let discoveredPlan2 = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: repo, toolchain: toolchain, diffScope: nil
        )
        let point2 = try #require(discoveredPlan2.mutations.first { $0.file.hasSuffix("A.swift") })
        let plan2 = narrowed(discoveredPlan2, to: point2)

        // Per-mutant identity (`PlannedMutationRef.pointDigest`, ADR-0005)
        // is scoped to the mutated file's own content alone — A.swift never
        // changed, so this must still be the identical mutation, not a new
        // one. If this test's premise ("A.swift's own mutation site is
        // completely untouched") ever silently stopped holding, this is
        // what would catch it.
        #expect(point2.id == point1.id, "A.swift's own mutation site is untouched, so its MutationID must be unchanged")
        #expect(
            PlannedMutationRef.pointDigest(for: point2) == PlannedMutationRef.pointDigest(for: point1),
            "the per-mutant point digest is a function of the mutated file alone -- B.swift changing must not move it"
        )

        let digest2 = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: configuration, toolchain: toolchain, purpose: "resultCache2"
        )
        #expect(
            digest2 != digest1,
            "the context digest is a whole-worktree content digest -- B.swift changing (even though A.swift did not) must move it"
        )

        // The entry run 1 stored must not be servable under run 2's own
        // digest — the direct proof that nothing here depends on the
        // MutationRunner-level assertions below to catch a stale reuse.
        let staleLookup = await cache.load(
            MutationResultCache.Key(mutationID: point2.id, contextDigest: digest2),
            point: point2, planID: plan2.planID, workUnitID: plan2.workUnitID
        )
        #expect(staleLookup == nil, "a verdict stored under digest1 must never be served under digest2")

        // dependency() now returns true: a real rebuild/retest's own
        // observed behavior would differ, simulated here exactly the way
        // every other test in this codebase simulates a differing real
        // build/test outcome — a differently-configured fake. Run 2 must
        // actually reach this adapter, not reuse run 1's cached verdict.
        let adapter2 = CountingTestAdapter(mutantStatus: .passed)
        let runner2 = try makeRunner(adapter: adapter2, plan: plan2, cache: cache, digest: digest2, projectRoot: repo)
        let report2 = try await runner2.run()

        #expect(report2.results.count == 1)
        let result2 = try #require(report2.results.first)
        #expect(await adapter2.mutantCallCount == 1, "run 2 must actually re-evaluate the mutant, not skip evaluation via a cache hit")
        #expect(result2.origin == .fresh, "a genuinely fresh evaluation, not a cross-run cache reuse of run 1's stale verdict")
        #expect(
            result2.outcome == .survived,
            "the new, correct outcome for dependency() now returning true -- not run 1's killedByAssertion"
        )
    }

    /// `discovered`, reduced to `point` alone — every other field copied
    /// verbatim. Keeps the runner's own evaluation, call counts, and
    /// `report.results` scoped to exactly the one mutant this test tracks,
    /// so B.swift's own independently-discovered `bool-literal` candidate
    /// (real and expected — see `changingOnlyTheDependencyFileInvalidatesTheCache`'s
    /// own comment) never has to be reasoned about alongside it.
    private func narrowed(_ discovered: MutationPlan, to point: MutationPoint) -> MutationPlan {
        MutationPlan(
            planID: discovered.planID,
            createdAt: discovered.createdAt,
            projectRoot: discovered.projectRoot,
            toolchain: discovered.toolchain,
            configurationHash: discovered.configurationHash,
            sourceFileHashes: discovered.sourceFileHashes,
            mutations: [point],
            skipped: discovered.skipped,
            operators: discovered.operators
        )
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
    private let mutantStatus: TestRunStatus
    private(set) var mutantCallCount = 0

    init(mutantStatus: TestRunStatus) {
        self.mutantStatus = mutantStatus
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        mutantCallCount += 1
        return Self.result(mutantStatus)
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
