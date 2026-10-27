@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `ProcessResult.cleanupVerified` reaches `TestRunResult.cleanupVerified`
/// through every adapter mapping, with its diagnosis, on every branch. Each
/// adapter is driven from a synthetic `ProcessResult`, so the mapping is
/// pinned without a real toolchain.
///
/// Mappings that turn a `ProcessResult` into a `TestRunResult`:
/// - SwiftPM: `SwiftPackageMacOSAdapter.classify` (baseline, mutant,
///   confirmation retest and schemata token runs all go through it).
/// - xcodebuild single: `XCTestInvocationService.runSingle` (isolated tests
///   and schemata tokens).
/// - xcodebuild batch: `XCTestInvocationService.runBatch` (isolated batches
///   and schemata token batches), plus `XcodeBuildAdapter.batchCleanup` for a
///   member the classifier left unreported.
/// - Wrapper: `PrioritizingTestAdapter`, which aggregates several runs.
@Suite("Cleanup verification: adapter propagation into TestRunResult")
struct CleanupVerificationPropagationTests {
    private static let diagnosis = "descendant cleanup of pid 1 could not be verified (injected)"

    private static func processResult(
        exitCode: Int32 = 0, timedOut: Bool = false, terminatingSignal: Int32? = nil, cleanupVerified: Bool = false
    ) -> ProcessResult {
        ProcessResult(
            exitCode: exitCode, standardOutput: Data(), standardError: Data(), durationSeconds: 1, timedOut: timedOut,
            terminatingSignal: terminatingSignal, outputComplete: true,
            cleanupVerified: cleanupVerified, cleanupDiagnosis: cleanupVerified ? nil : diagnosis
        )
    }

    private static let command = CommandRecord(executable: "xcrun", arguments: [], workingDirectory: "/tmp")

    // MARK: - SwiftPM

    @Test(
        "SwiftPM classify carries an unverified cleanup forward on every branch",
        arguments: [
            (Int32(0), false, Int32?.none, TestRunStatus.passed),
            (Int32(1), false, Int32?.none, TestRunStatus.failed),
            (Int32(2), false, Int32?.none, TestRunStatus.infrastructureFailure),
            (Int32(137), false, Int32?.some(SIGKILL), TestRunStatus.crashed),
            (Int32(137), true, Int32?.some(SIGKILL), TestRunStatus.timedOut)
        ]
    )
    func swiftPMClassifyPropagates(exitCode: Int32, timedOut: Bool, signal: Int32?, expectedStatus: TestRunStatus) {
        let result = SwiftPackageMacOSAdapter.classify(
            result: Self.processResult(exitCode: exitCode, timedOut: timedOut, terminatingSignal: signal), command: Self.command
        )
        #expect(result.status == expectedStatus, "the status mapping itself must not change")
        #expect(result.cleanupVerified == false)
        #expect(result.cleanupDiagnosis == Self.diagnosis)
    }

    @Test("SwiftPM classify carries a verified cleanup forward as verified")
    func swiftPMClassifyKeepsVerified() {
        let result = SwiftPackageMacOSAdapter.classify(result: Self.processResult(cleanupVerified: true), command: Self.command)
        #expect(result.cleanupVerified)
        #expect(result.cleanupDiagnosis == nil)
    }

    @Test("SwiftPM classify's narrowed-selection shortfall branch carries it forward too")
    func swiftPMShortfallPropagates() {
        let result = SwiftPackageMacOSAdapter.classify(
            result: Self.processResult(exitCode: 0), command: Self.command, xunitOutput: nil, reliableExpectedTestCount: 2
        )
        #expect(result.status == .infrastructureFailure)
        #expect(result.cleanupVerified == false)
    }

    @Test("SwiftPM classify's incomplete-output branch carries it forward too")
    func swiftPMIncompleteOutputPropagates() {
        let incomplete = ProcessResult(
            exitCode: 0, standardOutput: Data(), standardError: Data(), durationSeconds: 1, timedOut: false,
            terminatingSignal: nil, outputComplete: false, cleanupVerified: false, cleanupDiagnosis: Self.diagnosis
        )
        let result = SwiftPackageMacOSAdapter.classify(result: incomplete, command: Self.command)
        #expect(result.status == .infrastructureFailure)
        #expect(result.cleanupVerified == false)
        #expect(result.cleanupDiagnosis == Self.diagnosis)
    }

    // MARK: - xcodebuild single and batch

    private static func service(returning processResult: ProcessResult) -> XCTestInvocationService {
        XCTestInvocationService(
            terminationGracePeriodSeconds: 1, resultReader: XCResultAdapter(),
            launch: { _, _, _, _ in processResult }
        )
    }

