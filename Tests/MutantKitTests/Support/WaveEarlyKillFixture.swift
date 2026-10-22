import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Shared harness for the wave-based early-kill suites
/// (`MutationRunnerWaveEarlyKill*Tests`): a temp project, a real
/// `MutationRunner` wired for waves, and the fakes below. Each suite holds
/// its own instance, so every test gets a fresh project and scratch root.
struct WaveEarlyKillFixture {
    struct WaveRun {
        let report: RunReport
        let adapter: SpyWaveAdapter
        let points: [MutationPoint]
        let priorityStoreURL: URL
    }

    let root: URL = Self.makeTempDir(prefix: "mutantkit-wave-project")
    let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-wave-scratch")
    let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// `count` independent bool-literal mutation sites, one per line — each
    /// on its own line deliberately, exactly like the sibling batch-testing
    /// suites: on a shared line every mutant would report the same
    /// `point.line`, and a coverage map keyed by file+line could not tell
    /// them apart.
    func writeMutantProject(count: Int) throws {
        let url = root.appendingPathComponent("Sources/W.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fields = (0 ..< count).map { "    var v\($0) = true" }.joined(separator: "\n")
        try Data("struct W {\n\(fields)\n}".utf8).write(to: url)
    }

    /// Plans `count` mutants and runs them through a real `MutationRunner`
    /// wired for wave-based early kill: `selectCoveringTests` +
    /// `earlyAbortSelectedTests` + `testBatchSize`, and a `TestPriorityStore`
    /// passed to the runner directly (never wrapped in
    /// `PrioritizingTestAdapter` — that is the CLI's non-batched fallback,
    /// exercised elsewhere).
    ///
    /// `coverage` and `waveOutcomes`/`fullSuiteOutcomes` are built from the
    /// already-planned, ID-sorted points, so callers can key by point index
    /// without knowing a `MutationID` up front.
    func run(
        count: Int,
        testBatchSize: Int,
        coverage: (_ points: [MutationPoint]) -> [String: [Int: Set<TestIdentifier>]],
        waveOutcomes: (_ points: [MutationPoint]) -> [MutationID: [TestIdentifier: TestRunStatus]] = { _ in [:] },
        fullSuiteOutcomes: (_ points: [MutationPoint]) -> [MutationID: TestRunStatus] = { _ in [:] },
        retestKilledMutants: Bool = false,
        confirmTimedOutMutants: Bool = false,
        mutantTimeoutSeconds: Double? = nil,
        waveDurationSeconds: Double = 0,
        unbatchedOverride: (_ points: [MutationPoint]) -> [MutationID: TestRunStatus] = { _ in [:] },
        // Which mutants' wave `.timedOut` result should
        // be scripted as batch-attributed (`isBatchAttributedTimeout: true`
        // — a whole shared invocation killed with no way to tell which
        // configuration caused it) rather than the default, native-XCTest-
        // timeout shape (`false` — this one configuration was individually,
        // trustworthily identified).
        batchAttributedTimeouts: (_ points: [MutationPoint]) -> Set<MutationID> = { _ in [] },
        incrementalBuild: Bool = false
    ) async throws -> WaveRun {
        try writeMutantProject(count: count)

        let execution = ExecutionSettings(
            workers: 1,
            retestKilledMutants: retestKilledMutants,
            confirmCrashKills: false,
            confirmTimedOutMutants: confirmTimedOutMutants,
            selectCoveringTests: true,
            incrementalBuild: incrementalBuild,
            earlyAbortSelectedTests: true,
            testBatchSize: testBatchSize
        )
        var timeouts = TimeoutSettings()
        if let mutantTimeoutSeconds {
            timeouts.mutant = MutantTimeoutSettings(strategy: .fixed, maximumSeconds: mutantTimeoutSeconds)
        }
        let configuration = Configuration(execution: execution, timeouts: timeouts)
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == count)
        let points = plan.mutations.sorted { $0.id < $1.id }

        let coverageMap = PerTestCoverageMap(coveringTests: coverage(points), source: "test")
        // A manually-advanced clock, shared between the runner and the
        // adapter, replaces `Task.sleep`-and-hope-the-real-elapsed-time-
        // lands-close-enough: `waveDurationSeconds` now advances this fake
        // clock by an exact amount instead of sleeping for real, so every
        // duration this suite asserts on is deterministic — never at the
        // mercy of full-suite CPU contention stretching a real sleep past a
        // budget boundary the test never intended to cross.
        let clock = ManualClock()
        let adapter = SpyWaveAdapter(
            perTestCoverage: coverageMap,
            waveOutcomes: waveOutcomes(points),
            fullSuiteOutcomes: fullSuiteOutcomes(points),
            waveDurationSeconds: waveDurationSeconds,
            unbatchedOverride: unbatchedOverride(points),
            batchAttributedTimeouts: batchAttributedTimeouts(points),
            clock: clock
        )

        let priorityStoreURL = scratchRoot.appendingPathComponent("priority-\(UUID().uuidString).json")
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: WaveStubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            priorityStore: TestPriorityStore(url: priorityStoreURL),
            monotonicNow: clock.now
        )
        let report = try await runner.run()
        return WaveRun(report: report, adapter: adapter, points: points, priorityStoreURL: priorityStoreURL)
    }

    /// Decodes a `TestPriorityStore`'s persisted detection counts directly —
    /// the store itself exposes no getter, only `order`/`recordDetection`,
    /// so the on-disk snapshot is the only external window onto what got
    /// credited.
    func persistedDetections(at url: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistedPriorities.self, from: data)
        else { return [:] }
        return snapshot.detections
    }

    struct PersistedPriorities: Codable {
        let detections: [String: Int]
    }
}

