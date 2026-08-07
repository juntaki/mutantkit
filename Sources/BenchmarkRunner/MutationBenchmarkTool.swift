import Foundation

public struct BenchmarkToolIdentity: Codable, Sendable, Hashable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public enum BenchmarkMode: String, Codable, Sendable, CaseIterable {
    case cold
    case warm
    case incremental
}

/// Which tool runs first within one mode's own pair of runs — real
/// ordering methodology, not cosmetic: running the same tool first in
/// every mode could let one tool's own process consistently warm shared
/// machine-level state (filesystem cache, DNS, package-manager download
/// cache) that the other never benefits from, silently biasing a
/// comparison. `BenchmarkOrchestrator` defaults every mode to
/// `.mutantKitFirst` unless a caller explicitly overrides it per mode.
public enum ToolExecutionOrder: String, Codable, Sendable {
    case mutantKitFirst
    case muterFirst
}

/// Everything a `MutationBenchmarkTool` needs about the run it is being
/// asked to perform, beyond the project itself — bundled so `prepare`/`run`
/// each take one thing rather than an ever-growing parameter list.
public struct BenchmarkRunContext: Sendable {
    public let mode: BenchmarkMode
    public let runIndex: Int
    /// Where this tool may keep its own cache/derived-data between calls —
    /// `cold` mode uses a fresh, empty directory every time; `warm` and
    /// `incremental` reuse the same one across the runs in their group so
    /// the tool's own cache is genuinely warm on the second and third call.
    public let cacheDirectory: URL
    public let timeoutSeconds: Double
    /// The incremental-mode patch file, `nil` for `cold`/`warm`.
    public let patchFile: URL?

    public init(mode: BenchmarkMode, runIndex: Int, cacheDirectory: URL, timeoutSeconds: Double, patchFile: URL? = nil) {
        self.mode = mode
        self.runIndex = runIndex
        self.cacheDirectory = cacheDirectory
        self.timeoutSeconds = timeoutSeconds
        self.patchFile = patchFile
    }
}

/// What one tool invocation produced, before `ResultNormalizer` turns it
/// into a `MutationBenchmarkMeasurement` — the tool's own raw report
/// content (JSON, XML, whatever it emits) plus everything `ToolRunner`
/// observed about the process itself, kept separate so a malformed or
/// missing report never gets silently coerced into a "successful, zero
/// mutants" measurement.
public struct RawBenchmarkRun: Sendable {
    public let tool: BenchmarkToolIdentity
    public let projectID: String
    public let projectCommit: String
    public let mode: BenchmarkMode
    public let execution: ToolExecutionResult
    public let resources: ResourceMeasurement
    /// The tool's own report file content, if it produced one and this
    /// adapter located it — `nil` when the tool crashed, timed out, or
    /// wrote no report the adapter could find, which `ResultNormalizer`
    /// must treat as "every count unknown," never "every count zero."
    public let reportData: Data?

    public init(
        tool: BenchmarkToolIdentity, projectID: String, projectCommit: String, mode: BenchmarkMode,
        execution: ToolExecutionResult, resources: ResourceMeasurement, reportData: Data?
    ) {
        self.tool = tool
        self.projectID = projectID
        self.projectCommit = projectCommit
        self.mode = mode
        self.execution = execution
        self.resources = resources
        self.reportData = reportData
    }
}

/// One tool under benchmark — MutantKit and Muter each get their own
/// conformance, both driving the real CLI as an external process
/// (`ToolRunner`), never an in-process shortcut. Neither adapter may carry
/// its own bespoke timeout or exclusion list that the other does not also
/// get the chance to use — `BenchmarkRunContext.timeoutSeconds` is the one
/// shared timeout both `run` implementations must honor; if a tool
/// genuinely needs something different, that difference belongs in the
/// manifest or the resulting report, stated explicitly, never buried in
/// adapter-private defaults.
public protocol MutationBenchmarkTool: Sendable {
    var identity: BenchmarkToolIdentity { get }

    /// Whatever setup this tool needs before the first `run` for a given
    /// project/mode — installing dependencies, resolving packages, priming
    /// a cache directory. Called once per `(project, mode)` pair, before
    /// any of that group's repeated runs.
    func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws

    func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun
}
