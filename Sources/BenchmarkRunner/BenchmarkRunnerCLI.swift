import ArgumentParser
import Foundation

/// The `BenchmarkRunner` executable. Off by default the same way MutantKit's
/// own acceptance suites are — a real run clones and builds real external
/// projects, twice per tool per mode, and can take a very long time for the
/// larger corpus entries. `MUTANTKIT_BENCHMARK=1` gates the real, network-
/// touching path; without it, `run` refuses to start.
@main
struct BenchmarkRunnerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "BenchmarkRunner", subcommands: [Run.self, BudgetCheck.self, BuildCorpus.self, RawThroughput.self]
    )
}

/// Phase B3 (rigorous-benchmark program): drives `RawThroughputBenchmark`
/// against an already-materialized real project directory — deliberately
/// simpler than `Run`'s own manifest-driven, fresh-clone-per-mode flow,
/// since B3's own contract fixes the project/commit/scope ahead of time
/// (`Research/rigorous-benchmark-2026-08/B0-CONTRACT.md`) and reuses
/// whatever real checkout this program already has on disk rather than
/// re-cloning for every measurement.
struct RawThroughput: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raw-throughput",
        abstract: "Phase B3: rotation-scheduled raw throughput across an already-materialized real project."
    )

    @Option(name: .long, help: "Real project checkout directory (already cloned, at the exact commit under measurement).") var projectDirectory: String
    @Option(name: .long, help: "Project identifier, for the printed report only.") var projectID: String
    @Option(name: .long, help: "The commit this checkout is at.") var repositoryCommit: String
    @Option(name: .long, help: "Path to the mutantkit binary. Omit to skip MutantKit.") var mutantkitBinary: String?
    @Option(name: .long, help: "Path to the muter binary. Omit to skip Muter.") var muterBinary: String?
    @Option(name: .long, help: "Path to the swift-mutation-testing binary. Omit to skip it.") var swiftMutationTestingBinary: String?
    @Option(name: .long, help: "Restrict MutantKit's own generated config to this sources.include glob (repeatable).") var mutantkitSourceInclude: [String] = []
    @Option(
        name: .long,
        help: "B3.4: pin MutantKit's execution.workers explicitly (e.g. 1 for an ENGINE/CONTROLLED run). Omit to leave the real CLI's own auto default (this repo's own shipped PRACTICAL/DEFAULT profile is workers: 2, set via --mutantkit-workers 2, not this flag's own omission)."
    ) var mutantkitWorkers: Int?
    @Option(name: .long, help: "Restrict Muter to only these files, --files-to-mutate (repeatable).") var muterFilesToMutate: [String] = []
    @Option(name: .long, help: "Restrict swift-mutation-testing to this single --sources-path.") var swiftMutationTestingSourcesPath: String?
    @Option(name: .long, help: "swift-mutation-testing --exclude glob(s) (repeatable) — --sources-path is a directory only; excluding every sibling file is the real way to scope it to one file.") var swiftMutationTestingExclude: [String] = []
    @Option(name: .long, help: "How many full rotations to run. B0's own contract specifies a minimum of 5.") var repetitions: Int = 5
    @Option(name: .long, help: "Per-invocation timeout, seconds.") var timeoutSeconds: Double = 3600
    @Option(name: .long, help: "Where to write the raw JSON result.") var output: String
    @Option(
        name: .long,
        help: "B3.6: tool name(s) (repeatable) for which 0 discovered mutants is the fixture-documented, expected, valid result for this exact scope — e.g. a deliberately mutation-free file. Every other tool still fails closed on an unexplained 0."
    ) var expectZeroMutants: [String] = []

    func run() async throws {
        guard ProcessInfo.processInfo.environment["MUTANTKIT_BENCHMARK"] == "1" else {
            print("Refusing to run without MUTANTKIT_BENCHMARK=1 (drives real tools against a real project).")
            throw ExitCode.failure
        }

        let profile = BenchmarkToolchainProfile(
            id: "raw-throughput", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: ""
        )
        let project = MaterializedBenchmarkProject(
            project: BenchmarkProject(
                id: projectID, repositoryURL: "n/a (pre-materialized)", commitSHA: repositoryCommit, projectKind: .swiftPackage
            ),
            directory: URL(fileURLWithPath: projectDirectory)
        )

        var tools: [(name: String, tool: any MutationBenchmarkTool)] = []
        if let mutantkitBinary {
            tools.append(("mutantkit", MutantKitBenchmarkTool(
                binaryURL: URL(fileURLWithPath: mutantkitBinary), toolchainProfile: profile,
                sourceInclude: mutantkitSourceInclude.isEmpty ? nil : mutantkitSourceInclude, workers: mutantkitWorkers
            )))
        }
        if let muterBinary {
            tools.append(("muter", MuterBenchmarkTool(
                binaryURL: URL(fileURLWithPath: muterBinary), toolchainProfile: profile, filesToMutate: muterFilesToMutate
            )))
        }
        if let swiftMutationTestingBinary {
            tools.append(("swift-mutation-testing", SwiftMutationTestingBenchmarkTool(
                binaryURL: URL(fileURLWithPath: swiftMutationTestingBinary), toolchainProfile: profile,
                sourcesPath: swiftMutationTestingSourcesPath, excludePatterns: swiftMutationTestingExclude
            )))
        }
        guard !tools.isEmpty else {
            print("raw-throughput: no tool binaries given (at least one of --mutantkit-binary/--muter-binary/--swift-mutation-testing-binary is required).")
            throw ExitCode.failure
        }

        print("=== Phase B3 raw throughput: \(projectID) @ \(repositoryCommit.prefix(12)) ===")
        print("tools: \(tools.map(\.name).joined(separator: ", ")), repetitions: \(repetitions)")
        // B3.4: MutantKit's own concurrency is the only one of the three
        // this harness can pin — Muter and swift-mutation-testing each
        // use their own single documented default (no benchmark-visible
        // concurrency knob), per B0's own contract. Printed and recorded
        // explicitly so a reader never assumes two runs used the same
        // concurrency question just because they used the same tool.
        let mutantKitConcurrencyLabel = mutantkitWorkers.map { $0 == 1 ? "ENGINE/CONTROLLED (workers: 1)" : "workers: \($0)" } ?? "PRACTICAL/DEFAULT (auto)"
        if mutantkitBinary != nil {
            print("mutantkit concurrency profile: \(mutantKitConcurrencyLabel)")
        }

        let cacheDirectory = URL(fileURLWithPath: projectDirectory).appendingPathComponent(".benchmark-cache-raw-throughput")
        let zeroMutantsExpected = Dictionary(uniqueKeysWithValues: expectZeroMutants.map { ($0, true) })
        let (repetitionResults, summaries) = try await RawThroughputBenchmark.run(
            tools: tools, project: project, mode: .cold, repetitions: repetitions, cacheDirectory: cacheDirectory,
            timeoutSeconds: timeoutSeconds, zeroMutantsExpected: zeroMutantsExpected
        )

        for summary in summaries {
            print("--- \(summary.tool) ---")
            print("  wall (s) by repetition: \(summary.wallSecondsByRepetition.map { String(format: "%.1f", $0) })")
            print("  median wall (s): \(summary.medianWallSeconds.map { String(format: "%.1f", $0) } ?? "n/a")")
            print("  discovered: \(summary.discoveredCount.map(String.init) ?? "disagreed across repetitions — see raw output")")
            print("  median mutants/sec: \(summary.medianMutantsPerSecond.map { String(format: "%.3f", $0) } ?? "n/a")")
            for violation in summary.violations {
                print("  ⚠️ INVALID (B3.6): \(violation.description)")
            }
        }

        struct Report: Encodable {
            let projectID: String
            let repositoryCommit: String
            let repetitions: Int
            /// B3.4: which concurrency question this specific MutantKit
            /// measurement answers — `nil` when MutantKit did not run at
            /// all this invocation. Never compared against Muter's or
            /// swift-mutation-testing's own numbers as if it meant the
            /// same thing; those tools have no equivalent knob here.
            let mutantKitConcurrencyProfile: String?
            let summaries: [SummaryReport]
        }
        struct SummaryReport: Encodable {
            let tool: String
            let wallSecondsByRepetition: [Double]
            let medianWallSeconds: Double?
            let discoveredCount: Int?
            let medianMutantsPerSecond: Double?
            let violations: [String]
        }
        let report = Report(
            projectID: projectID, repositoryCommit: repositoryCommit, repetitions: repetitions,
            mutantKitConcurrencyProfile: mutantkitBinary != nil ? mutantKitConcurrencyLabel : nil,
            summaries: summaries.map {
                SummaryReport(
                    tool: $0.tool, wallSecondsByRepetition: $0.wallSecondsByRepetition, medianWallSeconds: $0.medianWallSeconds,
                    discoveredCount: $0.discoveredCount, medianMutantsPerSecond: $0.medianMutantsPerSecond,
                    violations: $0.violations.map(\.description)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        print("Wrote \(output).")
        _ = repetitionResults
    }
}

/// Phase B1 (rigorous-benchmark program): builds a real
/// `CanonicalMutationCorpus` from each tool's own already-produced real
/// report file — a standalone, reusable subcommand rather than a
/// throwaway script, since this needs to run again for every corpus
/// project this program's own B0 contract names (swift-numerics,
/// swift-algorithms, a real production iOS app), not just once.
struct BuildCorpus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-corpus",
        abstract: "Build a canonical N-way matched-mutant corpus from each tool's own real report file."
    )

    @Option(name: .long, help: "Project identifier, e.g. swift-numerics.") var projectID: String
    @Option(name: .long, help: "The commit the reports below were produced against.") var repositoryCommit: String
    @Option(name: .long, help: ArgumentHelp(Self.mutantkitReportHelp)) var mutantkitReport: String?
    @Option(name: .long, help: ArgumentHelp(Self.muterReportHelp)) var muterReport: [String] = []
    @Option(name: .long, help: "Path to a swift-mutation-testing report.json.") var swiftMutationTestingReport: String?
    /// Only meaningful together with `--muter-report`: `normalizeMuterReport`
    /// resolves Muter's own real relative paths by probing this directory
    /// for each candidate suffix — see that function's own doc comment
    /// (Phase C13) for why. Omit when comparing against a checkout that
    /// no longer exists; falls back to Muter's own bare basename in that
    /// case, exactly as the underlying function already does.
    @Option(name: .long, help: "Real project checkout directory, for resolving Muter's own real relative paths.") var projectDirectory: String?
    @Option(name: .long, help: "Where to write the corpus JSON.") var output: String

    func run() throws {
        var mutantsByTool: [String: [NormalizedMutant]] = [:]

        if let mutantkitReport {
            let data = try Data(contentsOf: URL(fileURLWithPath: mutantkitReport))
            mutantsByTool["mutantkit"] = try ResultNormalizer.normalizeMutantKitReport(data).mutants
        }
        if !muterReport.isEmpty {
            let directory = projectDirectory.map { URL(fileURLWithPath: $0) }
            var combined: [NormalizedMutant] = []
            for path in muterReport {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                combined.append(contentsOf: try ResultNormalizer.normalizeMuterReport(data, projectDirectory: directory))
            }
            mutantsByTool["muter"] = combined
        }
        if let swiftMutationTestingReport {
            let data = try Data(contentsOf: URL(fileURLWithPath: swiftMutationTestingReport))
            mutantsByTool["swift-mutation-testing"] = try ResultNormalizer.normalizeSwiftMutationTestingReport(data)
        }

        guard mutantsByTool.count >= 2 else {
            print("build-corpus: at least 2 tool reports are required for a real intersection (got \(mutantsByTool.count)).")
            throw ExitCode.failure
        }

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: projectID, repositoryCommit: repositoryCommit, mutantsByTool: mutantsByTool
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.corpus).write(to: URL(fileURLWithPath: output))

        print("Wrote \(result.corpus.mutations.count) canonical mutation(s) to \(output).")
        print("Tools compared: \(result.corpus.tools.joined(separator: ", "))")
        for (tool, count) in result.toolOnlyCounts.sorted(by: { $0.key < $1.key }) {
            print("  \(tool)-only (excluded from the corpus): \(count)")
        }
        for (tool, count) in result.ambiguousCounts.sorted(by: { $0.key < $1.key }) where count > 0 {
            print("  \(tool) ambiguous (disagreed with itself on the same position, excluded, fail-closed): \(count)")
        }
        if result.crossToolTextDisagreementCount > 0 {
            print("  cross-tool text disagreement (matched position, but tools disagree on the real text, excluded): \(result.crossToolTextDisagreementCount)")
        }
    }

    private static let mutantkitReportHelp = "Path to a real MutantKit report.json."
    private static let muterReportHelp =
        "Path(s) to real Muter report.json files (repeatable — Muter's own CLI runs one file/scope at a time, "
            + "so a corpus spanning several files needs several of its own reports merged here)."
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
    @Option(
        name: .long,
        help: "Path to the swift-mutation-testing binary (ericodx/swift-mutation-testing). Omit to skip this tool entirely."
    )
    var swiftMutationTestingBinary: String?
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
    @Option(name: .long, help: "Restrict swift-mutation-testing to this single --sources-path root directory (its own scoping mechanism).")
    var swiftMutationTestingSourcesPath: String?
    @Option(name: .long, help: "Restrict swift-mutation-testing to only these operator IDs (its own rawValues, e.g. RelationalOperatorReplacement).")
    var swiftMutationTestingOperator: [String] = []
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
            toolOrder: parsedToolOrder, modes: parsedModes,
            // Phase C13: `nil` (the default, when --swift-mutation-testing-binary
            // is not passed) skips this optional third tool entirely,
            // exactly like `--dry-run` skips the whole run — no existing
            // invocation is required to provide this binary.
            swiftMutationTesting: swiftMutationTestingBinary.map {
                SwiftMutationTestingBenchmarkTool(
                    binaryURL: URL(fileURLWithPath: $0), toolchainProfile: profile,
                    sourcesPath: swiftMutationTestingSourcesPath, operatorIDs: swiftMutationTestingOperator
                )
            }
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
