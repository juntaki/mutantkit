import Foundation
import MutationExecution
import MutationModel
import Testing

/// `PrioritizingTestAdapter` had no dedicated test file before this project's
/// own P7 self-mutation audit
/// (`Research/mutation-testing-hardening-2026-08/PROGRESS.md`) found it: a
/// sampled self-mutation run against just this 159-line file scored 1/5
/// (20%) — every other caller only ever type-checks that the adapter got
/// constructed (`RunCommandTestAdapterResolutionTests`) or injects a fake
/// `TestSelecting` straight into `MutationRunner`, bypassing this wrapper
/// entirely (`MutationRunnerWaveEarlyKillTests`). These tests exercise the
/// wrapper's own decision logic directly.
@Suite("PrioritizingTestAdapter: selected-test ordering and early abort")
struct PrioritizingTestAdapterTests {
    private static let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
    private static let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

    private func store() -> TestPriorityStore {
        TestPriorityStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("priority-\(UUID().uuidString).json"))
    }

    private func artifact() -> BuildArtifact {
        BuildArtifact(
            productsDirectory: FileManager.default.temporaryDirectory, productHash: "h1", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: "/t")
        )
    }

    /// Found by the audit: mutating `result.status != .passed` (line 121) to
    /// `== .passed` inverts which status stops the loop. Two covering tests,
    /// `testA` (alphabetically first, so tried first with a fresh, empty
    /// priority store) passing and `testB` failing: the real mutant is only
    /// caught by `testB`, which the mutation would never reach — it returns
    /// early on `testA`'s `.passed` result instead, reporting the mutant as
    /// surviving when a covering test that was never run would have killed
    /// it. Exactly the false-survivor class of bug this whole program exists
    /// to close.
    @Test("Early abort stops at the first non-passing result, in priority order, not the first passing one")
    func earlyAbortStopsAtTheFirstNonPassingResult() async throws {
        let fake = ScriptedTestSelectingAdapter(sequence: [
            .init(status: .passed, summary: nil),
            .init(
                status: .failed,
                summary: TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testB"], durationSeconds: 0.01)
            )
        ])
        let adapter = PrioritizingTestAdapter(base: fake, priorityStore: store())
        let point = try makeAnchoredPoint()

        let result = try await adapter.runMutant(
            point, artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30,
            selectedTests: [Self.testA, Self.testB]
        )

        #expect(result.status == .failed, "the mutant must be reported killed by the test that actually caught it")
        let selections = await fake.recordedSelections
        #expect(selections == [[Self.testA], [Self.testB]], "must run testA, then testB, stopping there — never a third call")
    }

    /// A non-empty selection must take the per-test ordered path (calling
    /// `selecting.runMutant(...selectedTests:)` once per covering test), not
    /// fall through to the unselected `base.runMutant(...)` — the guard
    /// mutated by the audit (`!selectedTests.isEmpty` -> `selectedTests.isEmpty`,
    /// line 60) would silently skip this path for every non-empty selection.
    @Test("A non-empty selection is run one test at a time, in priority order")
    func nonEmptySelectionTakesThePerTestOrderedPath() async throws {
        let fake = ScriptedTestSelectingAdapter(sequence: [
            .init(status: .passed, summary: nil)
        ])
        let adapter = PrioritizingTestAdapter(base: fake, priorityStore: store())
        let point = try makeAnchoredPoint()

        _ = try await adapter.runMutant(
            point, artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30,
            selectedTests: [Self.testA]
        )

        let selections = await fake.recordedSelections
        #expect(selections == [[Self.testA]], "must call the per-test overload with exactly the one selected test")
    }

    /// An empty (but non-nil) selection is the documented "coverage-blind or
    /// attribution-failed" case — it must fall back to the plain, unselected
    /// `base.runMutant(...)`, never call the per-test overload with an empty set.
    @Test("An empty selection falls back to the unselected run, never a per-test call with nothing selected")
    func emptySelectionFallsBackToTheUnselectedRun() async throws {
        let fake = ScriptedTestSelectingAdapter(sequence: [
            .init(status: .passed, summary: nil)
        ])
        let adapter = PrioritizingTestAdapter(base: fake, priorityStore: store())
        let point = try makeAnchoredPoint()

        _ = try await adapter.runMutant(
            point, artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30,
            selectedTests: []
        )

        let selections = await fake.recordedSelections
        #expect(selections == [nil], "the fallback call must carry no selection, not an empty one")
    }

    /// Found by the audit: mutating the ternary at line 141
    /// (`total > 0 ? TestOutcomeSummary(...) : nil`) to swap its branches
    /// would fabricate a zeroed `TestOutcomeSummary` here — exactly what
    /// `TestRunResult.summary`'s own doc comment calls out as "a fabricated
    /// measurement wearing the shape of a real one." When every covering
    /// test passes without producing structured counts (SwiftPM's ordinary
    /// non-parallel shape), the aggregated summary must stay `nil`.
    @Test("All covering tests passing with no structured counts reports no summary, not a fabricated zero one")
    func allCoveringTestsPassingProducesNoFabricatedSummary() async throws {
        let fake = ScriptedTestSelectingAdapter(sequence: [
            .init(status: .passed, summary: nil),
            .init(status: .passed, summary: nil)
        ])
        let adapter = PrioritizingTestAdapter(base: fake, priorityStore: store())
        let point = try makeAnchoredPoint()

        let result = try await adapter.runMutant(
            point, artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30,
            selectedTests: [Self.testA, Self.testB]
        )

        #expect(result.status == .passed)
        #expect(result.summary == nil, "no test produced real counts, so nothing should be invented")
    }

    /// The other side of the same ternary: when covering tests *do* produce
    /// real structured counts, the aggregated summary must be a real one
    /// reflecting them, not silently dropped to `nil`.
    @Test("Real per-test summaries are aggregated, not dropped, when every covering test passes")
    func realAccumulatedSummaryIsPreservedWhenAllTestsPass() async throws {
        let fake = ScriptedTestSelectingAdapter(sequence: [
            .init(status: .passed, summary: TestOutcomeSummary(total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.5)),
            .init(status: .passed, summary: TestOutcomeSummary(total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.5))
        ])
        let adapter = PrioritizingTestAdapter(base: fake, priorityStore: store())
        let point = try makeAnchoredPoint()

        let result = try await adapter.runMutant(
            point, artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30,
            selectedTests: [Self.testA, Self.testB]
        )

        let summary = try #require(result.summary)
        #expect(summary.total == 2, "both covering tests' real counts must be accumulated, not lost")
        #expect(summary.passed == 2)
    }

    /// Found by the audit: mutating `return await selecting.measurePerTestCoverage(...)`
    /// (line 44) to `return nil` survived untouched — nothing checked that
    /// this delegation actually happens when the base adapter supports it.
    @Test("measurePerTestCoverage delegates to the base adapter when it supports selection")
    func measurePerTestCoverageDelegatesWhenBaseSupportsSelection() async throws {
        let coverage = PerTestCoverageMap(coveringTests: ["Sources/Example.swift": [1: [Self.testA]]], source: "swift-package-codecov")
        let fake = ScriptedTestSelectingAdapter(sequence: [], coverageMap: coverage)
        let adapter = PrioritizingTestAdapter(base: fake, priorityStore: store())

        let result = await adapter.measurePerTestCoverage(
            artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30
        )

        #expect(result == coverage, "the real measured map must be returned, not thrown away")
    }

    @Test("measurePerTestCoverage returns nil when the base adapter does not support selection")
    func measurePerTestCoverageReturnsNilWhenBaseDoesNotSupportSelection() async throws {
        let adapter = PrioritizingTestAdapter(base: PlainTestAdapterOnly(), priorityStore: store())

        let result = await adapter.measurePerTestCoverage(
            artifact: artifact(), in: FileManager.default.temporaryDirectory, timeoutSeconds: 30
        )

        #expect(result == nil)
    }
}

