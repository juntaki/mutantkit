import Foundation

public enum MutantKitBenchmarkToolError: Error, CustomStringConvertible {
    case binaryNotFound(String)

    public var description: String {
        switch self {
        case let .binaryNotFound(path): "mutantkit binary not found at \(path); build it with `swift build -c release` first"
        }
    }
}

/// Drives the real `mutantkit` executable as an external process — never
/// `MutationExecution`/`MutationModel` in-process. `binaryURL` defaults to
/// the release build product next to this benchmark runner's own binary,
/// but is overridable so a CI job can point at a pinned release artifact
/// instead of whatever happens to be freshest in `.build`.
public struct MutantKitBenchmarkTool: MutationBenchmarkTool {
    public let identity: BenchmarkToolIdentity
    public let toolchainProfile: BenchmarkToolchainProfile
    private let binaryURL: URL
    private let toolRunner: ToolRunner
    /// Restricts the generated config's `sources.include` — `nil` keeps
    /// the existing default (`Sources/**`). Exists so a calibration run
    /// can bound a real corpus project's own mutation surface (e.g. one
    /// small module) without inventing a separate fixture, the same real
    /// project a full corpus run would otherwise use.
    private let sourceInclude: [String]?
    /// Operator IDs to disable in the generated config — empty keeps the
    /// existing default (every `defaultEnabled` operator under the
    /// `default` profile).
    private let disableOperators: [String]
    /// B3.4 (rigorous-benchmark program): `execution.workers` in the
    /// generated config — `nil` omits the key entirely, which the real
    /// `mutantkit` CLI defaults to `auto` (half the core count). Exists so
    /// one raw-throughput run can be explicitly pinned to `1` (an
    /// "ENGINE/CONTROLLED" measurement, isolating the mutation engine
    /// itself from this machine's own concurrency) and compared, clearly
    /// labeled, against a separate run left at this repo's own real
    /// shipped default (`workers: 2`, see `ConfigurationLoader`'s
    /// production-profile template) — never silently comparing one tool's
    /// concurrency=1 number against another tool's own higher default and
    /// calling the difference a measure of engine speed.
    private let workers: Int?

    public init(
        binaryURL: URL, version: String = "unknown", toolchainProfile: BenchmarkToolchainProfile, toolRunner: ToolRunner = ToolRunner(),
        sourceInclude: [String]? = nil, disableOperators: [String] = [], workers: Int? = nil
    ) {
        self.binaryURL = binaryURL
        identity = BenchmarkToolIdentity(name: "mutantkit", version: version)
        self.toolchainProfile = toolchainProfile
        self.toolRunner = toolRunner
        self.sourceInclude = sourceInclude
        self.disableOperators = disableOperators
        self.workers = workers
    }

    /// Every subprocess this adapter launches gets the identical toolchain
    /// environment — never left to inherit whatever `ProcessInfo` happens
    /// to carry, which could silently differ between `plan`/`run`/the
    /// differential re-run if the ambient environment changed mid-benchmark.
    private func environment() -> [String: String] {
        ToolchainEnvironmentBuilder.environment(base: ProcessInfo.processInfo.environment, profile: toolchainProfile)
    }

