import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner

struct ShardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shard",
        abstract: "Split a plan into N independent plans for parallel CI jobs.",
        discussion: """
        Assignment is by mutation ID, so a given mutant always lands in the same \
        shard regardless of machine, job order, or how many times you re-shard. \
        Each shard keeps the full operator and file-hash context, so it is a \
        complete plan in its own right and can be run and verified alone.
        """
    )

    @Argument(help: "The plan to split.")
    var plan: String

    @Option(name: .long, help: "Number of shards.")
    var count: Int

    @Option(name: [.customLong("output-directory"), .customShort("o")], help: "Where to write the shards.")
    var outputDirectory = "."

    func run() async throws {
        let planURL = URL(fileURLWithPath: plan)
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: planURL))
        let shards = try PlanSharding.shard(plan: loadedPlan, count: count)

        let directory = URL(fileURLWithPath: outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = planURL.deletingPathExtension().lastPathComponent
        for (index, shard) in shards.enumerated() {
            let url = directory.appendingPathComponent("\(stem).\(index).json")
            try shard.encoded().write(to: url, options: .atomic)
            print("\(url.path): \(shard.mutations.count) mutation(s)")
        }

        print("\nSplit \(loadedPlan.mutations.count) mutation(s) into \(shards.count) shard(s).")
        print("Run each with `mutantkit run --plan \(stem).<n>.json --output results.<n>.json`, then `mutantkit merge`.")
    }
}
