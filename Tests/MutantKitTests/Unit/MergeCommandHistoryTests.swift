import Foundation
@testable import CLI
import MutationModel
import MutationPlanner
import Reporting
import Testing

/// Regression coverage for a bug found during an adversarial review of the
/// product-strategy plan, verified against the source: `MergeCommand` never
/// touched `RunHistoryStore` at all. The README's own documented CI recipe is
///
///     mutantkit plan --output plan.json
///     mutantkit shard plan.json --count 8
///     mutantkit run --plan plan.3.json --output results.3.json   # x N shards
///     mutantkit merge results/*.json
///
/// Each sharded `run` recorded its own *partial* score to history, and
/// `merge` — which produces the real, whole-project score — recorded
/// nothing. `mutantkit history` on a CI machine following that recipe showed
/// only misleading per-shard fragments and never the correct combined
/// number.
///
/// This test drives the real `MergeCommand` (via `@testable import CLI`, in
/// process — no subprocess, no Xcode/simulator) against two shard reports
/// covering disjoint mutations, one killed and one survived, and checks that
/// the history record it produces carries the *merged* combined score
/// (killed: 1, survived: 1, tested: 50%) rather than either shard's own
/// partial score (each shard alone would read as 100% or 0%).
@Suite("MergeCommand: records the merged result to history")
struct MergeCommandHistoryTests {
    @Test("merge writes one history record with the merged counts, not a per-shard fragment")
    func mergeRecordsMergedCounts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-MergeCommandHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two real, independently-anchored mutations (distinct files, so
        // distinct content-derived IDs — see ADR-0002) standing in for the
        // work a real sharded plan would split across machines.
        let killedPoint = try makeAnchoredPoint(file: "Sources/A.swift")
        let survivedPoint = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [killedPoint, survivedPoint])

        // Each shard is a genuine single-mutation subset plan sharing the
        // parent's planID, the same shape `mutantkit shard` produces — not a
        // stand-in.
        let killedShardPlan = try PlanSharding.subset(of: plan, mutationIDs: [killedPoint.id])
        let survivedShardPlan = try PlanSharding.subset(of: plan, mutationIDs: [survivedPoint.id])

        let killedShardReport = makeReport(
            plan: killedShardPlan, results: [makeResult(point: killedPoint, outcome: .killedByAssertion)]
        )
        let survivedShardReport = makeReport(
            plan: survivedShardPlan, results: [makeResult(point: survivedPoint, outcome: .survived)]
        )
        // Each shard's own report reads as a whole (and misleading) score on
        // its own: 100% and 0% respectively. Neither should ever land in
        // history as-is.
        #expect(killedShardReport.score?.tested == 1.0)
        #expect(survivedShardReport.score?.tested == 0.0)

        let planURL = directory.appendingPathComponent("plan.json")
        let killedReportURL = directory.appendingPathComponent("killed-shard.json")
        let survivedReportURL = directory.appendingPathComponent("survived-shard.json")
        let outputURL = directory.appendingPathComponent("merged.json")
        try plan.encoded().write(to: planURL, options: .atomic)
        try killedShardReport.encoded().write(to: killedReportURL, options: .atomic)
        try survivedShardReport.encoded().write(to: survivedReportURL, options: .atomic)

        let command = try MergeCommand.parse([
            killedReportURL.path, survivedReportURL.path,
            "--plan", planURL.path,
            "--output", outputURL.path,
            "--project-root", directory.path
        ])
        try await command.run()

        let store = RunHistoryStore(root: directory.appendingPathComponent(".mutantkit/history"))
        let records = store.records()
        #expect(records.count == 1, "merge should write exactly one history record for the whole-project result")

        let record = try #require(records.first)
        #expect(record.killed == 1)
        #expect(record.survived == 1)
        #expect(record.testedScore == 0.5, "the merged score, not either shard's own 100% or 0%")
        #expect(record.integrityPassed)
    }
}
