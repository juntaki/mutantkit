import ArgumentParser
import Foundation
import MutationModel

@main
struct MutantKit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutantkit",
        abstract: "Trustworthy mutation testing for Swift and Apple platforms.",
        discussion: """
        MutantKit introduces small faults into your code and checks whether your tests \
        notice. Every mutant it reports can be proven to have been applied and executed; \
        when that cannot be proven, MutantKit reports no score rather than a misleading one.

        Start with `mutantkit doctor` — it checks your environment before you write any \
        configuration.
        """,
        version: ToolVersion.summary,
        subcommands: [
            InitCommand.self,
            DoctorCommand.self,
            ConfigCommand.self,
            DryRunCommand.self,
            PlanCommand.self,
            RunCommand.self,
            GateCommand.self,
            PerfCommand.self,
            HistoryCommand.self,
            VerifyCommand.self,
            InspectCommand.self,
            ReproduceCommand.self,
            ShardCommand.self,
            MergeCommand.self,
            MigrateCommand.self,
            OperatorCatalogCommand.self
        ],
        defaultSubcommand: nil
    )
}

// MARK: - Exit codes

/// Exit codes are an API: CI depends on them, so they are enumerated rather than
/// improvised at each call site.
enum MutantKitExit {
    /// The run completed and its results are trustworthy. Surviving mutants do
    /// NOT make this non-zero by default — a survivor is a finding, not a tool
    /// failure, and a suite is not broken for having one.
    static let success: Int32 = 0
    /// The tool could not do its job: bad config, unreadable plan, no project.
    static let operationalError: Int32 = 1
    /// The run happened but its own invariants did not reconcile, so no score was
    /// produced. Distinct from an operational error because the difference
    /// matters to whoever reads the CI log.
    static let integrityFailure: Int32 = 2
    /// Mutants survived and the caller asked for that to fail the build.
    static let survivorsFound: Int32 = 3
    /// A trusted report missed an explicit CI mutation-quality threshold.
    static let qualityGateFailure: Int32 = 4
}

// MARK: - Shared options

struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the project root. Defaults to the current directory.")
    var projectRoot: String?

    @Option(name: [.customLong("config"), .customShort("c")], help: "Path to mutantkit.yml.")
    var configPath: String?

    var resolvedProjectRoot: URL {
        URL(fileURLWithPath: projectRoot ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
    }
}

/// Flags that override the config file.
///
/// Every one is optional with no default, so "not passed" is distinguishable
/// from "passed the default value". Without that distinction a flag's default
/// would silently outrank the user's config file, which inverts the documented
/// precedence.
struct OverrideOptions: ParsableArguments {
    @Option(name: .long, help: "Xcode scheme to build.")
    var scheme: String?

    @Option(name: .long, help: "xcodebuild destination, e.g. 'platform=iOS Simulator,name=iPhone 16'.")
    var destination: String?

    @Option(name: .long, help: "Concurrent mutants. Defaults to half the core count.")
    var workers: Int?

    @Option(name: .long, help: "Operator profile: conservative, default, or experimental.")
    var profile: String?

    @Option(name: .long, help: "Stop after this many mutants.")
    var maxMutants: Int?

    func apply(to configuration: inout Configuration) throws {
        if let scheme { configuration.project.scheme = scheme }
        if let destination { configuration.project.destination = destination }
        if let workers { configuration.execution.workers = workers }
        if let maxMutants { configuration.execution.budget.maxMutants = maxMutants }
        if let profile {
            guard let parsed = OperatorProfile(rawValue: profile) else {
                throw ValidationError(
                    "Unknown operator profile '\(profile)'. Expected: conservative, default, experimental."
                )
            }
            configuration.operators.profile = parsed
        }
    }
}