    private static func scratchBundle() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-prop-\(UUID().uuidString)/r.xcresult")
    }

    @Test("xcodebuild single: the timed-out branch carries an unverified cleanup forward")
    func xcodebuildSingleTimeoutPropagates() async {
        let run = await Self.service(returning: Self.processResult(timedOut: true)).runSingle(
            arguments: [], resultBundle: Self.scratchBundle(), timeoutSeconds: 1, timeoutDiagnosis: "timed out",
            in: FileManager.default.temporaryDirectory,
            classify: { XCResultAdapter.Outcome(status: .passed, summary: makeTestSummary(), diagnosis: "unused") }
        )
        #expect(run.status == .timedOut)
        #expect(run.cleanupVerified == false)
        #expect(run.cleanupDiagnosis == Self.diagnosis)
    }

    @Test("xcodebuild single: the classified branch carries an unverified cleanup forward, even for a pass")
    func xcodebuildSingleClassifiedPropagates() async {
        let run = await Self.service(returning: Self.processResult()).runSingle(
            arguments: [], resultBundle: Self.scratchBundle(), timeoutSeconds: 1, timeoutDiagnosis: "timed out",
            in: FileManager.default.temporaryDirectory,
            classify: { XCResultAdapter.Outcome(status: .passed, summary: makeTestSummary(), diagnosis: "all passed") }
        )
        #expect(run.status == .passed)
        #expect(run.cleanupVerified == false)
    }

    @Test("xcodebuild batch: every member of a timed-out batch carries an unverified cleanup forward")
    func xcodebuildBatchTimeoutPropagates() async {
        let runs = await Self.service(returning: Self.processResult(timedOut: true)).runBatch(
            arguments: [], resultBundle: Self.scratchBundle(), timeoutSeconds: 1,
            configurationTestIdentifiers: ["a": ["T/a"], "b": ["T/b"]], in: FileManager.default.temporaryDirectory
        )
        #expect(runs.count == 2)
        #expect(runs.values.allSatisfy { $0.status == .timedOut && !$0.cleanupVerified && $0.cleanupDiagnosis == Self.diagnosis })
    }

    @Test("xcodebuild batch: every classified member carries an unverified cleanup forward")
    func xcodebuildBatchClassifiedPropagates() async {
        // No bundle exists, so `classifyBatch` reports every configuration
        // as an infrastructure failure without launching anything.
        let runs = await Self.service(returning: Self.processResult(exitCode: 65)).runBatch(
            arguments: [], resultBundle: Self.scratchBundle(), timeoutSeconds: 1,
            configurationTestIdentifiers: ["a": ["T/a"], "b": ["T/b"]], in: FileManager.default.temporaryDirectory
        )
        #expect(runs.count == 2)
        #expect(runs.values.allSatisfy { !$0.cleanupVerified && $0.cleanupDiagnosis == Self.diagnosis })
    }

    @Test("A batch member the classifier left unreported inherits the batch's unverified cleanup")
    func unreportedBatchMemberInheritsBatchCleanup() {
        let unverified = TestRunResult(
            status: .passed, summary: nil, command: Self.command, resultArtifactPath: nil, diagnosis: "ok",
            cleanupVerified: false, cleanupDiagnosis: Self.diagnosis
        )
        let verified = TestRunResult(
            status: .passed, summary: nil, command: Self.command, resultArtifactPath: nil, diagnosis: "ok", cleanupVerified: true
        )
        let fromUnverified = XcodeBuildAdapter.batchCleanup(["a": verified, "b": unverified])
        #expect(fromUnverified.verified == false)
        #expect(fromUnverified.diagnosis == Self.diagnosis)
        #expect(XcodeBuildAdapter.batchCleanup(["a": verified]).verified)
    }

    // MARK: - Wrapper

    @Test("PrioritizingTestAdapter stops at an unverified run and returns it, never an aggregate pass")
    func prioritizingAdapterStopsAtUnverifiedRun() async throws {
        let first = TestIdentifier(target: "T", qualifiedName: "C/testA")
        let second = TestIdentifier(target: "T", qualifiedName: "C/testB")
        let base = CleanupScriptedSelectingAdapter(cleanupVerifiedSequence: [false, true])
        let adapter = PrioritizingTestAdapter(
            base: base,
            priorityStore: TestPriorityStore(
                url: FileManager.default.temporaryDirectory.appendingPathComponent("priority-\(UUID().uuidString).json")
            )
        )

        let run = try await adapter.runMutant(
            makeAnchoredPoint(),
            artifact: BuildArtifact(
                productsDirectory: FileManager.default.temporaryDirectory, productHash: "h", xctestrunPath: nil, command: Self.command
            ),
            in: FileManager.default.temporaryDirectory, timeoutSeconds: 30, selectedTests: [first, second]
        )

        #expect(run.cleanupVerified == false)
        #expect(await base.callCount == 1, "no further covering test may run after an unverified cleanup")
    }

    // MARK: - Persistence

    @Test("A TestRunResult without the cleanupVerified key does not decode as verified")
    func legacyRecordWithoutTheKeyIsRejected() throws {
        let legacy = Data("""
        {"status":"passed","command":{"executable":"x","arguments":[],"workingDirectory":"/"},\
        "diagnosis":"ok","isBatchAttributedTimeout":false}
        """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TestRunResult.self, from: legacy) }
    }
}

/// Every run passes; `cleanupVerifiedSequence` sets each run's
/// `cleanupVerified`, in call order.
private actor CleanupScriptedSelectingAdapter: TestSelecting {
    private var remaining: [Bool]
    private(set) var callCount = 0

    init(cleanupVerifiedSequence: [Bool]) {
        remaining = cleanupVerifiedSequence
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(cleanupVerified: true)
    }

    func measurePerTestCoverage(artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async -> PerTestCoverageMap? {
        nil
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
        callCount += 1
        return Self.result(cleanupVerified: remaining.isEmpty ? true : remaining.removeFirst())
    }

    private static func result(cleanupVerified: Bool) -> TestRunResult {
        TestRunResult(
            status: .passed, summary: nil, command: CommandRecord(executable: "swift", arguments: [], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted pass",
            cleanupVerified: cleanupVerified, cleanupDiagnosis: cleanupVerified ? nil : "injected"
        )
    }
}
