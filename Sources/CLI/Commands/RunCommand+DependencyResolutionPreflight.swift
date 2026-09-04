import ArgumentParser
import Foundation
import MutationExecution
import MutationModel

/// Adversarial-review finding (NO_GO secondary gap #3 on the
/// `retestKilledMutants`/`PackageManifestConfirmationRetesting` fix), kept
/// in its own file rather than inlined in `RunCommand.swift` (already at
/// this project's `file_length` threshold before this fix, independent of
/// it) — same motive as `RunCommand.swift`'s own `--report`/`--also-report`
/// extension, purely for size, not because this belongs to a different
/// feature than `resolveTestAdapter`/`lockIdentity` there.
extension RunCommand {
    /// An explicit, logged, once-per-run preflight that resolves `root`'s
    /// own package dependencies *before* any mutation testing begins, so a
    /// deferred confirmation retest — potentially the run's only command
    /// ever to target `root` directly — is never the first thing that
    /// resolves them. See `PackageManifestConfirmationRetesting
    /// .resolveDependenciesForConfirmationRetest`'s own doc comment for the
    /// full "why" this precondition does not already hold on its own.
    ///
    /// Gated on both halves of the real precondition, exactly like
    /// `ExecutionCapabilitiesDiagnosis.schemataItem`'s own
    /// `PrioritizingTestAdapter.wouldWrap` check does for a different
    /// question: `execution.retestKilledMutants` (the only flag that can
    /// ever cause `MutationConfirmationCoordinator.confirmKill` to reach
    /// `runConfirmationRetest` at all) *and* `testAdapter` — resolved
    /// through `packageManifestConfirmationRetesting(for:)`, which
    /// unwraps a `TestAdapterWrapping` layer such as `PrioritizingTestAdapter`
    /// exactly the way `confirmKill`'s own dispatch does, so this preflight
    /// can never disagree with what a real confirmation retest would
    /// actually use. A project whose test adapter does not conform (the
    /// Xcode backend, whose `.xctestrun`-based confirmation never looks
    /// outside its own products clone) or a run with `retestKilledMutants`
    /// off (the default) pays nothing extra: this is a no-op for both.
    static func resolveDependenciesForConfirmationRetestIfNeeded(
        _ settings: Configuration, testAdapter: any TestAdapter, root: URL
    ) async throws {
        guard settings.execution.retestKilledMutants,
              let manifestDependent = packageManifestConfirmationRetesting(for: testAdapter) else { return }
        print("Resolving package dependencies in \(root.path) (once, up front — retestKilledMutants would otherwise trigger this for the first time inside a later confirmation retest)…")
        do {
            try await manifestDependent.resolveDependenciesForConfirmationRetest(
                packageRoot: root, timeoutSeconds: settings.timeouts.baselineSeconds
            )
        } catch {
            print("Dependency resolution failed: \(error)")
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
