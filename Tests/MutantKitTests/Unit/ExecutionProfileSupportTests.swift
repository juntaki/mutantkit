import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend
import Testing

/// Pure, no-filesystem tests for `ExecutionProfileSupport.characteristics` —
/// the CLI-layer half of `ExecutionProfileResolver` that turns a real,
/// decoded `MutationPlan` and a resolved `AppleAdapterFactory.Resolution`
/// into `ProjectExecutionCharacteristics`. `ExecutionProfileResolverTests`
/// covers the pure resolution *rule* over an already-built
/// `ProjectExecutionCharacteristics`; these tests cover the one step before
/// that — computing the characteristics themselves correctly from a plan
/// and an adapter.
///
/// None of these construct a real `WorkspaceManager`, project root, or
/// filesystem probe — `characteristics` no longer touches any of those (see
/// its own doc comment for why: the `clonefile(2)` precondition it used to
/// probe for was never real), so every case here runs instantly and needs
/// nothing on disk.
@Suite("ExecutionProfileSupport.characteristics")
struct ExecutionProfileSupportTests {
    // MARK: - Fakes

    /// Every method here is unreachable from `characteristics` itself,
    /// which only ever asks `is any Protocol` of `resolution.adapter.test` —
    /// it never calls a method on it. `fatalError` bodies make that
    /// contract explicit: a future change that starts actually invoking one
    /// of these would fail loudly in this suite, not silently return a
    /// meaningless stub value.
    private struct BareTestAdapter: TestAdapter {
        func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
            fatalError("unused")
        }

