import Foundation
import MutationModel
import MutationPlanner
import Testing

/// Sharding is what lets a one-hour run fit inside a ten-minute CI budget —
/// but only because the assignment is a pure function of the mutation ID. A
/// shard run that landed on different mutants each time it was scheduled would
/// silently change the score; a merge that combined reports from different
/// plans would publish a number for a project state that never existed.
@Suite("Plan sharding")
struct PlanShardingTests {
    /// Assignment is `FNV-1a(id) % count`. The same mutant lands in the same
    /// shard every time, for every count — that is what makes a re-run of a
    /// dead shard land on exactly the same mutants.
    @Test("The same mutant always lands in the same shard for a given count")
    func assignmentIsStable() {
        let ids = (0 ..< 50).map { MutationID(rawValue: "mut_\($0)") }

        for count in [2, 3, 5, 8] {
            for id in ids {
                let assignment = PlanSharding.index(of: id, count: count)
                #expect(assignment == PlanSharding.index(of: id, count: count))
                #expect((0 ..< count).contains(assignment))
            }
        }
    }

    @Test("Assignment is uniform-ish across shards")
    func assignmentIsRoughlyBalanced() {
        let ids = (0 ..< 1000).map { MutationID(rawValue: "mut_\($0)") }
        let count = 4

        var buckets = [Int](repeating: 0, count: count)
        for id in ids { buckets[PlanSharding.index(of: id, count: count)] += 1 }

        // Not asking for perfect balance — asking that no shard is empty and no
        // shard holds more than 40% of the mutants. A broken hash that put
        // everything in one bucket would show up immediately.
        #expect(buckets.allSatisfy { $0 > 0 })
        #expect(buckets.allSatisfy { $0 <= ids.count * 4 / 10 })
    }

    @Test("Shard count 1 returns the original plan untouched")
    func shardCountOneIsIdentity() throws {
        let plan = Self.plan(mutations: Self.points(count: 5))

        let shards = try PlanSharding.shard(plan: plan, count: 1)

        #expect(shards.count == 1)
        #expect(shards[0].mutations == plan.mutations)
        #expect(shards[0].skipped == plan.skipped)
    }

