import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend
import Testing

/// Pins the fix for the schemata-availability line in `mutantkit doctor`'s
/// execution-capabilities summary: it used to answer "is schemata available"
/// purely from `adapter.build is SchemataBuildable && adapter.test is
/// SchemataTestable` — a check that is true for `.swiftPackageApple`,
/// `.xcodeProject` *and* `.xcodeWorkspace` alike, because
/// `AppleAdapterFactory.adapter(for:)` maps all three to the same
/// `XcodeBuildProjectAdapter`/`XcodeBuildAdapter` pair regardless of which
/// kind is actually in play. `docs/schemata-support-matrix.md` — the
/// project's own real, E2E-proven support table — says `swiftPackageApple`
/// and `xcodeWorkspace` are **Unsupported**, so the old check silently
/// contradicted the project's own authoritative documentation for both.
///
/// `ExecutionCapabilitiesDiagnosis.schemataSupported(for:)` now sources the
/// answer from `ProjectKind` directly, matching the matrix by construction.
@Suite("ExecutionCapabilitiesDiagnosis: schemata availability")
struct ExecutionCapabilitiesDiagnosisSchemataTests {
    // MARK: - schemataSupported(for:) matches docs/schemata-support-matrix.md exactly

    @Test(
        "schemataSupported(for:) matches docs/schemata-support-matrix.md's Supported/Unsupported rows for every ProjectKind",
        arguments: [
            (ProjectKind.swiftPackageMacOS, true),
            (ProjectKind.xcodeProject, true),
            (ProjectKind.swiftPackageApple, false),
            (ProjectKind.xcodeWorkspace, false)
        ]
    )
    func schemataSupportMatchesMatrix(kind: ProjectKind, expectedSupported: Bool) {
        #expect(
            ExecutionCapabilitiesDiagnosis.schemataSupported(for: kind) == expectedSupported,
            "\(kind.rawValue) disagrees with docs/schemata-support-matrix.md"
        )
    }

    // MARK: - items(for:configuration:) end to end, per ProjectKind

    @Test(
        "The \"Schemata execution\" item's status/code follow the matrix for each ProjectKind, with a default Configuration",
        arguments: [
            (ProjectKind.swiftPackageMacOS, DiagnosisItem.Status.ok),
            (ProjectKind.xcodeProject, DiagnosisItem.Status.ok),
            (ProjectKind.swiftPackageApple, DiagnosisItem.Status.warning),
            (ProjectKind.xcodeWorkspace, DiagnosisItem.Status.warning)
        ]
    )
    func schemataItemStatusPerProjectKind(kind: ProjectKind, expectedStatus: DiagnosisItem.Status) {
        let resolution = makeResolution(kind: kind, test: FakeSchemataTestAdapter())
        let items = ExecutionCapabilitiesDiagnosis.items(for: resolution, configuration: Configuration())
        let schemataItem = items.first { $0.code == .schemataExecutionSupport }

        #expect(schemataItem?.status == expectedStatus, "\(String(describing: schemataItem))")
        if expectedStatus == .warning {
            #expect(schemataItem?.detail.contains(kind.rawValue) == true)
        }
    }

    // MARK: - selectCoveringTests + earlyAbortSelectedTests interaction

    /// The second half of the fix: even a `schemataSupported` kind can lose
    /// schemata at run time. `RunCommand.resolveTestAdapter` wraps the base
    /// test adapter in `PrioritizingTestAdapter` (`TestSelecting`-only, not
    /// `SchemataTestable`) whenever `execution.selectCoveringTests` and
    /// `execution.earlyAbortSelectedTests` are both on and batching isn't
    /// taking over instead — this test drives that exact combination
    /// through the diagnostic and confirms it reports the *blocked*
    /// answer, not the kind-level "available" one.
    @Test("selectCoveringTests + earlyAbortSelectedTests, no batching-capable adapter: schemata reported unavailable for this run")
    func selectCoveringTestsWithEarlyAbortBlocksSchemata() {
        let resolution = makeResolution(kind: .swiftPackageMacOS, test: FakeSchemataTestAdapter())
        let configuration = configuration(selectCoveringTests: true, earlyAbort: true, testBatchSize: nil)

        let items = ExecutionCapabilitiesDiagnosis.items(for: resolution, configuration: configuration)
        let schemataItem = items.first { $0.code == .schemataExecutionSupport }

        #expect(schemataItem?.status == .warning, "\(String(describing: schemataItem))")
        #expect(schemataItem?.detail.contains("this run's configuration") == true)
        #expect(schemataItem?.remedy != nil)
    }

    /// The wave-mode escape hatch: `testBatchSize` set *and* the resolved
    /// test adapter conforms to `BatchTestable` means `resolveTestAdapter`
    /// hands the runner the base adapter unwrapped (see that function's
    /// own doc comment on wave mode) — schemata stays available.
    @Test("selectCoveringTests + earlyAbortSelectedTests + testBatchSize with a batching-capable adapter: schemata stays available")
    func selectCoveringTestsWithBatchingCapableAdapterKeepsSchemataAvailable() {
        let resolution = makeResolution(kind: .swiftPackageMacOS, test: FakeSchemataBatchableTestAdapter())
        let configuration = configuration(selectCoveringTests: true, earlyAbort: true, testBatchSize: 10)

        let items = ExecutionCapabilitiesDiagnosis.items(for: resolution, configuration: configuration)
        let schemataItem = items.first { $0.code == .schemataExecutionSupport }

        #expect(schemataItem?.status == .ok, "\(String(describing: schemataItem))")
    }

    /// A kind the matrix already marks Unsupported must stay unavailable
    /// regardless of `Configuration` — the run's own test-adapter wrapping
    /// only matters once the kind itself clears the first gate.
    @Test("An unsupported ProjectKind stays unavailable even with a schemata-friendly Configuration")
    func unsupportedKindStaysUnavailableRegardlessOfConfiguration() {
        let resolution = makeResolution(kind: .xcodeWorkspace, test: FakeSchemataBatchableTestAdapter())
        let configuration = configuration(selectCoveringTests: false, earlyAbort: false, testBatchSize: nil)

        let items = ExecutionCapabilitiesDiagnosis.items(for: resolution, configuration: configuration)
        let schemataItem = items.first { $0.code == .schemataExecutionSupport }

        #expect(schemataItem?.status == .warning, "\(String(describing: schemataItem))")
        #expect(schemataItem?.detail.contains("xcodeWorkspace") == true)
    }

    // MARK: - Helpers

    private func configuration(selectCoveringTests: Bool, earlyAbort: Bool, testBatchSize: Int?) -> Configuration {
        Configuration(execution: ExecutionSettings(
            selectCoveringTests: selectCoveringTests,
            earlyAbortSelectedTests: earlyAbort,
            testBatchSize: testBatchSize
        ))
    }

    private func makeResolution(kind: ProjectKind, test: any TestAdapter) -> AppleAdapterFactory.Resolution {
        AppleAdapterFactory.Resolution(
            adapter: FakeProjectAdapter(kind: kind, build: FakeBuildAdapter(), test: test),
            detection: ProjectDetection(kind: kind, reason: "test fixture", projectFile: nil)
        )
    }
}

// MARK: - Fakes

/// Minimal `BuildAdapter` — `schemataItem` never touches `adapter.build`
/// (availability is sourced from `ProjectKind` plus the resolved test
/// adapter only, see that function's own doc comment), so this only needs
/// to exist to satisfy `ProjectAdapter`'s shape.
private struct FakeBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }
    func buildBaseline(in workspace: URL) async throws -> BuildArtifact { fatalError("not exercised") }
    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact { fatalError("not exercised") }
}

private struct FakeSchemataTestAdapter: TestAdapter, SchemataTestable {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        environment: [String: String], selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }
}

private struct FakeSchemataBatchableTestAdapter: TestAdapter, SchemataTestable, BatchTestable {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        environment: [String: String], selectedTests: Set<TestIdentifier>?
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

private struct FakeProjectAdapter: ProjectAdapter {
    let kind: ProjectKind
    let build: any BuildAdapter
    let test: any TestAdapter
}
