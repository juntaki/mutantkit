@testable import CLI
import Foundation
@testable import MutationExecution
import MutationModel
import Testing

/// Adversarial-review finding #3 on the `retestKilledMutants`/
/// `PackageManifestConfirmationRetesting` fix: left alone,
/// `MutationConfirmationCoordinator.confirmKill`'s own `swift test
/// --skip-build --package-path <projectRoot> --scratch-path <clone>` would
/// be the *first* command any MutantKit run ever targets `projectRoot`
/// with — for a pristine SwiftPM project (no committed `Package.resolved`),
/// that means SwiftPM's first-ever dependency resolution, and the fresh
/// `Package.resolved` it writes, would happen unexpectedly inside a
/// deferred confirmation retest, potentially hours into a run, rather than
/// up front. `RunCommand.resolveDependenciesForConfirmationRetestIfNeeded`
/// fixes this: an explicit, logged, once-per-run preflight, gated on the
/// same precondition `confirmKill`'s own dispatch checks.
///
/// This suite proves the *dispatch* (gating + wrapper unwrapping) with a
/// fast, scripted mock — mirroring `RunCommandTestAdapterResolutionTests`'
/// own style for `resolveTestAdapter`. The real toolchain proof (a genuine
/// `swift package resolve` writing `Package.resolved` into a pristine
/// project root, via the actual `SwiftPackageMacOSAdapter`, through this
/// same dispatch) lives in `SwiftPackageMacOSDependencyResolutionPreflightAcceptanceTests`.
@Suite("RunCommand: dependency-resolution preflight for confirmation retests")
struct RunCommandDependencyResolutionPreflightTests {
    private func configuration(retestKilledMutants: Bool) -> Configuration {
        Configuration(execution: ExecutionSettings(retestKilledMutants: retestKilledMutants))
    }

    private var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("preflight-root-\(UUID().uuidString)")
    }

    @Test("retestKilledMutants off: never calls the adapter, even though it conforms")
    func retestKilledMutantsOffNeverCalls() async throws {
        let log = ResolveCallLog()
        try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
            configuration(retestKilledMutants: false), testAdapter: FakeManifestConfirmationAdapter(log: log), root: root
        )
        let calls = await log.calls
        #expect(calls.isEmpty, "must be a no-op when retestKilledMutants is off — the default")
    }

    @Test("retestKilledMutants on but the adapter does not conform: never calls anything, no crash")
    func nonConformingAdapterNeverCalls() async throws {
        // Compiles and runs fine with a plain adapter — nothing to unwrap or
        // dispatch to, exactly like the Xcode backend's own `.xctestrun`-
        // based confirmation, which never needs this at all.
        try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
            configuration(retestKilledMutants: true), testAdapter: PlainFakeTestAdapter(), root: root
        )
    }

    @Test("retestKilledMutants on and the adapter conforms directly: calls it exactly once, with the real project root")
    func conformingAdapterIsCalledWithProjectRoot() async throws {
        let log = ResolveCallLog()
        let projectRoot = root
        try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
            configuration(retestKilledMutants: true), testAdapter: FakeManifestConfirmationAdapter(log: log), root: projectRoot
        )
        let calls = await log.calls
        #expect(calls == [projectRoot], "must resolve against the tool's own stable project root, never a sandbox")
    }

    /// The exact regression finding #1's own fix exists for, reused here:
    /// `PrioritizingTestAdapter` (installed whenever `selectCoveringTests`
    /// + `earlyAbortSelectedTests` are both on) wraps a genuinely-
    /// conforming adapter opaquely. This preflight must see through it via
    /// `TestAdapterWrapping`/`packageManifestConfirmationRetesting(for:)`
    /// exactly the way `MutationConfirmationCoordinator.confirmKill` does —
    /// a preflight that silently skipped a wrapped adapter would defeat the
    /// fix just as silently as the original, un-fixed `confirmKill` cast did.
    @Test("retestKilledMutants on and the adapter conforms only through a TestAdapterWrapping wrapper: still called")
    func wrappedConformingAdapterIsStillCalled() async throws {
        let log = ResolveCallLog()
        let projectRoot = root
        let wrapped = PrioritizingTestAdapter(
            base: FakeManifestConfirmationAdapter(log: log),
            priorityStore: TestPriorityStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("priority-\(UUID().uuidString).json"))
        )
        try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
            configuration(retestKilledMutants: true), testAdapter: wrapped, root: projectRoot
        )
        let calls = await log.calls
        #expect(calls == [projectRoot], "must unwrap PrioritizingTestAdapter to reach the real adapter underneath")
    }

    @Test("A resolution failure propagates rather than being silently swallowed")
    func resolutionFailurePropagates() async throws {
        let log = ResolveCallLog()
        await log.scriptFailure()
        await #expect(throws: (any Error).self) {
            try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
                configuration(retestKilledMutants: true), testAdapter: FakeManifestConfirmationAdapter(log: log), root: root
            )
        }
    }
}

// MARK: - Shared test infrastructure

private actor ResolveCallLog {
    private(set) var calls: [URL] = []
    private var shouldFail = false

    func record(_ packageRoot: URL) throws {
        calls.append(packageRoot)
        if shouldFail {
            struct Scripted: Error {}
            throw Scripted()
        }
    }

    func scriptFailure() {
        shouldFail = true
    }
}

private struct PlainFakeTestAdapter: TestAdapter {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }
}

private struct FakeManifestConfirmationAdapter: TestAdapter, PackageManifestConfirmationRetesting {
    let log: ResolveCallLog

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func runConfirmationRetest(
        _ point: MutationPoint, packageRoot: URL, productsScratchRoot: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        fatalError("not exercised")
    }

    func resolveDependenciesForConfirmationRetest(packageRoot: URL, timeoutSeconds: Double) async throws {
        try await log.record(packageRoot)
    }
}