// MARK: - Fakes

/// A `TestSelecting` fake that hands back a scripted sequence of statuses
/// (with independently-controlled summaries, unlike other suites' fakes that
/// always attach a summary based on status alone) and records the exact
/// `selectedTests` value of every call, in order.
private actor ScriptedTestSelectingAdapter: TestSelecting {
    struct Scripted {
        let status: TestRunStatus
        let summary: TestOutcomeSummary?
    }

    private var remaining: [Scripted]
    private let coverageMap: PerTestCoverageMap?
    private(set) var recordedSelections: [Set<TestIdentifier>?] = []

    init(sequence: [Scripted], coverageMap: PerTestCoverageMap? = nil) {
        remaining = sequence
        self.coverageMap = coverageMap
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(status: .passed, summary: nil)
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        coverageMap
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, selectedTests: nil)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        recordedSelections.append(selectedTests)
        precondition(!remaining.isEmpty, "runMutant called more times than this test scripted")
        let next = remaining.removeFirst()
        return Self.result(status: next.status, summary: next.summary)
    }

    private static func result(status: TestRunStatus, summary: TestOutcomeSummary?) -> TestRunResult {
        TestRunResult(
            status: status, summary: summary,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)"
        )
    }
}

/// A minimal `TestAdapter` that deliberately does *not* conform to
/// `TestSelecting`, so `base as? any TestSelecting` fails — the case
/// `measurePerTestCoverage`'s own guard exists for.
private struct PlainTestAdapterOnly: TestAdapter {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        TestRunResult(
            status: .passed, summary: nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "plain"
        )
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runBaseline(artifact, in: workspace, timeoutSeconds: timeoutSeconds)
    }
}