    @Test("Shard count 0 is refused")
    func shardCountZeroIsRefused() {
        let plan = Self.plan(mutations: Self.points(count: 5))

        #expect(throws: ShardingError.self) {
            try PlanSharding.shard(plan: plan, count: 0)
        }
    }

    /// The union of shards' mutations equals the original plan's mutations, and
    /// the union is disjoint: no mutant appears in two shards. This is the
    /// property that makes merge a concatenation rather than a reconciliation.
    @Test("Shards partition the parent's mutations")
    func shardsPartitionMutations() throws {
        let points = Self.points(count: 20)
        let plan = Self.plan(mutations: points)

        let shards = try PlanSharding.shard(plan: plan, count: 4)

        // Union equals parent.
        let union = Set(shards.flatMap { $0.mutations.map(\.id) })
        #expect(union == Set(plan.mutations.map(\.id)))

        // Disjoint across shards.
        var seen: Set<MutationID> = []
        for shard in shards {
            for id in shard.mutations.map(\.id) {
                #expect(seen.insert(id).inserted, "\(id) appeared in two shards")
            }
        }
    }

    /// Skipped records shard by the same rule, so the union of the shards'
    /// skips equals the parent's skips — and not, as the simpler choice would
    /// have it, the parent's skips duplicated `count` times.
    @Test("Shards partition skipped records by the same rule")
    func shardsPartitionSkipped() throws {
        let skippedPoints = Self.points(count: 10)
        let skipped = skippedPoints.map {
            SkippedMutation(id: $0.id, file: $0.file, reason: .budgetExceeded)
        }
        let plan = Self.plan(mutations: [], skipped: skipped)

        let shards = try PlanSharding.shard(plan: plan, count: 3)

        let union = Set(shards.flatMap { $0.skipped.map(\.id) })
        #expect(union == Set(skipped.map(\.id)))

        var seen: Set<MutationID> = []
        for shard in shards {
            for record in shard.skipped {
                #expect(seen.insert(record.id).inserted, "\(record.id) skipped in two shards")
            }
        }
    }

    /// Shards share the parent's `planID`. This is deliberate, and the source
    /// of the checkpoint isolation hazard the regression tests guard against:
    /// `planID` cannot be a checkpoint key because every shard has it.
    @Test("Shards share the parent's plan ID")
    func shardsShareParentPlanID() throws {
        let plan = Self.plan(id: "plan_shared", mutations: Self.points(count: 6))
        let shards = try PlanSharding.shard(plan: plan, count: 3)

        #expect(shards.allSatisfy { $0.planID == "plan_shared" })
        #expect(shards.allSatisfy { $0.planID == plan.planID })
    }

    /// Each shard keeps the full `sourceFileHashes` and the full `operators`
    /// list, so a shard's report stays interpretable on its own and a shard
    /// can still detect a file that changed under it.
    @Test("Each shard keeps the parent's source hashes and operators")
    func shardsKeepParentMetadata() throws {
        let plan = MutationPlan(
            planID: "plan_a",
            createdAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/p",
            toolchain: Self.toolchain,
            configurationHash: ContentHash.of("config"),
            sourceFileHashes: [
                "Sources/A.swift": ContentHash.of("a"),
                "Sources/B.swift": ContentHash.of("b")
            ],
            mutations: Self.points(count: 3),
            skipped: [],
            operators: []
        )

        let shards = try PlanSharding.shard(plan: plan, count: 3)

        #expect(shards.count == 3)
        for shard in shards {
            #expect(shard.sourceFileHashes == plan.sourceFileHashes)
            #expect(shard.operators == plan.operators)
        }
    }

    // MARK: - merge

    /// Merging the shard reports for a plan reproduces the unsharded report:
    /// same mutation IDs, same outcomes, no mutant added and none dropped.
    @Test("Merge reconstructs the unsharded report exactly")
    func mergeReconstructsUnsharded() throws {
        let points = Self.points(count: 12)
        let plan = Self.plan(mutations: points)
        let unshardedReport = Self.report(
            plan: plan,
            results: points.map { Self.result(point: $0, outcome: .killedByAssertion) }
        )

        let shards = try PlanSharding.shard(plan: plan, count: 4)
        let shardReports = shards.map { shard in
            Self.report(
                plan: shard,
                results: shard.mutations.map { Self.result(point: $0, outcome: .killedByAssertion) }
            )
        }

        let merged = try PlanSharding.merge(reports: shardReports, plan: plan)

        let byID = Dictionary(uniqueKeysWithValues: merged.results.map { ($0.id, $0.outcome) })
        let originalByID = Dictionary(uniqueKeysWithValues: unshardedReport.results.map { ($0.id, $0.outcome) })
        #expect(byID == originalByID)
        #expect(merged.integrity.passed == unshardedReport.integrity.passed)
        #expect(merged.score == unshardedReport.score)
    }

    /// Merge refuses reports from different plans. The two reports would
    /// otherwise be stitched into a number for a project state that never
    /// existed.
    @Test("Merge refuses reports from different plans")
    func mergeRefusesDifferentPlans() throws {
        let planA = Self.plan(id: "plan_a", mutations: Self.points(count: 3))
        let planB = Self.plan(id: "plan_b", mutations: Self.points(count: 3))

        let reportA = Self.report(plan: planA, results: [])
        let reportB = Self.report(plan: planB, results: [])

        #expect(throws: ShardingError.self) {
            try PlanSharding.merge(reports: [reportA, reportB], plan: planA)
        }
    }

    /// Merge refuses a toolchain mismatch. Numbers measured against different
    /// compilers are not comparable.
    @Test("Merge refuses reports from different toolchains")
    func mergeRefusesDifferentToolchains() throws {
        let plan = Self.plan(mutations: Self.points(count: 3))
        let otherToolchain = ToolchainFingerprint(
            toolVersion: "0.1.0",
            toolCommitSHA: nil,
            swiftVersion: "6.0.0",
            swiftSyntaxVersion: "600.0.0",
            xcodeVersion: nil
        )

        let a = Self.report(plan: plan, results: [], toolchain: Self.toolchain)
        let b = Self.report(plan: plan, results: [], toolchain: otherToolchain)

        #expect(throws: ShardingError.self) {
            try PlanSharding.merge(reports: [a, b], plan: plan)
        }
    }

    /// A duplicate result — the same mutant reported by two shards — is
    /// refused. A merge that quietly took the first would let a re-run of one
    /// shard double-count its mutants and silently widen its share of the score.
    @Test("Merge refuses duplicate results across shards")
    func mergeRefusesDuplicates() throws {
        let points = Self.points(count: 3)
        let plan = Self.plan(mutations: points)

        let firstShard = try PlanSharding.shard(plan: plan, count: 2)[0]
        let firstShardReport = Self.report(
            plan: firstShard,
            results: firstShard.mutations.map { Self.result(point: $0, outcome: .killedByAssertion) }
        )

        // The second shard is set up to report one mutant the first already
        // reported — exactly what would happen if a checkpoint let a shard
        // resume its sibling's results.
        let duplicatedPoint = firstShard.mutations.first!
        let secondReport = Self.report(
            plan: plan,
            results: [Self.result(point: duplicatedPoint, outcome: .survived)]
        )

        #expect(throws: ShardingError.self) {
            try PlanSharding.merge(reports: [firstShardReport, secondReport], plan: plan)
        }
    }

    /// A failed baseline in any shard invalidates the merged report. A baseline
    /// that passed everywhere carries the (shared) passing record; a baseline
    /// that failed somewhere carries the failing one so the reader sees the
    /// actual failure rather than a silent pass.
    @Test("A failed baseline in one shard fails the merged report")
    func failedBaselineIsCarriedThroughMerge() throws {
        let points = Self.points(count: 4)
        let plan = Self.plan(mutations: points)

        let passing = Self.report(
            plan: plan,
            results: points.map { Self.result(point: $0, outcome: .killedByAssertion) },
            baselinePassed: true
        )
        let failing = Self.report(
            plan: plan,
            results: [],
            baselinePassed: false
        )

        let merged = try PlanSharding.merge(reports: [passing, failing], plan: plan)

        #expect(!merged.baseline.passed)
        #expect(merged.score == nil, "a red baseline anywhere withholds the merged score")
    }

    @Test("Merging an empty set is refused")
    func mergingEmptyIsRefused() throws {
        let plan = Self.plan(mutations: [])
        #expect(throws: ShardingError.self) {
            try PlanSharding.merge(reports: [], plan: plan)
        }
    }

    // MARK: - Fixtures

    private static let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private static func points(count: Int) -> [MutationPoint] {
        (0 ..< count).map { index in
            point(id: "mut_\(String(format: "%04d", index))", file: "Sources/File\(index % 3).swift")
        }
    }

    private static func point(id: String, file: String) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: id),
            file: file,
            enclosingDeclaration: DeclarationIdentity(path: ["Q", "f()"]),
            operatorID: "swift.core.bool-literal-inversion",
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(start: 0, end: 4),
            originalText: "true",
            replacementText: "false",
            prefixTokenFingerprint: "prefix",
            suffixTokenFingerprint: "suffix",
            sourceFileHash: ContentHash.of(file),
            expectedSyntaxKind: "booleanLiteralExpr",
            confidence: .high,
            executionMode: .isolated,
            line: 1,
            column: 1
        )
    }

    private static func plan(
        id: String = "plan_test",
        mutations: [MutationPoint],
        skipped: [SkippedMutation] = []
    ) -> MutationPlan {
        MutationPlan(
            planID: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projectRoot: "/p",
            toolchain: toolchain,
            configurationHash: ContentHash.of("config"),
            sourceFileHashes: ["Sources/Foo.swift": ContentHash.of("foo")],
            mutations: mutations,
            skipped: skipped,
            operators: []
        )
    }

    private static func result(point: MutationPoint, outcome: MutationOutcome) -> MutationResult {
        makeResult(
            point: point,
            outcome: outcome,
            evidence: MutationEvidence(
                sourceBeforeHash: ContentHash.of("before"),
                sourceAfterHash: ContentHash.of("after"),
                sourceDiff: "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-true\n+false\n",
                buildProductHash: ContentHash.of("mutant"),
                applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                    mutantHash: ContentHash.of("mutant"),
                    baselineHash: ContentHash.of("baseline")
                ))
            ),
            testSummary: TestOutcomeSummary(
                total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.1
            ),
            diagnosis: "test",
            durationSeconds: 0.5
        )
    }

    private static func report(
        plan: MutationPlan,
        results: [MutationResult],
        baselinePassed: Bool = true,
        toolchain: ToolchainFingerprint = toolchain
    ) -> RunReport {
        let baseline = BaselineRecord(
            passed: baselinePassed,
            testSummary: TestOutcomeSummary(
                total: 1, passed: baselinePassed ? 1 : 0,
                failed: baselinePassed ? 0 : 1,
                failingTests: baselinePassed ? [] : ["X/y()"],
                durationSeconds: 0.5
            ),
            durationSeconds: 0.5,
            buildProductHash: ContentHash.of("baseline"),
            buildCommand: nil,
            testCommand: nil
        )

        return RunReport(
            planID: plan.planID,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100),
            projectRoot: plan.projectRoot,
            toolchain: toolchain,
            baseline: baseline,
            ledger: makeLedger(results),
            integrity: IntegrityChecker.check(
                plan: plan, ledger: makeLedger(results), baselinePassed: baselinePassed
            )
        )
    }
}
