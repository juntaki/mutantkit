import Foundation
import MutationModel
import Testing

/// Sharding a plan, running each shard independently, and merging the results.
///
/// The claim under test is that splitting the work does not change the answer.
/// It is checked by running the same plan both ways and comparing outcomes per
/// mutation, not by comparing scores: a score is one number that many different
/// wrong runs can agree on, and two runs that lost different mutants can still
/// average out to the same percentage.
@Suite("Acceptance: shard, run, merge", .enabled(if: Acceptance.isEnabled))
struct ShardMergeAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 2
    reports: [console, json]
    """

    private func stage() throws -> URL {
        let directory = try Acceptance.stageFixture("SwiftPackageMacOS")
        try Data(Self.configuration.utf8)
            .write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)
        return directory
    }

    private func outcomes(_ report: RunReport) -> [MutationID: MutationOutcome] {
        Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.outcome) })
    }

    @Test("Three shards merge to the same outcomes as one unsharded run")
    func shardedRunAgreesWithUnshardedRun() throws {
        let directory = try stage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Acceptance.run(["plan", "--output", "plan.json"], in: directory)

        // Unsharded, for reference.
        try Acceptance.run(["run", "--plan", "plan.json", "--report", "json"], in: directory)
        let whole = try MutationPlan.decoder().decode(
            RunReport.self,
            from: Data(contentsOf: directory.appendingPathComponent(".mutantkit/report.json"))
        )

        try Acceptance.run(["shard", "plan.json", "--count", "3", "-o", "shards"], in: directory)

        for index in 0 ..< 3 {
            let shard = try Acceptance.run(
                ["run", "--plan", "shards/plan.\(index).json", "-o", "r\(index).json",
                 "--report", "json", "--no-resume"],
                in: directory
            )
            #expect(shard.exitCode == 0, "shard \(index): \(shard.output)")
        }

        let merged = try Acceptance.run(
            ["merge", "r0.json", "r1.json", "r2.json", "--plan", "plan.json", "-o", "merged.json"],
            in: directory
        )
        #expect(merged.exitCode == 0, "\(merged.output)")

        let combined = try MutationPlan.decoder().decode(
            RunReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("merged.json"))
        )

        // Merging re-checks the invariants against the *whole* plan, which is the
        // only place a mutant lost between shards can surface: each shard
        // reconciles perfectly against its own subset while the run as a whole
        // silently drops it.
        #expect(combined.integrity.violations.isEmpty, "\(combined.integrity.violations.map(\.detail))")
        #expect(outcomes(combined) == outcomes(whole))
        #expect(combined.score?.killed == whole.score?.killed)
        #expect(combined.score?.survived == whole.score?.survived)
    }

    /// Shards keep their parent's plan ID, so keying a checkpoint on that would
    /// have each shard resume from its siblings' results and then report outcomes
    /// for mutations absent from its own plan. On a CI matrix — separate machines,
    /// separate disks — it would not reproduce locally either.
    @Test("Shards of one plan do not share a checkpoint")
    func shardsDoNotShareACheckpoint() throws {
        let directory = try stage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        try Acceptance.run(["shard", "plan.json", "--count", "3", "-o", "shards"], in: directory)

        // Run every shard in one working directory, without --no-resume, so any
        // checkpoint collision has every chance to happen.
        for index in 0 ..< 3 {
            let shard = try Acceptance.run(
                ["run", "--plan", "shards/plan.\(index).json", "-o", "r\(index).json", "--report", "json"],
                in: directory
            )
            #expect(shard.exitCode == 0, "shard \(index) picked up another shard's results: \(shard.output)")
        }

        let checkpoints = try FileManager.default
            .contentsOfDirectory(atPath: directory.appendingPathComponent(".mutantkit").path)
            .filter { $0.hasPrefix("checkpoint-") }
        #expect(checkpoints.count == 3, "each shard needs its own checkpoint, found \(checkpoints)")
    }

    /// Assignment is by mutation ID, so re-sharding cannot move a mutant.
    @Test("Sharding is deterministic and loses nothing")
    func shardingIsDeterministicAndTotal() throws {
        let directory = try stage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        let plan = try MutationPlan.decode(from: Data(contentsOf: directory.appendingPathComponent("plan.json")))

        func shardIDs(into folder: String) throws -> [Set<MutationID>] {
            try Acceptance.run(["shard", "plan.json", "--count", "3", "-o", folder], in: directory)
            return try (0 ..< 3).map { index in
                let url = directory.appendingPathComponent("\(folder)/plan.\(index).json")
                return Set(try MutationPlan.decode(from: Data(contentsOf: url)).mutations.map(\.id))
            }
        }

        let first = try shardIDs(into: "a")
        let second = try shardIDs(into: "b")

        #expect(first == second, "the same mutant must always land in the same shard")
        // Every mutation appears exactly once across the shards.
        #expect(first.reduce(Set<MutationID>()) { $0.union($1) } == Set(plan.mutations.map(\.id)))
        #expect(first.reduce(0) { $0 + $1.count } == plan.mutations.count)
    }
}
