import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Gate 3 Phase H3-3: real, non-mocked production-path validation of native
/// timeout containment — not a hand-built spike (`XcodeBatchHangTimeoutSpikeAcceptanceTests`,
/// Phase H1) and not a fake (`MutationRunnerBatchTestingTests`/
/// `MutationRunnerWaveEarlyKillTests`'s unit coverage of the resolved-allowance
/// wiring). This calls the actual, unmodified-by-this-test public entry point —
/// `XcodeBuildAdapter.runBatch(_:in:timeoutSeconds:nativeTimeoutAllowanceSeconds:)`
/// — the exact method `MutationRunner.testOneBatch` (the default, non-wave
/// batching path Gate 3's own real-production-app batch-hang-containment
/// finding came from) and `testWaveChunk` both call.
///
/// `HangContainmentTests.testHangs` hangs unconditionally, which is safe here
/// only because that whole target belongs to its own `HangContainmentDemo`
/// scheme (see `Fixtures/XcodeProject/project.yml`) — never the "Checkout"
/// scheme every other acceptance suite, and mutantkit's own baseline
/// establishment, uses.
@Suite("Acceptance: XcodeBuildAdapter.runBatch native timeout containment (Gate 3 Phase H3)", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeBatchNativeTimeoutContainmentAcceptanceTests {
    private static let allowanceSeconds = 60.0

    private static let sharedRun = Task { try await run() }

    private func run() async throws -> [MutationID: TestRunResult] {
        try await Self.sharedRun.value
    }

    private static func run() async throws -> [MutationID: TestRunResult] {
        let directory = try Acceptance.stageFixture("XcodeProject")
        let destination = try Acceptance.iPhoneDestination()

        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "HangContainmentDemo", destination: destination)
        )
        let adapter = XcodeBuildAdapter(configuration: configuration, kind: .xcodeProject, projectFile: nil, projectRoot: directory)

        let artifact = try await adapter.buildBaseline(in: directory)

        let target = "HangContainmentTests"
        let items = [
            BatchMutantItem(
                id: MutationID(rawValue: "A"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangContainmentTests/testPassesA")]
            ),
            BatchMutantItem(
                id: MutationID(rawValue: "B"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangContainmentTests/testHangs")]
            ),
            BatchMutantItem(
                id: MutationID(rawValue: "C"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangContainmentTests/testPassesC")]
            )
        ]

        // The exact call `testOneBatch`/`testWaveChunk` make — `timeoutSeconds`
        // (the outer, aggregate fail-safe) deliberately generous here so this
        // test's own pass/fail hinges on native containment actually working,
        // not on racing the outer supervisor.
        return await adapter.runBatch(
            items, in: directory, timeoutSeconds: 600, nativeTimeoutAllowanceSeconds: allowanceSeconds
        )
    }

    @Test("The hanging configuration is timedOut, individually attributed — not a batch-wide placeholder")
    func hangingConfigurationIsIndividuallyAttributedTimeout() async throws {
        let results = try await self.run()
        let hang = try #require(results[MutationID(rawValue: "B")])
        #expect(hang.status == .timedOut)
        // A real, specific observation from `XCResultAdapter.classifyBatch`'s
        // native-timeout branch — never the batch-wide-outer-kill shape,
        // which would mark this `true` and route a clean confirmation
        // through `trustedTimeoutOutcome` instead of ordinary `.flaky`
        // disagreement handling (Gate 3 Phase H2's finding).
        #expect(hang.isBatchAttributedTimeout == false)
    }

    @Test("Siblings on either side of the hang both still pass — not lost, not rerun as a side effect of the hang")
    func siblingsPassAlongsideTheHang() async throws {
        let results = try await self.run()
        #expect(results[MutationID(rawValue: "A")]?.status == .passed)
        #expect(results[MutationID(rawValue: "C")]?.status == .passed)
    }

    @Test("Every configuration handed to the batch comes back with a result — the process was never outer-killed")
    func everyConfigurationReportsBack() async throws {
        let results = try await self.run()
        // A batch-wide outer-timeout kill (`XcodeBuildAdapter.runBatchOnDestination`'s
        // `result.timedOut` branch) would still report all three back, but
        // every one of them `.timedOut` — distinguishing this from the two
        // tests above requires all three together: A and C are `.passed`,
        // proven above, which is only possible if the shared `xcodebuild`
        // invocation completed normally rather than being killed outright.
        #expect(results.count == 3)
    }
}
