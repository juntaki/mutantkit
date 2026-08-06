import Foundation
import MutationModel

/// Wraps a `TestAdapter` with Stryker-style selected-test execution:
/// covering tests are ordered by historical kill usefulness and executed one
/// at a time, stopping as soon as one detects the mutant.
///
/// The wrapper is deliberately transparent for baseline and full-suite runs.
/// It only changes calls that already carry a non-empty per-test selection,
/// so a coverage-blind or attribution-failed run keeps the original safe
/// behaviour of running the complete configured suite.
public struct PrioritizingTestAdapter: TestSelecting, Sendable {
    private let base: any TestAdapter
    private let priorityStore: TestPriorityStore

    public init(base: any TestAdapter, priorityStore: TestPriorityStore) {
        self.base = base
        self.priorityStore = priorityStore
    }

    public func runBaseline(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await base.runBaseline(artifact, in: workspace, timeoutSeconds: timeoutSeconds)
    }

    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await base.runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds)
    }

    public func measurePerTestCoverage(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        guard let selecting = base as? any TestSelecting else { return nil }
        return await selecting.measurePerTestCoverage(
            artifact: artifact,
            in: workspace,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        guard let selecting = base as? any TestSelecting,
              let selectedTests,
              !selectedTests.isEmpty
        else {
            return try await base.runMutant(
                point,
                artifact: artifact,
                in: workspace,
                timeoutSeconds: timeoutSeconds
            )
        }

        let ordered = await priorityStore.order(selectedTests)
        let startedAt = Date()
        var total = 0
        var passed = 0
        var failed = 0
        var failingTests: [String] = []
        var accumulatedDuration: Double = 0
        var lastResult: TestRunResult?

        for test in ordered {
            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = timeoutSeconds - elapsed
            guard remaining > 0 else {
                guard let lastResult else {
                    return try await selecting.runMutant(
                        point,
                        artifact: artifact,
                        in: workspace,
                        timeoutSeconds: timeoutSeconds,
                        selectedTests: [test]
                    )
                }
                return TestRunResult(
                    status: .timedOut,
                    summary: nil,
                    command: lastResult.command,
                    resultArtifactPath: lastResult.resultArtifactPath,
                    diagnosis: "Selected-test execution exhausted the mutant timeout before all covering tests ran."
                )
            }

            let result = try await selecting.runMutant(
                point,
                artifact: artifact,
                in: workspace,
                timeoutSeconds: remaining,
                selectedTests: [test]
            )
            lastResult = result

            if let summary = result.summary {
                total += summary.total
                passed += summary.passed
                failed += summary.failed
                failingTests.append(contentsOf: summary.failingTests)
                accumulatedDuration += summary.durationSeconds ?? 0
            }

            // First detection wins. Mutation testing only needs one trustworthy
            // witness that the mutant was caught; running the rest of the
            // covering tests would add cost without changing the verdict.
            if result.status != .passed {
                switch result.status {
                case .failed, .crashed, .timedOut:
                    await priorityStore.recordDetection(by: test)
                case .passed, .infrastructureFailure:
                    break
                }
                return result
            }
        }

        guard let lastResult else {
            return try await base.runMutant(
                point,
                artifact: artifact,
                in: workspace,
                timeoutSeconds: timeoutSeconds
            )
        }

        let summary: TestOutcomeSummary? = total > 0
            ? TestOutcomeSummary(
                total: total,
                passed: passed,
                failed: failed,
                failingTests: failingTests,
                durationSeconds: accumulatedDuration
            )
            : nil

        return TestRunResult(
            status: .passed,
            summary: summary,
            command: lastResult.command,
            resultArtifactPath: lastResult.resultArtifactPath,
            diagnosis: "All \(ordered.count) covering test(s) passed; selected tests were executed in historical kill-priority order with early abort enabled."
        )
    }
}

/// Persistent, deterministic test ordering learned from previous detected
/// mutants. A test that has killed more mutants is tried earlier next time.
/// Ties fall back to the stable `-only-testing:` identifier, so plans remain
/// reproducible even when the history file is absent or newly created.
public actor TestPriorityStore {
    private struct Snapshot: Codable {
        var detections: [String: Int]
    }

    private let url: URL
    private var detections: [String: Int]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            detections = snapshot.detections
        } else {
            detections = [:]
        }
    }

    public func order(_ tests: Set<TestIdentifier>) -> [TestIdentifier] {
        tests.sorted { lhs, rhs in
            let left = detections[lhs.onlyTestingArgument, default: 0]
            let right = detections[rhs.onlyTestingArgument, default: 0]
            if left != right { return left > right }
            return lhs.onlyTestingArgument < rhs.onlyTestingArgument
        }
    }

    public func recordDetection(by test: TestIdentifier) {
        detections[test.onlyTestingArgument, default: 0] += 1
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(detections: detections)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
