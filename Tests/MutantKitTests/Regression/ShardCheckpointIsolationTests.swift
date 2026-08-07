import Foundation
import MutationModel
import Testing

/// Shards of one plan must not share a checkpoint.
///
/// Sharding keeps the parent's `planID` on every shard, because they really are
/// the same plan split up. That makes `planID` the wrong thing to key a
/// checkpoint on: each shard would resume from its siblings' results, then
/// report outcomes for mutations absent from its own plan. The integrity check
/// catches that as `resultWithoutPlannedMutation`, but the run is already wasted
/// by then — and on a CI matrix, where shards run on separate machines with
/// separate disks, it would not reproduce locally at all.
@Suite("Regression: shards of one plan get separate checkpoints")
struct ShardCheckpointIsolationTests {
    @Test("Shards sharing a plan ID still get distinct work-unit IDs")
    func shardsWithSamePlanIDHaveDistinctWorkUnitIDs() {
        let all = (0 ..< 6).map { Self.point(index: $0) }

        let parent = Self.plan(id: "plan_shared", mutations: all)
        let shardA = Self.plan(id: "plan_shared", mutations: Array(all[0 ..< 3]))
        let shardB = Self.plan(id: "plan_shared", mutations: Array(all[3 ..< 6]))

        #expect(shardA.planID == shardB.planID, "sharding is expected to preserve the parent plan ID")

        #expect(shardA.workUnitID != shardB.workUnitID)
        #expect(shardA.workUnitID != parent.workUnitID)
        #expect(shardB.workUnitID != parent.workUnitID)
    }

    @Test("The same work resumes: identical mutation sets share a work-unit ID")
    func identicalPlansShareWorkUnitID() {
        let mutations = (0 ..< 3).map { Self.point(index: $0) }
        let first = Self.plan(id: "plan_a", mutations: mutations)
        // Reversed on the way in: the plan sorts by ID, so ordering must not
        // leak into the key or a re-run would never resume.
        let second = Self.plan(id: "plan_a", mutations: mutations.reversed())

        #expect(first.workUnitID == second.workUnitID)
    }

    @Test("A different parent plan never reuses another's checkpoint")
    func differentPlanIDsDoNotShareWorkUnitID() {
        let mutations = (0 ..< 3).map { Self.point(index: $0) }
        #expect(
            Self.plan(id: "plan_a", mutations: mutations).workUnitID
                != Self.plan(id: "plan_b", mutations: mutations).workUnitID
        )
    }

    // MARK: - Fixtures

    private static func point(index: Int) -> MutationPoint {
        let declaration = DeclarationIdentity(path: ["Fixture", "value()"])
        let id = MutationID.compute(
            filePath: "Sources/Fixture.swift",
            declaration: declaration,
            operatorID: "swift.core.bool-literal-inversion",
            operatorVersion: 1,
            originalTokenFingerprint: ContentHash.shortDigest(of: "true"),
            occurrenceIndex: index
        )

        return MutationPoint(
            id: id,
            file: "Sources/Fixture.swift",
            enclosingDeclaration: declaration,
            operatorID: "swift.core.bool-literal-inversion",
            operatorVersion: 1,
            occurrenceIndex: index,
            utf8Range: ByteRange(start: index * 10, end: index * 10 + 4),
            originalText: "true",
            replacementText: "false",
            prefixTokenFingerprint: "prefix",
            suffixTokenFingerprint: "suffix",
            sourceFileHash: ContentHash.of("fixture"),
            expectedSyntaxKind: "booleanLiteralExpr",
            confidence: .high,
            executionMode: .isolated,
            line: index + 1,
            column: 1
        )
    }

    private static func plan(id: String, mutations: [MutationPoint]) -> MutationPlan {
        MutationPlan(
            planID: id,
            createdAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/fixture",
            toolchain: ToolchainFingerprint(
                toolVersion: "test",
                toolCommitSHA: nil,
                swiftVersion: "test",
                swiftSyntaxVersion: "test",
                xcodeVersion: nil
            ),
            configurationHash: ContentHash.of("config"),
            sourceFileHashes: ["Sources/Fixture.swift": ContentHash.of("fixture")],
            mutations: mutations,
            skipped: [],
            operators: []
        )
    }
}
