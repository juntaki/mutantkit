import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Regression coverage for the actual production fix: with
/// `Configuration.execution.retestKilledMutants` on, the isolated SwiftPM
/// macOS backend's confirmation retest used to run `swift test --skip-build`
/// against a bare products-only clone (`WorkspaceManager.cloneProducts`'s
/// flat shape) — a directory with no `Package.swift` and no real target
/// source tree, which SwiftPM cannot resolve a package graph from at all.
/// The retest failed before it ever ran a single test, and `MutationVerdictVerifier`
/// correctly (but only because it fails safe) sank the confirmation to
/// `.flaky` rather than crediting an unconfirmable kill — root-caused in
/// `Research/product-completeness-2026-08/F7-A-E-FREEZE-RELEASE-GATE.md`.
///
/// The fix: `MutationConfirmationCoordinator.confirmKill` now dispatches to
/// `PackageManifestConfirmationRetesting.runConfirmationRetest` when the
/// test adapter conforms to it, handing it `packageRoot` (the tool's own
/// stable, read-only `projectRoot` — never a per-mutant sandbox) alongside
/// a nested `<triple>/<configuration>`-shaped products clone
/// (`WorkspaceManager.cloneProductsForConfirmation`) instead of retesting
/// directly against a bare products clone the way every other adapter still
/// does.
///
/// This suite proves the *dispatch* mechanism end to end via a mock adapter
/// (fast, no real toolchain — the real `SwiftPackageMacOSAdapter` +
/// real `swift build`/`swift test` end-to-end proof lives in the acceptance
/// suite, `SchemataConfirmationDifferentialAcceptanceTests`, which this same
/// fix now makes pass): that `confirmKill` calls the new method rather than
/// the ordinary `runMutant` path, that it is handed the correct
/// `packageRoot`, and that the mutant's final verdict is a genuine
/// confirmed kill rather than falling to `.flaky`.
@Suite("Mutation runner: confirmKill dispatches to a manifest-dependent adapter's own confirmation retest")
struct MutationRunnerManifestDependentConfirmationRetestTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-manifest-confirm-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-manifest-confirm-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    @Test("A manifest-dependent adapter's confirmation retest is used instead of runMutant, and the kill is genuinely confirmed")
    func manifestDependentRetestIsUsedAndTheKillIsConfirmed() async throws {
        try writeSingleMutantProject()

        let configuration = Configuration(execution: ExecutionSettings(retestKilledMutants: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let log = ManifestDependentCallLog()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: RecordingBuildAdapter(log: log),
            test: ManifestDependentRecordingTestAdapter(log: log),
            workspaces: workspaces
        )
        let report = try await runner.run()

        // The ordinary `runMutant` path must have been used exactly once —
        // the primary test — never for the confirmation retest too.
        let primaryCalls = await log.runMutantCalls
        #expect(primaryCalls.count == 1, "the primary test must go through the ordinary runMutant path exactly once")

        // The new, manifest-dependent retest must have been used exactly
        // once — the confirmation — never falling back to the ordinary path.
        let confirmationCalls = await log.confirmationRetestCalls
        #expect(confirmationCalls.count == 1, "the confirmation retest must go through runConfirmationRetest, not runMutant")

        let confirmation = try #require(confirmationCalls.first)

        // `packageRoot` must be the tool's own stable projectRoot, never a
        // per-mutant sandbox -- see `PackageManifestConfirmationRetesting`'s
        // own doc comment for why that stability is load-bearing, not
        // incidental.
        #expect(confirmation.packageRoot == root, "packageRoot must be the tool's own stable projectRoot")

        // `productsScratchRoot` must be independent of the primary run's own
        // workspace -- the same isolation invariant
        // `MutationRunnerConfirmKillWorkspaceIsolationTests` already proves
        // for the ordinary path, which must hold here too.
        #expect(
            confirmation.productsScratchRoot != primaryCalls.first,
            "the confirmation retest's own products clone must be independent of the primary run's workspace"
        )

        // The actual property under test: a real, genuine confirmed kill --
        // not a fall-through to .flaky, which is exactly what the original
        // bug produced (the confirmation retest could not even launch a
        // resolvable `swift test` invocation).
        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion, "expected a confirmed kill, not a fall-through to .flaky: \(result.diagnosis)")
        #expect(
            result.diagnosis.contains("Confirmed by a second run of the identical mutant, failing the same test(s)."),
            "expected the shared MutationVerdictVerifier.confirmKill diagnosis text: \(result.diagnosis)"
        )
    }
}

// MARK: - Shared test infrastructure

private struct ConfirmationRetestCall {
    let packageRoot: URL
    let productsScratchRoot: URL
}

private actor ManifestDependentCallLog {
    private(set) var runMutantCalls: [URL] = []
    private(set) var confirmationRetestCalls: [ConfirmationRetestCall] = []

    func recordRunMutant(workspace: URL) {
        runMutantCalls.append(workspace)
    }

    func recordConfirmationRetest(packageRoot: URL, productsScratchRoot: URL) {
        confirmationRetestCalls.append(
            ConfirmationRetestCall(packageRoot: packageRoot, productsScratchRoot: productsScratchRoot)
        )
    }
}

/// Always succeeds, with a mutant product hash that differs from the
/// baseline's -- activation evidence is proven, so classification reaches
/// the test-status branch this suite actually exercises. `productsDirectory`
/// is the workspace itself, matching every other suite's own recording
/// build adapter (`MutationRunnerConfirmKillWorkspaceIsolationTests`,
/// `MutationRunnerTimeoutConfirmationInnerRetestIsolationTests`) --
/// `cloneProductsForConfirmation` then clones the whole sandbox, nested
/// under its own resolved `<triple>/<configuration>`-shaped path (here,
/// whatever `workspace`'s own last two path components happen to be --
/// this suite does not depend on them looking like a real toolchain
/// triple, only on the clone being real and independent).
private struct RecordingBuildAdapter: BuildAdapter {
    let log: ManifestDependentCallLog

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "baseline-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "mutant-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Conforms to both `TestAdapter` (the primary test path) and
/// `PackageManifestConfirmationRetesting` (the confirmation retest path) --
/// exactly the shape `SwiftPackageMacOSAdapter` itself now has. Both scripted
/// runs report `.failed` with the identical failing-test set, so
/// `MutationVerdictVerifier.confirmKill` reaches a genuine confirmed kill.
private actor ManifestDependentRecordingTestAdapter: TestAdapter, PackageManifestConfirmationRetesting {
    let log: ManifestDependentCallLog

    init(log: ManifestDependentCallLog) {
        self.log = log
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        await log.recordRunMutant(workspace: workspace)
        return Self.result(.failed)
    }

    func runConfirmationRetest(
        _ point: MutationPoint,
        packageRoot: URL,
        productsScratchRoot: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        await log.recordConfirmationRetest(packageRoot: packageRoot, productsScratchRoot: productsScratchRoot)
        return Self.result(.failed)
    }

    /// This suite drives `MutationRunner` directly, never `RunCommand`'s own
    /// preflight — nothing here calls this method, so a no-op satisfies the
    /// protocol without needing its own recording/assertion machinery.
    func resolveDependenciesForConfirmationRetest(packageRoot: URL, timeoutSeconds: Double) async throws {}

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)"
        )
    }
}
