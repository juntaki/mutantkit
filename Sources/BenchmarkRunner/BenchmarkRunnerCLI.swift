import ArgumentParser
import Foundation

/// The `BenchmarkRunner` executable. Off by default the same way MutantKit's
/// own acceptance suites are — a real run clones and builds real external
/// projects, twice per tool per mode, and can take a very long time for the
/// larger corpus entries. `MUTANTKIT_BENCHMARK=1` gates the real, network-
/// touching path; without it, `run` refuses to start.
@main
struct BenchmarkRunnerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "BenchmarkRunner", subcommands: [Run.self, BudgetCheck.self])
}

/// Reads a real MutantKit `plan.json` (already produced, before any
/// mutation execution starts) and fails closed if the resulting estimate
/// exceeds the given budget — meant to run between `mutantkit plan` and
/// `muter build`/`muter run` in a calibration or scouting workflow, so a
/// mis-scoped run (e.g. a glob matching a whole module instead of one
/// file) is caught before the expensive part, not after a timeout.
struct BudgetCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "budget-check")

    @Option(name: .long, help: "Path to a real plan.json produced by `mutantkit plan`.") var planPath: String
    @Option(name: .long, help: "Project id, for the printed estimate only.") var projectID: String
    @Option(name: .long, help: "Source scope glob(s) used for this run, for the printed estimate only.") var sourceScope: [String] = []
    @Option(name: .long, help: "A real Muter candidate count from a prior run of this exact scope, if known.") var muterCandidates: Int?
    @Option(name: .long, help: "Fail closed if the estimated total exceeds this many minutes.") var maxEstimatedMinutes: Double?
    @Option(name: .long, help: "Fail closed if MutantKit's own real candidate count exceeds this.") var maxMutantkitCandidates: Int?
    @Option(name: .long, help: "Fail closed if the known Muter candidate count exceeds this.") var maxMuterCandidates: Int?
    @Flag(name: .long, help: "Bypass both checks — must be explicit, never a silent default.") var allowBudgetOverride = false

    func run() throws {
        let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
        guard let plan = try JSONSerialization.jsonObject(with: planData) as? [String: Any],
              let mutations = plan["mutations"] as? [[String: Any]]
        else {
            print("budget-check: \(planPath) is not a well-formed plan.json (no 'mutations' array)")
            throw ExitCode.failure
        }

        let estimate = BenchmarkCostModel.estimate(
            projectID: projectID, sourceScope: sourceScope, mutantKitCandidates: mutations.count, muterCandidates: muterCandidates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? encoder.encode(estimate), let string = String(data: json, encoding: .utf8) {
            print(string)
        }

        do {
            try BenchmarkBudgetGuard.requireWithinBudget(
                estimate, maxEstimatedMinutes: maxEstimatedMinutes, maxMutantKitCandidates: maxMutantkitCandidates,
                maxMuterCandidates: maxMuterCandidates, allowOverride: allowBudgetOverride
            )
        } catch {
            print("budget-check FAILED: \(error)")
            throw ExitCode.failure
        }
        print("budget-check passed (confidence: \(estimate.confidence.rawValue), lower-bound based on one prior calibration run).")
    }
}

struct Run: AsyncParsableCommand {
    @Option(name: .long, help: "Path to the benchmark manifest.") var manifest: String = "Benchmarks/manifest.json"
    @Option(name: .long, help: "Directory to write results into (a lane subdirectory is appended automatically).")
    var output: String = "Benchmarks/results"
    @Option(name: .long, help: "Path to the mutantkit binary.") var mutantkitBinary: String = ".build/release/mutantkit"
    @Option(name: .long, help: "Path to the muter binary.") var muterBinary: String = "/usr/local/bin/muter"
    @Option(name: .long, help: "Runs per mode (median is reported).") var runsPerMode: Int = 3
    @Option(name: .long, help: "Per-invocation timeout, seconds.") var timeoutSeconds: Double = 3600
    @Option(
        name: .long,
        help: "Which lane to run: currentEnvironment (whatever toolchain is installed now) or crossToolCompatibility (a pinned one)."
    )
    var lane: BenchmarkToolchainProfile.Purpose = .currentEnvironment
    @Option(name: .long, help: "DEVELOPER_DIR to pin for the crossToolCompatibility lane — required when --lane crossToolCompatibility.")
    var developerDirectory: String?
    @Flag(name: .long, help: "Only validate the manifest and print the corpus; do not clone or run anything.")
    var dryRun: Bool = false
    @Option(name: .long, help: ArgumentHelp(Self.toolOrderHelp))
    var toolOrder: [String] = []
    @Option(name: .long, help: ArgumentHelp(Self.mutantkitSourceIncludeHelp))
    var mutantkitSourceInclude: [String] = []
    @Option(name: .long, help: "Disable these MutantKit operator IDs in the generated config (repeatable).")
    var mutantkitDisableOperator: [String] = []
    @Option(name: .long, help: ArgumentHelp(Self.muterFilesToMutateHelp))
    var muterFilesToMutate: [String] = []
    @Option(name: .long, help: "Restrict Muter to only these operator IDs (Muter's own rawValues, e.g. RelationalOperatorReplacement).")
    var muterOperator: [String] = []
    @Option(name: .long, help: ArgumentHelp(Self.modesHelp))
    var modes: [String] = []

