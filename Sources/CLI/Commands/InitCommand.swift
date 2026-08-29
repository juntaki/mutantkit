import ArgumentParser
import Foundation

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write a mutantkit.yml for this project."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Overwrite an existing mutantkit.yml.")
    var force = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let destination = root.appendingPathComponent(ConfigurationLoader.fileName)

        if FileManager.default.fileExists(atPath: destination.path), !force {
            print("\(destination.path) already exists. Pass --force to overwrite it.")
            throw ExitCode(MutantKitExit.operationalError)
        }

        let plan = await ProjectDetectionPlan.detect(root: root)
        print(plan.summaryLines.joined(separator: "\n"))

        try Data(plan.template.utf8).write(to: destination, options: .atomic)
        print("\nWrote \(destination.path)")
        print(plan.hasTestTargets
            ? "Next: run `mutantkit doctor` and `mutantkit plan` — `tests.targets` is already filled in, review it before running."
            : "Next: fill in `tests.targets`, then run `mutantkit doctor` and `mutantkit plan`.")
    }
}
