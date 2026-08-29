import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner
import Reporting

struct MergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Combine shard reports into one report."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "The shard reports to merge.")
    var reports: [String]

    @Option(name: .long, help: "The original, unsharded plan. Needed to check that every mutant came back.")
    var plan = "plan.json"

    @Option(name: [.customLong("output"), .customShort("o")], help: "Where to write the merged JSON report.")
    var output = "report.json"

    func run() async throws {
        let loadedPlan = try MutantKitExit.onFailure {
            try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: plan)))
        }
        let decoder = MutationPlan.decoder()

        let loaded = try MutantKitExit.onFailure {
            try reports.map { path in
                try decoder.decode(RunReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            }
        }

        // Merging re-runs the integrity check against the *whole* plan, which is
        // the only place a mutant lost between shards can be caught: each shard
        // reconciled perfectly against its own subset while the run as a whole
        // silently dropped it.
        let merged = try PlanSharding.merge(reports: loaded, plan: loadedPlan)

        try merged.encoded().write(to: URL(fileURLWithPath: output), options: .atomic)
        print(try ConsoleReporter().render(merged))
        print("\nWrote \(output)")

        // The one point in a sharded CI pipeline that knows the real,
        // whole-project score: each shard's own `mutantkit run` records only
        // its partial slice (or, with `--no-history`, nothing at all — see
        // RunCommand), so this is the only history record such a pipeline
        // ever produces that reflects the whole plan. Best-effort, like
        // RunCommand's own history write: a failure here should not fail an
        // otherwise-successful merge, but must not vanish either.
        do {
            try RunHistoryStore(
                root: common.resolvedProjectRoot.appendingPathComponent(".mutantkit/history")
            ).record(merged)
        } catch {
            let diagnosis = "history write failed for \(merged.planID): \(error)"
            FileHandle.standardError.write(Data("warning: \(diagnosis)\n".utf8))
        }

        guard merged.integrity.passed else {
            throw ExitCode(MutantKitExit.integrityFailure)
        }
    }
}
