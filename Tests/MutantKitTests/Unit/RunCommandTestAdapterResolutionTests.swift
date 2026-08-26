@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Codex review finding on `perf/wave-early-kill`: `RunCommand` picked wave
/// mode purely from `testBatchSize` being configured, without checking
/// whether the resolved adapter actually supports batching. A project whose
/// adapter is not `BatchTestable` (a plain SwiftPM package, for one) would
/// silently lose `earlyAbortSelectedTests` entirely — neither wave mode (the
/// runner never enters the wave loop for a non-`BatchTestable` adapter) nor
/// the `PrioritizingTestAdapter` fallback would run.
@Suite("RunCommand: test adapter resolution")
struct RunCommandTestAdapterResolutionTests {
    private func configuration(selectCoveringTests: Bool, earlyAbort: Bool, testBatchSize: Int?) -> Configuration {
        Configuration(
            execution: ExecutionSettings(
                selectCoveringTests: selectCoveringTests,
                earlyAbortSelectedTests: earlyAbort,
                testBatchSize: testBatchSize
            )
        )
    }

    private var priorityStoreURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("priority-\(UUID().uuidString).json")
    }

    @Test("Early abort disabled: the base adapter is returned unwrapped, no priority store")
    func earlyAbortDisabledReturnsBaseAdapter() {
        let base = FakeBatchableTestAdapter()
        let (adapter, store) = RunCommand.resolveTestAdapter(
            configuration(selectCoveringTests: true, earlyAbort: false, testBatchSize: 10),
            base: base, priorityStoreURL: priorityStoreURL
        )
        #expect(adapter is FakeBatchableTestAdapter)
        #expect(store == nil)
    }

    @Test("testBatchSize set and the adapter supports batching: wave mode — base adapter, runner priority store")
    func batchSizeWithBatchableAdapterUsesWaveMode() {
        let base = FakeBatchableTestAdapter()
        let (adapter, store) = RunCommand.resolveTestAdapter(
            configuration(selectCoveringTests: true, earlyAbort: true, testBatchSize: 10),
            base: base, priorityStoreURL: priorityStoreURL
        )
        #expect(adapter is FakeBatchableTestAdapter, "wave mode hands the runner the adapter itself, unwrapped")
        #expect(store != nil, "the runner needs the priority store directly to run its own wave loop")
    }

    /// The regression this suite exists to pin: `testBatchSize` alone must
    /// not select wave mode when the adapter cannot actually batch.
    @Test("testBatchSize set but the adapter cannot batch: falls back to PrioritizingTestAdapter, not silence")
    func batchSizeWithNonBatchableAdapterFallsBackToPrioritizing() {
        let base = FakeNonBatchableTestAdapter()
        let (adapter, store) = RunCommand.resolveTestAdapter(
            configuration(selectCoveringTests: true, earlyAbort: true, testBatchSize: 10),
            base: base, priorityStoreURL: priorityStoreURL
        )
        #expect(adapter is PrioritizingTestAdapter, "must wrap in the serial early-abort adapter, not hand back the raw base")
        #expect(store == nil, "the runner has no wave loop to consult a store for here")
    }

    @Test("No testBatchSize configured: falls back to PrioritizingTestAdapter even for a batchable adapter")
    func noBatchSizeFallsBackToPrioritizing() {
        let base = FakeBatchableTestAdapter()
        let (adapter, store) = RunCommand.resolveTestAdapter(
            configuration(selectCoveringTests: true, earlyAbort: true, testBatchSize: nil),
            base: base, priorityStoreURL: priorityStoreURL
        )
        #expect(adapter is PrioritizingTestAdapter)
        #expect(store == nil)
    }
}

private struct FakeNonBatchableTestAdapter: TestAdapter {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }
}

private struct FakeBatchableTestAdapter: TestAdapter, BatchTestable {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        fatalError("not exercised")
    }
}
