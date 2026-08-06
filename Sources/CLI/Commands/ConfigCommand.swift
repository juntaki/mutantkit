import ArgumentParser
import Foundation
import MutationModel

/// Validates `mutantkit.yml` or emits the JSON Schema used by editors/CI.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Validate MutantKit configuration or print its JSON Schema."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Print the JSON Schema instead of validating the resolved configuration.")
    var schema = false

    func run() throws {
        if schema {
            print(ConfigurationJSONSchema.document)
            return
        }

        let root = common.resolvedProjectRoot
        let configuration = try ConfigurationLoader.load(
            explicitPath: common.configPath,
            projectRoot: root
        )
        let issues = ConfigurationValidator.validate(configuration, projectRoot: root)

        if issues.isEmpty {
            print("Configuration is valid.")
            return
        }

        for issue in issues {
            print(issue.description)
        }

        if issues.contains(where: { $0.severity == .error }) {
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