// MARK: - Fakes

struct WaveStubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: workspace.appendingPathComponent("baseline.xctestrun"),
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash-\(mutation.point.id.rawValue)",
            xctestrunPath: workspace.appendingPathComponent("mutant.xctestrun"),
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// A manually-advanced monotonic clock shared between a `MutationRunner`
/// under test and its `SpyWaveAdapter`, so a wave's simulated duration is an
/// exact, deterministic quantity — advanced synchronously by `advance(by:)`
/// — rather than `Task.sleep`'s real elapsed wall-clock time, which
/// full-suite CPU contention from unrelated concurrently-running tests can
/// inflate past a budget boundary the test never intended to cross. Returns
/// a plain elapsed-seconds `TimeInterval`, matching `MutationRunner`'s
/// `monotonicNow`, not a wall-clock `Date`.
final class ManualClock: @unchecked Sendable {
    private var elapsed: TimeInterval = 0
    private let lock = NSLock()

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        elapsed += seconds
        lock.unlock()
    }
}

/// Fakes a batched adapter for the wave loop. Every wave item carries
/// exactly one selected test (`testInWaves` always narrows to the
/// survivor's next test), so an outcome is looked up by `(mutant, that one
/// test)`. Unattributed items carry `selectedTests == nil` (the full
/// configured list) and are looked up in `fullSuiteOutcomes` instead.
/// Anything not scripted defaults to `.passed`, so a test only needs to
/// specify the outcomes it cares about.
actor SpyWaveAdapter: TestSelecting, BatchTestable {
    private let perTestCoverage: PerTestCoverageMap?
    private let waveOutcomes: [MutationID: [TestIdentifier: TestRunStatus]]
    private let fullSuiteOutcomes: [MutationID: TestRunStatus]
    /// Artificial per-`runBatch`-call delay, so a test can make cumulative
    /// wave duration a known, controllable quantity instead of whatever a
    /// near-instant synchronous call happens to measure. Realized by
    /// advancing `clock` (shared with the `MutationRunner` under test) by
    /// exactly this amount, never by a real `Task.sleep` — see `clock`.
    private let waveDurationSeconds: Double
    /// The same manually-advanced clock passed to `MutationRunner`. Advancing
    /// it here, instead of sleeping for real time, is what makes this
    /// adapter's simulated wave duration exact rather than merely
    /// approximate: the runner reads "now" from this same clock immediately
    /// before and after `runBatch`, so the measured duration is exactly
    /// `waveDurationSeconds`, unaffected by how long this process actually
    /// took to get scheduled.
    private let clock: ManualClock?
    /// What a mutant's unbatched `runMutant(selectedTests:)` call reports,
    /// when present — this path is only ever reached by a confirmation rerun
    /// or a standalone ground-truth verification, never by a wave's own test
    /// (which always goes through `runBatch`), so this simulates that rerun
    /// disagreeing with the mutant's original wave-batch result, the way a
    /// genuinely flaky test would.
    private let unbatchedOverride: [MutationID: TestRunStatus]
    /// Mutants whose wave `.timedOut` result should
    /// carry `isBatchAttributedTimeout: true`. Absent from this set (the
    /// default for every mutant) means the native-XCTest-timeout shape —
    /// `false`, this one configuration individually identified.
    private let batchAttributedTimeouts: Set<MutationID>
    private(set) var runBatchCalls: [[BatchMutantItem]] = []
    private(set) var runBatchTimeouts: [Double] = []
    private(set) var runBatchNativeTimeoutAllowances: [Double?] = []
    private(set) var runMutantSelectedTestsCalls: [Set<TestIdentifier>?] = []

    init(
        perTestCoverage: PerTestCoverageMap?,
        waveOutcomes: [MutationID: [TestIdentifier: TestRunStatus]] = [:],
        fullSuiteOutcomes: [MutationID: TestRunStatus] = [:],
        waveDurationSeconds: Double = 0,
        unbatchedOverride: [MutationID: TestRunStatus] = [:],
        batchAttributedTimeouts: Set<MutationID> = [],
        clock: ManualClock? = nil
    ) {
        self.perTestCoverage = perTestCoverage
        self.waveOutcomes = waveOutcomes
        self.fullSuiteOutcomes = fullSuiteOutcomes
        self.waveDurationSeconds = waveDurationSeconds
        self.unbatchedOverride = unbatchedOverride
        self.batchAttributedTimeouts = batchAttributedTimeouts
        self.clock = clock
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
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        runMutantSelectedTestsCalls.append(selectedTests)
        // A run against the baseline's own build is the unmutated control.
        if artifact.productHash == "baseline-hash" {
            return Self.result(.passed)
        }
        if let override = unbatchedOverride[point.id] {
            return Self.result(override)
        }
        let status = selectedTests?.first.flatMap { waveOutcomes[point.id]?[$0] } ?? .failed
        return Self.result(status)
    }

    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        runBatchCalls.append(items)
        runBatchTimeouts.append(timeoutSeconds)
        runBatchNativeTimeoutAllowances.append(nativeTimeoutAllowanceSeconds)
        if waveDurationSeconds > 0 {
            if let clock {
                clock.advance(by: waveDurationSeconds)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(waveDurationSeconds * 1_000_000_000))
            }
        }

        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            let isBatchAttributedTimeout = batchAttributedTimeouts.contains(item.id)
            if let tests = item.selectedTests, let single = tests.first, tests.count == 1 {
                let status = waveOutcomes[item.id]?[single] ?? .passed
                results[item.id] = Self.result(status, isBatchAttributedTimeout: isBatchAttributedTimeout)
            } else {
                let status = fullSuiteOutcomes[item.id] ?? .passed
                results[item.id] = Self.result(status, isBatchAttributedTimeout: isBatchAttributedTimeout)
            }
        }
        return results
    }

    private static func result(_ status: TestRunStatus, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: [], durationSeconds: 0.01)
                : status == .passed
                ? TestOutcomeSummary(total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "xcodebuild", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }
}
