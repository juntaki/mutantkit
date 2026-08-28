import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for `Configuration.execution.selectCoveringTests`:
/// does the runner narrow a mutant's test invocation to the tests
/// `TestSelecting.measurePerTestCoverage` attributed to its line, and does
/// it always fall back to the unrestricted run — never to an empty
/// selection — whenever that attribution has nothing to say. Confirmation
/// reruns (`confirmCrashKills`/`confirmTimedOutMutants`) must reproduce the
/// same narrowed scope as the original observation, not a different one.
@Suite("Mutation runner: coverage-based test selection")
struct MutationRunnerTestSelectionTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-selection-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-selection-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )
    private let addTest = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testSomething")

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    /// Plans the fixture, builds a `PerTestCoverageMap` attributing the
    /// single discovered mutation to `attribution` (or leaves the map with
    /// nothing to say about it, when `attribution` is `nil` — the "unknown"
    /// case), and runs it through a scripted `TestSelecting` adapter.
    private func run(
        selectCoveringTests: Bool,
        attribution: Set<TestIdentifier>??,
        confirmCrashKills: Bool = false,
        confirmTimedOutMutants: Bool = false,
        mutantSequence: [TestRunStatus]
    ) async throws -> (RunReport, ScriptedSelectiveTestAdapter) {
        try writeSingleMutantProject()

        let configuration = Configuration(
            execution: ExecutionSettings(
                confirmCrashKills: confirmCrashKills,
                confirmTimedOutMutants: confirmTimedOutMutants,
                selectCoveringTests: selectCoveringTests
            )
        )
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)
        let point = try #require(plan.mutations.first)

        let perTestCoverage: PerTestCoverageMap? = attribution.map { covering in
            PerTestCoverageMap(
                coveringTests: covering.map { [point.file: [point.line: $0]] } ?? [:],
                source: "test"
            )
        } ?? nil

        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let adapter = ScriptedSelectiveTestAdapter(
            mutantSequence: mutantSequence, perTestCoverage: perTestCoverage
        )
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces
        )
        let report = try await runner.run()
        return (report, adapter)
    }

    @Test("selectCoveringTests on, attribution known: the mutant runs only against the attributed tests")
    func knownAttributionNarrowsTheRun() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([addTest]), mutantSequence: [.failed]
        )

        #expect(report.results.first?.outcome == .killedByAssertion)
        let selections = await adapter.recordedSelections
        #expect(selections == [[addTest]])
    }

    @Test("selectCoveringTests on, attribution unknown: falls back to the unrestricted run, not an empty one")
    func unknownAttributionFallsBackToUnrestricted() async throws {
        // `attribution: .some(nil)` means the map exists but has nothing to
        // say about this exact site — the "profiled, but this line wasn't
        // reached by anything" case `testsCovering` returns `nil` for.
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: .some(nil), mutantSequence: [.failed]
        )

        #expect(report.results.first?.outcome == .killedByAssertion)
        let selections = await adapter.recordedSelections
        #expect(selections == [nil])
    }

    @Test("selectCoveringTests on, no per-test coverage measured at all: falls back to the unrestricted run")
    func noPerTestCoverageAtAllFallsBackToUnrestricted() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: nil, mutantSequence: [.failed]
        )

        #expect(report.results.first?.outcome == .killedByAssertion)
        let selections = await adapter.recordedSelections
        #expect(selections == [nil])
    }

    @Test("selectCoveringTests off: an adapter that conforms to TestSelecting is still run unrestricted")
    func flagOffNeverNarrowsEvenIfTheAdapterCould() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: false, attribution: .some([addTest]), mutantSequence: [.failed]
        )

        #expect(report.results.first?.outcome == .killedByAssertion)
        let selections = await adapter.recordedSelections
        #expect(selections == [nil])
    }

    @Test("A crash confirmation rerun reproduces the same narrowed selection as the original observation")
    func confirmationReproducesTheSameSelection() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([addTest]),
            confirmCrashKills: true, mutantSequence: [.crashed, .crashed]
        )

        #expect(report.results.first?.outcome == .killedByCrash)
        let selections = await adapter.recordedSelections
        // First run, then the independent confirmation rebuild's run — both
        // narrowed to the same attributed test.
        #expect(selections == [[addTest], [addTest]])
    }

    // MARK: - Selected-test-aware timeout

    // A `10...30`s, `selectedTests.count`-scaled clamp lived here
    // previously — narrowing a known selection's timeout well below the
    // whole-suite number. Gate 3's real-iOS-project run found it
    // uncalibrated for Xcode/Simulator's fixed per-invocation overhead (see
    // `TimeoutController.mutantLimitSeconds(selectedTests:)`'s own doc
    // comment and `Research/benchmarks/gate3-ios-schemata-2026-08-23`), so a
    // known selection now resolves to the same whole-suite number an
    // unknown one always did — the three tests below assert that identical
    // outcome instead of a narrower one.

    @Test("A known, non-empty selection resolves to the same whole-suite timeout as an unknown one, not a narrower clamp")
    func knownSelectionMatchesWholeSuiteTimeout() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([addTest]), mutantSequence: [.failed]
        )

        #expect(report.results.first?.outcome == .killedByAssertion)
        let observed = try #require(await adapter.recordedTimeoutSeconds.first)
        // Default `TimeoutSettings()` with an unmeasured (~0s) baseline
        // resolves to ~ the adaptive default's overheadAllowance (60s).
        #expect(abs(observed - 60) < 1)
    }

    @Test("An unknown/unattributed selection keeps today's whole-suite-scaled timeout, completely unchanged")
    func unknownSelectionFallsThroughToWholeSuiteTimeout() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: .some(nil), mutantSequence: [.failed]
        )

        #expect(report.results.first?.outcome == .killedByAssertion)
        let observed = try #require(await adapter.recordedTimeoutSeconds.first)
        // Default `TimeoutSettings()` with an unmeasured (~0s) baseline
        // resolves to ~ the adaptive default's overheadAllowance (60s).
        #expect(abs(observed - 60) < 1)
    }

    @Test("A confirmation reruns under the exact same resolved limit the original observation used, never a separately-resolved one")
    func confirmationReusesThePrimaryRunsResolvedTimeout() async throws {
        let (report, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([addTest]),
            confirmCrashKills: true, mutantSequence: [.crashed, .crashed]
        )

        #expect(report.results.first?.outcome == .killedByCrash)
        let observed = await adapter.recordedTimeoutSeconds
        // `#require`, not `#expect`: this exact assertion has been observed
        // to crash the whole test process (unguarded `observed[0]`/
        // `observed[1]` below trapping) under severe machine contention.
        // Fail cleanly instead.
        try #require(observed.count == 2)
        #expect(
            abs(observed[0] - observed[1]) < 0.001,
            "the original observation and its confirmation must resolve to the identical limit, got \(observed)"
        )
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash",
            xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// A `TestSelecting` fake that hands back scripted statuses one call at a
/// time, and records which `selectedTests` each `runMutant` call arrived
/// with — the thing this suite exists to assert on.
private actor ScriptedSelectiveTestAdapter: TestSelecting {
    private var remaining: [TestRunStatus]
    private let perTestCoverage: PerTestCoverageMap?
    private(set) var recordedSelections: [Set<TestIdentifier>?] = []
    private(set) var recordedTimeoutSeconds: [Double] = []

    init(mutantSequence: [TestRunStatus], perTestCoverage: PerTestCoverageMap?) {
        remaining = mutantSequence
        self.perTestCoverage = perTestCoverage
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        perTestCoverage
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, selectedTests: nil)
    }

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        recordedSelections.append(selectedTests)
        recordedTimeoutSeconds.append(timeoutSeconds)
        precondition(!remaining.isEmpty, "runMutant called more times than the test scripted")
        return Self.result(remaining.removeFirst())
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)"
        )
    }
}