    func run() async throws {
        guard dryRun || ProcessInfo.processInfo.environment["MUTANTKIT_BENCHMARK"] == "1" else {
            print("Refusing to run the real benchmark without MUTANTKIT_BENCHMARK=1 (clones and builds real external projects).")
            throw ExitCode.failure
        }
        if lane == .crossToolCompatibility, developerDirectory == nil {
            print("--lane crossToolCompatibility requires --developer-directory to pin a specific toolchain.")
            throw ExitCode.failure
        }

        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let loadedManifest = try BenchmarkManifest.decode(from: manifestData)
        print("Loaded \(loadedManifest.projects.count) project(s) from \(manifest).")
        for project in loadedManifest.projects {
            print("  - \(project.id) @ \(project.commitSHA.prefix(12)) [\(project.tags.joined(separator: ", "))]")
        }
        if dryRun {
            print("--dry-run: not cloning or running anything.")
            return
        }

        let profile = try makeProfile()
        let outputDirectory = profile.resultDirectory(under: URL(fileURLWithPath: output))
        let parsedToolOrder = try parseToolOrder()
        let parsedModes = try parseModes()

        let orchestrator = BenchmarkOrchestrator(
            mutantKit: MutantKitBenchmarkTool(
                binaryURL: URL(fileURLWithPath: mutantkitBinary), toolchainProfile: profile,
                sourceInclude: mutantkitSourceInclude.isEmpty ? nil : mutantkitSourceInclude, disableOperators: mutantkitDisableOperator
            ),
            muter: MuterBenchmarkTool(
                binaryURL: URL(fileURLWithPath: muterBinary), toolchainProfile: profile,
                filesToMutate: muterFilesToMutate, operatorIDs: muterOperator
            ),
            toolchainProfile: profile, runsPerMode: runsPerMode, timeoutSeconds: timeoutSeconds, outputDirectory: outputDirectory,
            toolOrder: parsedToolOrder, modes: parsedModes
        )
        try await orchestrator.run(manifest: loadedManifest)
    }

    private static let toolOrderHelp =
        "Per-mode tool execution order override, as mode:order (e.g. --tool-order warm:muterFirst). "
            + "Repeatable; a mode not given here defaults to mutantKitFirst."
    private static let mutantkitSourceIncludeHelp =
        "Restrict MutantKit's own generated config to this sources.include glob (repeatable). Bounds a real corpus "
            + "project's mutation surface without a separate fixture — e.g. one small module for a calibration run."
    private static let muterFilesToMutateHelp =
        "Restrict Muter to only these files, passed as --files-to-mutate (repeatable). Muter's adapter already runs "
            + "with --skip-coverage, so without this a real corpus project is mutated across every file it contains."
    private static let modesHelp =
        "Restrict which modes run (cold/warm/incremental, repeatable) — defaults to all three. "
            + "Exists for a scouting run's own cold-only-first gate."

    private func parseToolOrder() throws -> [BenchmarkMode: ToolExecutionOrder] {
        var result: [BenchmarkMode: ToolExecutionOrder] = [:]
        for entry in toolOrder {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let mode = BenchmarkMode(rawValue: String(parts[0])),
                  let order = ToolExecutionOrder(rawValue: String(parts[1]))
            else {
                print("--tool-order entry \"\(entry)\" is not a valid mode:order pair (mode: cold|warm|incremental, order: mutantKitFirst|muterFirst).")
                throw ExitCode.failure
            }
            result[mode] = order
        }
        return result
    }

    private func parseModes() throws -> [BenchmarkMode] {
        guard !modes.isEmpty else { return BenchmarkMode.allCases }
        return try modes.map { entry in
            guard let mode = BenchmarkMode(rawValue: entry) else {
                print("--modes entry \"\(entry)\" is not cold, warm, or incremental.")
                throw ExitCode.failure
            }
            return mode
        }
    }

    private func makeProfile() throws -> BenchmarkToolchainProfile {
        let environment = ToolchainEnvironmentBuilder.environment(
            base: ProcessInfo.processInfo.environment,
            profile: BenchmarkToolchainProfile(
                id: "probe", purpose: lane, developerDirectory: developerDirectory, swiftExecutable: "swift", swiftVersion: ""
            )
        )
        let observed = ToolchainDriftGuard.observe(environment: environment)
        let id = lane == .currentEnvironment
            ? BenchmarkPreflight.currentEnvironment().identifier
            : (developerDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pinned").replacingOccurrences(of: " ", with: "_")

        return BenchmarkToolchainProfile(
            id: id, purpose: lane, developerDirectory: developerDirectory, swiftExecutable: observed.swiftExecutablePath ?? "swift",
            swiftVersion: observed.swiftVersion, xcodeBuildVersion: observed.xcodeBuildVersion
        )
    }
}

extension BenchmarkToolchainProfile.Purpose: ExpressibleByArgument {}
