import Foundation

public enum MuterBenchmarkToolError: Error, CustomStringConvertible {
    case binaryNotFound(String)

    public var description: String {
        switch self {
        case let .binaryNotFound(path): "muter binary not found at \(path); install it (e.g. `brew install muter-mutation-testing/formulae/muter`) first"
        }
    }
}

/// Drives the real `muter` executable as an external process — same
/// external-process discipline `MutantKitBenchmarkTool` follows, so neither
/// tool gets an unfair in-process shortcut the other cannot also have.
///
/// Muter has no equivalent of MutantKit's verifier-proven `activation`/
/// `execution` evidence — its own report never claims to prove a mutant
/// was compiled into the tested binary or that the mutated line actually
/// ran. `ResultNormalizer` reflects that as `nil` (not observable by this
/// tool), never as `0` or as a value borrowed from MutantKit's own
/// definition of those terms.
public struct MuterBenchmarkTool: MutationBenchmarkTool {
    public let identity: BenchmarkToolIdentity
    public let toolchainProfile: BenchmarkToolchainProfile
    private let binaryURL: URL
    private let toolRunner: ToolRunner
    /// Passed as `--files-to-mutate` — empty keeps Muter's own default
    /// (every discovered file). Exists for the same reason as
    /// `MutantKitBenchmarkTool`'s `sourceInclude`: Muter's adapter already
    /// runs with `--skip-coverage`, so without this a real corpus project
    /// is mutated across every file it contains, unbounded.
    private let filesToMutate: [String]
    /// Passed as `--operators` — empty keeps Muter's own default (every
    /// registered operator: RelationalOperatorReplacement,
    /// RemoveSideEffects, ChangeLogicalConnector, SwapTernary). Muter has
    /// no equivalent of MutantKit's `disable`/`profile` config keys for
    /// this, so it is a CLI argument here instead of the written config.
    private let operatorIDs: [String]

    public init(
        binaryURL: URL, version: String = "unknown", toolchainProfile: BenchmarkToolchainProfile, toolRunner: ToolRunner = ToolRunner(),
        filesToMutate: [String] = [], operatorIDs: [String] = []
    ) {
        self.binaryURL = binaryURL
        identity = BenchmarkToolIdentity(name: "muter", version: version)
        self.toolchainProfile = toolchainProfile
        self.toolRunner = toolRunner
        self.filesToMutate = filesToMutate
        self.operatorIDs = operatorIDs
    }

    private func environment() -> [String: String] {
        ToolchainEnvironmentBuilder.environment(base: ProcessInfo.processInfo.environment, profile: toolchainProfile)
    }

    public func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw MuterBenchmarkToolError.binaryNotFound(binaryURL.path)
        }
        try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)

        // Muter's own config (`muter.conf.yml`) — like MutantKit's, a
        // benchmark corpus checkout carries none of its own, so a minimal
        // one is written unless the project already has one. Real schema
        // confirmed via `muter init`'s own generated output (not guessed):
        // `arguments`/`executable`/`exclude`/`excludeCalls`, never
        // `excludeCallList`/`excludeFileList`.
        let configPath = project.directory.appendingPathComponent("muter.conf.yml")
        guard !FileManager.default.fileExists(atPath: configPath.path) else { return }
        try """
        arguments:
        - test
        executable: /usr/bin/swift
        exclude:
        - Package.swift
        excludeCalls: []
        """.write(to: configPath, atomically: true, encoding: .utf8)
    }

    public func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
        let reportPath = context.cacheDirectory.appendingPathComponent("muter-report-\(context.runIndex).json")

        var arguments = ["run", "--format", "json", "--output", reportPath.path, "--skip-coverage", "--skip-update-check"]
        // Muter's own `--files-to-mutate` option is declared without
        // `.upToNextOption`, so each value needs its own repeated flag —
        // unlike `--operators`, which Muter declares `parsing: .upToNextOption`
        // and therefore takes every value after one flag occurrence.
        for file in filesToMutate {
            arguments.append("--files-to-mutate")
            arguments.append(file)
        }
        if !operatorIDs.isEmpty {
            arguments.append("--operators")
            arguments.append(contentsOf: operatorIDs)
        }

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