    public func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw MutantKitBenchmarkToolError.binaryNotFound(binaryURL.path)
        }
        // `warm`/`incremental` reuse `context.cacheDirectory` across their
        // repeated runs; `cold` is handed a fresh, empty directory by the
        // orchestrator every time, so there is nothing extra to prime here
        // beyond making sure it exists.
        try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)

        // A benchmark corpus project is a real, third-party checkout — it
        // was never authored with a `mutantkit.yml` of its own, so one is
        // written here from `BenchmarkProject`'s own fields. Only written
        // if the project does not already carry one (a corpus entry may
        // supply its own, hand-tuned config as part of its patch fixture).
        let configPath = project.directory.appendingPathComponent("mutantkit.yml")
        guard !FileManager.default.fileExists(atPath: configPath.path) else { return }
        try defaultConfiguration(for: project.project).write(to: configPath, atomically: true, encoding: .utf8)
    }

    func defaultConfiguration(for project: BenchmarkProject) -> String {
        let include = (sourceInclude ?? ["Sources/**"]).map { "\"\($0)\"" }.joined(separator: ", ")
        let disable = disableOperators.map { "\"\($0)\"" }.joined(separator: ", ")
        // Omitted entirely when `nil`, matching the real CLI's own
        // omitted-key-means-`auto` behavior rather than writing a
        // placeholder value this adapter would have to invent.
        let workersLine = workers.map { "\n  workers: \($0)" } ?? ""
        switch project.projectKind {
        case .swiftPackage:
            return """
            version: 1
            project:
              kind: swiftPackageMacOS
            sources:
              include: [\(include)]
            operators:
              profile: default
              disable: [\(disable)]
            execution:
              strategy: schemata\(workersLine)
            reports: [json]
            """
        case .xcodeProject, .xcodeWorkspace:
            let kind = project.projectKind == .xcodeProject ? "xcodeProject" : "xcodeWorkspace"
            return """
            version: 1
            project:
              kind: \(kind)
              scheme: \(project.scheme ?? "")
              destination: \(project.destination ?? "platform=macOS")
              configuration: \(project.configuration ?? "Debug")
            sources:
              include: [\(sourceInclude?.map { "\"\($0)\"" }.joined(separator: ", ") ?? "\"**/*.swift\"")]
            operators:
              profile: default
              disable: [\(disable)]
            execution:
              strategy: isolated\(workersLine)
            reports: [json]
            """
        }
    }

    public func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
        let planPath = context.cacheDirectory.appendingPathComponent("plan-\(context.runIndex).json")
        let reportPath = context.cacheDirectory.appendingPathComponent("report-\(context.runIndex).json")

        let plan = try await toolRunner.run(ToolInvocation(
            executableURL: binaryURL, arguments: ["plan", "--output", planPath.path],
            workingDirectory: project.directory, environment: environment(), timeoutSeconds: context.timeoutSeconds
        ))
        guard plan.exitCode == 0 else {
            return RawBenchmarkRun(
                tool: identity, projectID: project.project.id, projectCommit: project.project.commitSHA, mode: context.mode,
                execution: plan, resources: .unavailable, reportData: nil
            )
        }

        let collector = MeasurementCollector()
        let bytesBefore = MeasurementCollector.directorySizeBytes(project.directory)
        let runResult = try await toolRunner.run(
            ToolInvocation(
                executableURL: binaryURL,
                arguments: ["run", "--plan", planPath.path, "--report", "json", "--output", reportPath.path],
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
            execution: runResult, resources: resources, reportData: reportData
        )
    }

    /// Re-runs the identical, already-produced `planPath` under
    /// `execution.strategy: isolated` (never re-planned — the exact same
    /// `MutationID` set, so `ResultNormalizer.compareBackends` is comparing
    /// two runs of the same mutations, not two different discoveries) —
    /// the real differential check `BenchmarkGate`'s `backendDisagreements`
    /// requirement needs, computed for real rather than left `nil`.
    /// `nil` only when the schemata run itself produced no comparable
    /// report to re-run against.
    public func runIsolatedDifferential(
        project: MaterializedBenchmarkProject, context: BenchmarkRunContext, planPath: URL
    ) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: planPath.path) else { return nil }

        let isolatedConfigPath = context.cacheDirectory.appendingPathComponent("mutantkit-isolated.yml")
        try isolatedConfiguration(for: project.project).write(to: isolatedConfigPath, atomically: true, encoding: .utf8)

        let reportPath = context.cacheDirectory.appendingPathComponent("report-isolated-differential-\(context.runIndex).json")
        let result = try await toolRunner.run(ToolInvocation(
            executableURL: binaryURL,
            arguments: [
                "run", "--config", isolatedConfigPath.path, "--plan", planPath.path, "--report", "json", "--output", reportPath.path
            ],
            workingDirectory: project.directory, environment: environment(), timeoutSeconds: context.timeoutSeconds
        ))
        guard result.exitCode == 0 || FileManager.default.fileExists(atPath: reportPath.path) else { return nil }
        return try? Data(contentsOf: reportPath)
    }

    func isolatedConfiguration(for project: BenchmarkProject) -> String {
        defaultConfiguration(for: project).replacingOccurrences(of: "strategy: schemata", with: "strategy: isolated")
    }
}
