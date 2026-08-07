import ArgumentParser
import Foundation
import MutationModel
import MuterCompatibility
import Yams

struct MigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Convert a muter.conf.yml into a mutantkit.yml.",
        discussion: """
        The importer reports every field it translated, every field it dropped, and \
        why. It does not silently discard settings it cannot carry.

        MutantKit does not aim for behavioural compatibility with Muter and will not \
        reproduce its mutation scores. Expect different — and probably lower — \
        numbers.
        """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .customLong("from-muter"), help: "Path to muter.conf.yml.")
    var fromMuter: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Where to write mutantkit.yml.")
    var output: String?

    @Flag(name: .long, help: "Print the result without writing it.")
    var dryRun = false

    @Flag(name: .long, help: "Overwrite an existing mutantkit.yml.")
    var force = false

    func run() async throws {
        let source = URL(fileURLWithPath: fromMuter)
        let result = try MuterConfigImporter().importConfiguration(from: source)

        print(result.report.rendered())

        let yaml = try YAMLEncoder().encode(result.configuration)

        guard !dryRun else {
            print("\n--- mutantkit.yml (dry run) ---\n\(yaml)")
            return
        }

        let destination = output.map { URL(fileURLWithPath: $0) }
            ?? common.resolvedProjectRoot.appendingPathComponent(ConfigurationLoader.fileName)

        if FileManager.default.fileExists(atPath: destination.path), !force {
            print("\n\(destination.path) already exists. Pass --force to overwrite it.")
            throw ExitCode(MutantKitExit.operationalError)
        }

        try Data(yaml.utf8).write(to: destination, options: .atomic)
        print("\nWrote \(destination.path)")

        if result.report.requiresAttention {
            print("""

            Some settings need your attention — see the report above. Review the file, \
            then run `mutantkit doctor` to check it against this environment.
            """)
        } else {
            print("Next: `mutantkit doctor`, then `mutantkit plan`.")
        }
    }
}
