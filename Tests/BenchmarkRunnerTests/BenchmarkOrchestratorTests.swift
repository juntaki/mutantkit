@testable import BenchmarkRunner
import Foundation
import Testing

/// Always succeeds with an empty status and creates the destination
/// directory on "clone" — every `ProjectMaterializer` call in these tests
/// resolves locally, so no test here touches the network.
private struct AlwaysCleanGit: GitCommandRunning {
    func run(_ arguments: [String], in directory: URL) async throws -> (exitCode: Int32, output: String) {
        if arguments.first == "clone" {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return (0, "")
    }
}

private actor CallRecorder {
    private(set) var cacheDirectories: [String] = []

    func record(_ path: String) {
        cacheDirectories.append(path)
    }
}

/// Records which tool's `run` started first, per mode — the seam
/// `toolOrder` tests use to observe execution order without a real
/// `mutantkit`/`muter` binary on `PATH`.
private actor OrderRecorder {
    private(set) var startedFirst: [BenchmarkMode: String] = [:]

    func recordStart(mode: BenchmarkMode, toolName: String) {
        if startedFirst[mode] == nil { startedFirst[mode] = toolName }
    }
}

/// Reports a fixed, tiny result every call and records the cache directory
/// it was handed — the seam these tests use to observe cold-vs-warm
/// isolation and result aggregation against the real `BenchmarkOrchestrator`,
/// without a real `mutantkit`/`muter` binary on `PATH`.
private struct FakeTool: MutationBenchmarkTool {
    let identity: BenchmarkToolIdentity
    let recorder: CallRecorder
    var orderRecorder: OrderRecorder?

    func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {}

    func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
        await recorder.record(context.cacheDirectory.path)
        await orderRecorder?.recordStart(mode: context.mode, toolName: identity.name)
        let reportJSON = Data(#"{"results": [], "integrity": {"passed": true}}"#.utf8)
        return RawBenchmarkRun(
            tool: identity, projectID: project.project.id, projectCommit: project.project.commitSHA, mode: context.mode,
            execution: ToolExecutionResult(
                exitCode: 0, standardOutput: "", standardError: "", wallSeconds: Double(context.runIndex + 1), timedOut: false, processID: 0
            ),
            resources: .unavailable, reportData: reportJSON
        )
    }
}

@Suite("BenchmarkOrchestrator")
struct BenchmarkOrchestratorTests {
    private static let project = BenchmarkProject(
        id: "example", repositoryURL: "https://example.com/example.git",
        commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
    )

    private static let testProfile = BenchmarkToolchainProfile(
        id: "test-profile", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "test"
    )

    private func makeOrchestrator(
        mutantKitRecorder: CallRecorder, muterRecorder: CallRecorder, runsPerMode: Int, outputDirectory: URL
    ) -> BenchmarkOrchestrator {
        BenchmarkOrchestrator(
            mutantKit: FakeTool(identity: BenchmarkToolIdentity(name: "mutantkit", version: "test"), recorder: mutantKitRecorder),
            muter: FakeTool(identity: BenchmarkToolIdentity(name: "muter", version: "test"), recorder: muterRecorder),
            toolchainProfile: Self.testProfile, runsPerMode: runsPerMode, timeoutSeconds: 60, outputDirectory: outputDirectory,
            materializer: ProjectMaterializer(git: AlwaysCleanGit())
        )
    }

    @Test("cold mode gets a distinct cache directory every run; warm mode reuses the same one across its runs")
    func coldRunsAreIsolatedWarmRunsAreShared() async throws {
        let mkRecorder = CallRecorder()
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantbench-orchestrator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let orchestrator = makeOrchestrator(
            mutantKitRecorder: mkRecorder, muterRecorder: CallRecorder(), runsPerMode: 3, outputDirectory: outputDirectory
        )
        try await orchestrator.run(manifest: BenchmarkManifest(schemaVersion: 1, projects: [Self.project]))

        let mkDirectories = await mkRecorder.cacheDirectories
        // cold + warm + (incremental is skipped: no fixture patch exists for "example") = 6 calls
        #expect(mkDirectories.count == 6, "\(mkDirectories)")

        let coldDirectories = Set(mkDirectories.prefix(3))
        #expect(coldDirectories.count == 3, "every cold run must get its own cache directory, never reused")

        let warmDirectories = Set(mkDirectories[3 ..< 6])
        #expect(warmDirectories.count == 1, "warm mode must reuse the same cache directory across its repeated runs")
    }

    @Test("Aggregate JSON and both reports are written after a run")
    func writesAggregateAndReports() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantbench-orchestrator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let orchestrator = makeOrchestrator(
            mutantKitRecorder: CallRecorder(), muterRecorder: CallRecorder(), runsPerMode: 3, outputDirectory: outputDirectory
        )
        try await orchestrator.run(manifest: BenchmarkManifest(schemaVersion: 1, projects: [Self.project]))

        #expect(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("aggregate.json").path))
        #expect(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("report.md").path))
        #expect(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("report.html").path))

        let aggregateData = try Data(contentsOf: outputDirectory.appendingPathComponent("aggregate.json"))
        let measurements = try JSONDecoder().decode([MutationBenchmarkMeasurement].self, from: aggregateData)
        #expect(!measurements.isEmpty, "the aggregate must contain the medianed measurements from both tools")
    }

    @Test("A per-mode toolOrder override is honored; an unlisted mode still defaults to mutantKitFirst")
    func toolOrderIsHonoredPerMode() async throws {
        let orderRecorder = OrderRecorder()
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantbench-orchestrator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let orchestrator = BenchmarkOrchestrator(
            mutantKit: FakeTool(
                identity: BenchmarkToolIdentity(name: "mutantkit", version: "test"), recorder: CallRecorder(), orderRecorder: orderRecorder
            ),
            muter: FakeTool(
                identity: BenchmarkToolIdentity(name: "muter", version: "test"), recorder: CallRecorder(), orderRecorder: orderRecorder
            ),
            toolchainProfile: Self.testProfile, runsPerMode: 1, timeoutSeconds: 60, outputDirectory: outputDirectory,
            materializer: ProjectMaterializer(git: AlwaysCleanGit()), toolOrder: [.warm: .muterFirst]
        )
        try await orchestrator.run(manifest: BenchmarkManifest(schemaVersion: 1, projects: [Self.project]))

        let startedFirst = await orderRecorder.startedFirst
        #expect(startedFirst[.cold] == "mutantkit", "an unlisted mode must default to mutantKitFirst")
        #expect(startedFirst[.warm] == "muter", "the explicit muterFirst override must be honored")
    }

    @Test("A modes restriction runs only the given modes — a scouting run's own cold-only-first gate")
    func modesRestrictionLimitsExecution() async throws {
        let mkRecorder = CallRecorder()
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantbench-orchestrator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let orchestrator = BenchmarkOrchestrator(
            mutantKit: FakeTool(identity: BenchmarkToolIdentity(name: "mutantkit", version: "test"), recorder: mkRecorder),
            muter: FakeTool(identity: BenchmarkToolIdentity(name: "muter", version: "test"), recorder: CallRecorder()),
            toolchainProfile: Self.testProfile, runsPerMode: 1, timeoutSeconds: 60, outputDirectory: outputDirectory,
            materializer: ProjectMaterializer(git: AlwaysCleanGit()), modes: [.cold]
        )
        try await orchestrator.run(manifest: BenchmarkManifest(schemaVersion: 1, projects: [Self.project]))

        #expect(await mkRecorder.cacheDirectories.count == 1, "only cold's single run should have happened, not warm/incremental too")
    }
}
