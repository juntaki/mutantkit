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

        Start with `mutantkit setup` — it detects your project, checks your environment, and \
        writes a starting `mutantkit.yml` in one step. Prefer to go one step at a time? \
        `mutantkit doctor` checks the environment alone, and `mutantkit init` writes the \
        config alone.
        """,
        version: ToolVersion.summary,
        subcommands: [
            SetupCommand.self,
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

    /// Runs `body`, mapping any error it throws — other than one that
    /// already carries its own deliberate exit code (`ExitCode`) — to
    /// `operationalError`, explicitly. A JSON decode failure, a
    /// `ConfigurationLoader` error, or plain file I/O reaching this point
    /// would otherwise propagate unmapped and fall through to
    /// `ArgumentParser`'s own default failure exit code, which today
    /// happens to equal `operationalError` only by coincidence, not by
    /// design — this tool's exit codes are a stable, deliberate API (see
    /// this enum's own doc comment), and every path that reaches one should
    /// say so on purpose rather than by accident.
    static func onFailure<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            throw ExitCode(operationalError)
        }
    }
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
                // Bad input, not a usage-syntax error `ArgumentParser`'s own
                // `ValidationError` (exit 64) would suggest: every other bad-
                // input case in the commands that reach here already throws
                // `MutantKitExit.operationalError` explicitly, and this one
                // should be no different (see the CLI's own exit-code
                // contract, `MutantKitExit`).
                print("Unknown operator profile '\(profile)'. Expected: conservative, default, experimental.")
                throw ExitCode(MutantKitExit.operationalError)
            }
            configuration.operators.profile = parsed
        }
    }
}
