import Foundation

public enum SwiftMutationTestingBenchmarkToolError: Error, CustomStringConvertible {
    case binaryNotFound(String)

    public var description: String {
        switch self {
        case let .binaryNotFound(path):
            "swift-mutation-testing binary not found at \(path); build it from " +
                "https://github.com/ericodx/swift-mutation-testing (`swift build -c release`) or " +
                "`brew tap ericodx/homebrew-tools && brew install swift-mutation-testing` first"
        }
    }
}

/// Drives the real `swift-mutation-testing` executable
/// (`ericodx/swift-mutation-testing`) as an external process — the same
/// external-process discipline `MuterBenchmarkTool`/`MutantKitBenchmarkTool`
/// already follow, so no tool under comparison gets an in-process shortcut
/// the others cannot also have.
///
/// Phase C13 (competitive-parity program): the user named this tool as a
/// comparison target from the start of the whole program; `BenchmarkRunner`
/// only ever had adapters for MutantKit and Muter. Every CLI flag and the
/// report schema below are confirmed against the real tool — a fresh
/// `git clone` + `swift build -c release` of `ericodx/swift-mutation-testing`
/// (default branch), its own `--help` output, and its own
/// `Docs/STRYKER-COMPATIBILITY.md` (the real, documented JSON report shape
/// `--output` writes) — never guessed from the README's prose summary
/// alone, matching this codebase's own established standard for every
/// other competitor adapter.
///
/// Unlike Muter, this tool's own report genuinely carries real
/// `originalText`/`replacement` fields (confirmed in
/// `Docs/STRYKER-COMPATIBILITY.md`) and real 1-based `line`/`column`
/// (also confirmed there) — so `ResultNormalizer
/// .normalizeSwiftMutationTestingReport` does not need the same
/// filesystem-probing relative-path workaround Muter's own normalizer
/// needed: `files` dictionary keys are already documented as real paths
/// relative to `projectRoot`.
public struct SwiftMutationTestingBenchmarkTool: MutationBenchmarkTool {
    public let identity: BenchmarkToolIdentity
    public let toolchainProfile: BenchmarkToolchainProfile
    private let binaryURL: URL
    private let toolRunner: ToolRunner
    /// Passed as `--sources-path` — `nil` keeps the tool's own default
    /// (the whole project). Exists for the same reason
    /// `MuterBenchmarkTool.filesToMutate`/`MutantKitBenchmarkTool
    /// .sourceInclude` do: bounding a real corpus project's mutation
    /// surface for a calibration run without inventing a separate
    /// fixture. Unlike Muter's per-file repeatable `--files-to-mutate`,
    /// this tool only exposes a single root directory (confirmed via its
    /// own `--help`) — a real, narrower scoping mechanism, not this
    /// adapter's own limitation.
    private let sourcesPath: String?
    /// Passed as `--operator` (repeatable) — empty keeps the tool's own
    /// default (every operator active).
    private let operatorIDs: [String]
    /// Passed as `--exclude` (repeatable) — glob patterns for files to
    /// skip. Exists because `--sources-path` is a *directory* only
    /// (confirmed the hard way, Phase B3: passing a file path there
    /// silently discovers zero candidates, no error at all — the real
    /// way to scope this tool down to one specific file within a larger
    /// directory is `--sources-path <dir>` plus `--exclude` for every
    /// sibling file).
    private let excludePatterns: [String]

    public init(
        binaryURL: URL, version: String = "unknown", toolchainProfile: BenchmarkToolchainProfile, toolRunner: ToolRunner = ToolRunner(),
        sourcesPath: String? = nil, operatorIDs: [String] = [], excludePatterns: [String] = []
    ) {
        self.binaryURL = binaryURL
        identity = BenchmarkToolIdentity(name: "swift-mutation-testing", version: version)
        self.toolchainProfile = toolchainProfile
        self.toolRunner = toolRunner
        self.sourcesPath = sourcesPath
        self.operatorIDs = operatorIDs
        self.excludePatterns = excludePatterns
    }

    private func environment() -> [String: String] {
        ToolchainEnvironmentBuilder.environment(base: ProcessInfo.processInfo.environment, profile: toolchainProfile)
    }

    /// No config file is written here, unlike `MuterBenchmarkTool`: every
    /// setting this benchmark needs (`--scheme`/`--destination`/
    /// `--sources-path`/`--operator`/`--output`/`--no-cache`) has a real
    /// CLI flag (confirmed via `--help`), and the tool's own
    /// `.swift-mutation-testing.yml` is entirely optional — omitting it
    /// keeps this adapter simpler without losing any real capability.
    public func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw SwiftMutationTestingBenchmarkToolError.binaryNotFound(binaryURL.path)
        }
        try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)
    }

    /// Factored out of `run` so the real, exact CLI shape is directly
    /// unit-testable (Phase B3 added `excludePatterns` after a real,
    /// silent scoping mistake — `--sources-path` given a file path
    /// instead of a directory discovered zero mutants, no error at all —
    /// and a real bug there should never again only be catchable by
    /// running the real binary).
    static func arguments(
        reportPath: String, mode: BenchmarkMode, sourcesPath: String?, operatorIDs: [String], excludePatterns: [String]
    ) -> [String] {
        var arguments = ["--output", reportPath, "--quiet"]
        // This tool's own result cache lives at a fixed location under the
        // project root (`.swift-mutation-testing-cache/results.json`,
        // confirmed against its real source — no `--cache-directory` flag
        // exists to redirect it, unlike `context.cacheDirectory` for the
        // other two adapters). `cold` mode gets a fresh checkout every run
        // regardless, so `--no-cache` here is a belt-and-suspenders
        // guarantee, never a behavior change for a genuinely fresh
        // checkout; `warm`/`incremental` deliberately omit it so the
        // tool's own real cache warms naturally across the repeated runs
        // `BenchmarkOrchestrator` makes against the same reused checkout —
        // the same "reuse the checkout, let the tool's own cache do its
        // job" contract `MuterBenchmarkTool`/`MutantKitBenchmarkTool`
        // already honor via `context.cacheDirectory`.
        if mode == .cold {
            arguments.append("--no-cache")
        }
        if let sourcesPath {
            arguments.append(contentsOf: ["--sources-path", sourcesPath])
        }
        for operatorID in operatorIDs {
            arguments.append(contentsOf: ["--operator", operatorID])
        }
        for pattern in excludePatterns {
            arguments.append(contentsOf: ["--exclude", pattern])
        }
        return arguments
    }

    public func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
        let reportPath = context.cacheDirectory.appendingPathComponent("swift-mutation-testing-report-\(context.runIndex).json")
        let arguments = Self.arguments(
            reportPath: reportPath.path, mode: context.mode, sourcesPath: sourcesPath, operatorIDs: operatorIDs,
            excludePatterns: excludePatterns
        )

        let collector = MeasurementCollector()
        let bytesBefore = MeasurementCollector.directorySizeBytes(project.directory)
        let result = try await toolRunner.run(
            ToolInvocation(
                executableURL: binaryURL, arguments: arguments,
                workingDirectory: project.directory, environment: environment(), timeoutSeconds: context.timeoutSeconds
            ),
            onProcessStarted: { pid in
                Task { await collector.startSampling(rootProcessID: pid) }
            }
        )
        let resources = await collector.stopSampling(workingDirectory: project.directory, bytesBefore: bytesBefore)
        let reportData = try? Data(contentsOf: reportPath)

        return RawBenchmarkRun(
            tool: identity, projectID: project.project.id, projectCommit: project.project.commitSHA, mode: context.mode,
            execution: result, resources: resources, reportData: reportData
        )
    }
}
