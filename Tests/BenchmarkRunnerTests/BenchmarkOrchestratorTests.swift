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
    /// When set (Phase C13 regression test), overrides the default empty
    /// report with one built from the real `project` the orchestrator
    /// materialized — used to prove a cold-mode checkout survives long
    /// enough for `normalizeMuterReport`'s real relative-path resolution
    /// to actually run against it, not just warm/incremental.
    var reportBuilder: (@Sendable (MaterializedBenchmarkProject) -> Data)?

    func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {}

    func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
        await recorder.record(context.cacheDirectory.path)
        await orderRecorder?.recordStart(mode: context.mode, toolName: identity.name)
        let reportJSON = reportBuilder?(project) ?? Data(#"{"results": [], "integrity": {"passed": true}}"#.utf8)
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

    /// Regression test for a real bug caught by Codex review before the
    /// Phase C13 mutant-matching fix was committed as done: the last
    /// `cold`-mode checkout used to be deleted *inside* `runMode`, before
    /// `runProject` got a chance to pass it into `normalizeMuterReport` —
    /// silently defeating that fix's real relative-path resolution for
    /// exactly the `cold` mode the original "0 matched mutants" finding
    /// was measured under. Drives the real `BenchmarkOrchestrator` (not
    /// `ResultNormalizer` directly, which cannot see this ordering bug at
    /// all) with fake tools that (a) return a real Muter-shaped report
    /// whose `mutationPoint.filePath` points at a real file the fake
    /// Muter tool creates inside the real materialized `project.directory`,
    /// and (b) a MutantKit report at the identical real relative path/
    /// line/column — then asserts the two actually match in the written
    /// `report.md`, proving the checkout was still on disk when
    /// `normalizeMuterReport` ran.
    @Test("A cold-mode Muter mutant's real relative path still resolves — the checkout must survive long enough")
    func coldModeMuterRelativePathSurvivesCleanupOrdering() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantbench-orchestrator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let mutantKitReport: @Sendable (MaterializedBenchmarkProject) -> Data = { _ in
            Data(#"""
            {"results": [{
              "point": {
                "file": "Sources/Foo.swift", "utf8Range": {"start": 0, "end": 2},
                "originalText": "<", "replacementText": ">=",
                "operatorID": "swift.core.relational-operator-replacement",
                "line": 3, "column": 5
              },
              "outcome": "killedByAssertion"
            }]}
            """#.utf8)
        }
        let muterReport: @Sendable (MaterializedBenchmarkProject) -> Data = { project in
            // The real file `relativePath` must find on disk — created
            // here, inside the fake tool's own `run`, exactly like the
            // real Muter binary would leave real source files behind in
            // its own working copy.
            let nested = project.directory.appendingPathComponent("Sources")
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try? Data().write(to: nested.appendingPathComponent("Foo.swift"))

            return Data(#"""
            {"fileReports": [{
              "fileName": "Foo.swift",
              "appliedOperators": [{
                "testSuiteOutcome": "passed",
                "mutationPoint": {
                  "filePath": "\#(project.directory.path)_mutated/Sources/Foo.swift",
                  "position": {"line": 3, "column": 5},
                  "mutationOperatorId": "RelationalOperatorReplacement"
                }
              }]
            }]}
            """#.utf8)
        }

        let orchestrator = BenchmarkOrchestrator(
            mutantKit: FakeTool(
                identity: BenchmarkToolIdentity(name: "mutantkit", version: "test"),
                recorder: CallRecorder(), reportBuilder: mutantKitReport
            ),
            muter: FakeTool(
                identity: BenchmarkToolIdentity(name: "muter", version: "test"), recorder: CallRecorder(), reportBuilder: muterReport
            ),
            toolchainProfile: Self.testProfile, runsPerMode: 1, timeoutSeconds: 60, outputDirectory: outputDirectory,
            materializer: ProjectMaterializer(git: AlwaysCleanGit()), modes: [.cold]
        )
        // A project id unique to this test, not `Self.project`/"example":
        // `runMode`'s cold-mode checkout directory is named purely from
        // `(project.id, tool, mode, index)` under the *shared* system temp
        // directory, with no per-test-run salt. Swift Testing runs this
        // suite's tests concurrently by default, and every other test here
        // also uses "example" — reusing it made this test flaky (another
        // concurrently-running test's cold-mode checkout for the same
        // project id/tool/mode/index could be created, wiped, or reused
        // out from under this one). A unique id sidesteps that pre-existing,
        // orchestrator-level directory-naming collision risk entirely,
        // rather than trying to fix it here.
        let project = BenchmarkProject(
            id: "relpath-regression-\(UUID().uuidString)", repositoryURL: "https://example.com/example.git",
            commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
        )
        try await orchestrator.run(manifest: BenchmarkManifest(schemaVersion: 1, projects: [project]))

        let report = try String(contentsOf: outputDirectory.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(report.contains("exactly comparable: 1"), "\(report)")
        #expect(report.contains("MutantKit-only: 0"), "\(report)")
        #expect(report.contains("Muter-only: 0"), "\(report)")
    }
}