        func runMutant(
            _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
        ) async throws -> TestRunResult {
            fatalError("unused")
        }
    }

    private struct CapableTestAdapter: TestAdapter, CoverageMeasuring, TestSelecting, BatchTestable {
        func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
            fatalError("unused")
        }

        func runMutant(
            _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
        ) async throws -> TestRunResult {
            fatalError("unused")
        }

        func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? { fatalError("unused") }

        func measurePerTestCoverage(
            artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
        ) async -> PerTestCoverageMap? { fatalError("unused") }

        func runMutant(
            _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
            selectedTests: Set<TestIdentifier>?
        ) async throws -> TestRunResult { fatalError("unused") }

        func runBatch(
            _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double, nativeTimeoutAllowanceSeconds: Double?
        ) async -> [MutationID: TestRunResult] { fatalError("unused") }
    }

    private struct BareBuildAdapter: BuildAdapter {
        func diagnose() async throws -> BuildDiagnosis { fatalError("unused") }
        func buildBaseline(in workspace: URL) async throws -> BuildArtifact { fatalError("unused") }
        func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact { fatalError("unused") }
    }

    private struct StubAdapter: ProjectAdapter {
        let kind: ProjectKind
        let build: any BuildAdapter = BareBuildAdapter()
        let test: any TestAdapter
    }

    private func resolution(kind: ProjectKind, test: any TestAdapter = BareTestAdapter()) -> AppleAdapterFactory.Resolution {
        AppleAdapterFactory.Resolution(
            adapter: StubAdapter(kind: kind, test: test),
            detection: ProjectDetection(kind: kind, reason: "test", projectFile: nil)
        )
    }

    private func stubOperator(id: String, schemataEligible: Bool) -> OperatorDescriptor {
        OperatorDescriptor(
            id: id, version: 1, category: "test", summary: "test operator",
            defaultEnabled: true, confidence: .high, schemataEligible: schemataEligible
        )
    }

    private func stubPoint(id: String, operatorID: String) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: id), file: "Sources/Example.swift", enclosingDeclaration: .topLevel,
            operatorID: operatorID, operatorVersion: 1, occurrenceIndex: 0, utf8Range: ByteRange(start: 0, end: 4),
            originalText: "true", replacementText: "false", prefixTokenFingerprint: "p", suffixTokenFingerprint: "s",
            sourceFileHash: "hash", expectedSyntaxKind: "booleanLiteralExpr", confidence: .high,
            executionMode: .isolated, line: 1, column: 1
        )
    }

    private func stubPlan(mutations: [MutationPoint], operators: [OperatorDescriptor]) -> MutationPlan {
        MutationPlan(
            planID: "plan", createdAt: Date(timeIntervalSince1970: 0), projectRoot: "/tmp/does-not-matter",
            toolchain: ToolchainFingerprint(
                toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0", xcodeVersion: nil
            ),
            configurationHash: "hash", sourceFileHashes: [:], mutations: mutations, skipped: [], operators: operators
        )
    }

    // MARK: - Schemata eligibility counting

    @Test("counts only mutations whose operator is both schemata-eligible and intersected against the plan's own operators")
    func eligibilityCountingAgainstAHandBuiltPlan() async {
        let eligibleOperator = stubOperator(id: "op.eligible", schemataEligible: true)
        let ineligibleOperator = stubOperator(id: "op.ineligible", schemataEligible: false)
        let plan = stubPlan(
            mutations: [
                stubPoint(id: "m1", operatorID: "op.eligible"),
                stubPoint(id: "m2", operatorID: "op.eligible"),
                stubPoint(id: "m3", operatorID: "op.ineligible")
            ],
            operators: [eligibleOperator, ineligibleOperator]
        )

        let characteristics = await ExecutionProfileSupport.characteristics(
            plan: plan, resolution: resolution(kind: .swiftPackageMacOS)
        )

        #expect(characteristics.schemataEligibleMutationCount == 2)
        #expect(characteristics.totalMutationCount == 3)
        #expect(characteristics.schemataEligibleOperatorIDs == ["op.eligible"])
    }

    @Test("an enabled, schemata-eligible operator with zero actual planned mutations never appears in the reported operator ID list")
    func eligibleButUnusedOperatorIsExcludedFromTheReportedList() async {
        let usedEligibleOperator = stubOperator(id: "op.used", schemataEligible: true)
        let unusedEligibleOperator = stubOperator(id: "op.unused", schemataEligible: true)
        let plan = stubPlan(
            mutations: [stubPoint(id: "m1", operatorID: "op.used")],
            operators: [usedEligibleOperator, unusedEligibleOperator]
        )

        let characteristics = await ExecutionProfileSupport.characteristics(
            plan: plan, resolution: resolution(kind: .swiftPackageMacOS)
        )

        // The count was never wrong (it is derived from `plan.mutations`
        // directly, which never included `op.unused` in the first place) —
        // what this pins is the human-readable operator list not padding
        // itself with a name that backs zero planned mutations.
        #expect(characteristics.schemataEligibleMutationCount == 1)
        #expect(characteristics.schemataEligibleOperatorIDs == ["op.used"])
    }

    @Test("zero planned mutations reports zero eligible and an empty operator list, never a division-by-zero crash")
    func emptyPlanReportsZero() async {
        let plan = stubPlan(mutations: [], operators: [stubOperator(id: "op.a", schemataEligible: true)])
        let characteristics = await ExecutionProfileSupport.characteristics(
            plan: plan, resolution: resolution(kind: .swiftPackageMacOS)
        )
        #expect(characteristics.schemataEligibleMutationCount == 0)
        #expect(characteristics.totalMutationCount == 0)
        #expect(characteristics.schemataEligibleOperatorIDs.isEmpty)
    }

    // MARK: - Adapter conformance checks

    @Test("perTestCoverageAdapterCapable/testAdapterBatchTestable are true for an adapter conforming to those protocols")
    func conformingAdapterReportsCapable() async {
        let plan = stubPlan(mutations: [], operators: [])
        let characteristics = await ExecutionProfileSupport.characteristics(
            plan: plan, resolution: resolution(kind: .swiftPackageMacOS, test: CapableTestAdapter())
        )
        #expect(characteristics.perTestCoverageAdapterCapable == true)
        #expect(characteristics.testAdapterBatchTestable == true)
    }

    @Test("perTestCoverageAdapterCapable/testAdapterBatchTestable are false for a bare TestAdapter")
    func nonConformingAdapterReportsIncapable() async {
        let plan = stubPlan(mutations: [], operators: [])
        let characteristics = await ExecutionProfileSupport.characteristics(
            plan: plan, resolution: resolution(kind: .swiftPackageMacOS, test: BareTestAdapter())
        )
        #expect(characteristics.perTestCoverageAdapterCapable == false)
        #expect(characteristics.testAdapterBatchTestable == false)
    }

    // MARK: - sharedModuleCacheSupported: swiftPackageMacOS-only, no filesystem probe

    @Test("sharedModuleCacheSupported is true only for a swiftPackageMacOS resolution")
    func sharedModuleCacheSupportedOnlyForSwiftPackageMacOS() async {
        let plan = stubPlan(mutations: [], operators: [])

        let macOS = await ExecutionProfileSupport.characteristics(plan: plan, resolution: resolution(kind: .swiftPackageMacOS))
        #expect(macOS.sharedModuleCacheSupported == true)

        for kind: ProjectKind in [.xcodeProject, .xcodeWorkspace, .swiftPackageApple] {
            let characteristics = await ExecutionProfileSupport.characteristics(plan: plan, resolution: resolution(kind: kind))
            #expect(characteristics.sharedModuleCacheSupported == false, "expected \(kind) to report unsupported")
        }
    }

    /// Pins the short-circuit itself, not just its outcome: an earlier
    /// revision computed this by constructing a real `WorkspaceManager`
    /// (which requires — and side-effects — a real, writable scratch root)
    /// purely to probe `clonefile(2)` support, for a precondition
    /// `ExecutionSettings.sharedModuleCache` never actually depended on.
    /// This test's `projectRoot` is a path that cannot possibly exist as a
    /// writable directory; if `characteristics` still tried to construct a
    /// `WorkspaceManager` against it, that would either throw (silently
    /// swallowed, `sharedModuleCacheSupported` still `false` — indistinguishable
    /// from this test's own expectation) or hang/fail loudly for a
    /// non-swiftPackageMacOS kind that has no business touching a
    /// filesystem at all. Asserting this completes instantly, synchronously,
    /// for an adapter kind the real gate always short-circuits on is the
    /// closest a black-box test can get to proving the probe is gone.
    @Test("the non-swiftPackageMacOS short-circuit never touches the filesystem")
    func nonSwiftPackageMacOSNeverProbesTheFilesystem() async {
        let plan = stubPlan(mutations: [], operators: [])
        let bogusRoot = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/definitely/not/real")
        let bogusResolution = AppleAdapterFactory.Resolution(
            adapter: StubAdapter(kind: .xcodeProject, test: BareTestAdapter()),
            detection: ProjectDetection(kind: .xcodeProject, reason: "test", projectFile: bogusRoot)
        )
        let characteristics = await ExecutionProfileSupport.characteristics(plan: plan, resolution: bogusResolution)
        #expect(characteristics.sharedModuleCacheSupported == false)
        #expect(!FileManager.default.fileExists(atPath: bogusRoot.path), "characteristics must never have created anything at this path")
    }
}
