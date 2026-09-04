import ArgumentParser
import Foundation
import MutationExecution
import MutationModel

/// Diagnoses the environment before the user commits to a configuration.
///
/// This runs first for a reason. Almost every painful failure in this category
/// of tool is an environment mismatch discovered an hour into a run — the wrong
/// build system for the package, a scheme that is not shared, an `.xctestrun`
/// that is not where it was assumed to be. `doctor` asks those questions in
/// seconds, before a config file exists to be blamed.
///
/// The checks themselves live in `ReadinessCheck` — `mutantkit setup` runs the
/// identical checks as one step of its own golden-path flow, so the logic is
/// not duplicated between the two commands.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that this environment can run mutation testing."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Skip the trial build. Faster, but proves much less.")
    var skipBuild = false

    /// `BuildDiagnosis` is already exactly the shape an agent wants —
    /// `canProceed` plus the `[DiagnosisItem]` that explain it, fully
    /// computed before either output path renders it — so this serializes
    /// it directly (with `schemaVersion` added, see `BuildDiagnosis`'s own
    /// doc comment), the same choice the prior phase made for `gate --json`
    /// and `QualityGateResult`. Exit codes are untouched: `--json` still
    /// throws `MutantKitExit.operationalError` when `!canProceed`, after
    /// emitting the JSON document, so a CI script can rely on the exit code
    /// alone or parse `--json` and get the identical verdict.
    @Flag(name: .long, help: "Emit the diagnosis as JSON instead of the text report below.")
    var json = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let outcome = await ReadinessCheck.run(root: root, configPath: common.configPath, skipBuild: skipBuild)

        // Appended here, in `DoctorCommand` itself, rather than inside
        // `ReadinessCheck.diagnose` where every other item above is
        // assembled: a separate, parallel effort is adding a broader
        // environment/capability summary to that same shared function at
        // the same time, and this stays a single, self-contained addition
        // with no edit to that function at all, to keep the two lanes from
        // colliding there. `BuildDiagnosis.init` recomputes `canProceed`
        // from the combined items, so this cannot silently change the
        // ready/not-ready verdict — this item's own `status` is always
        // `.ok` (see `Self.sharedModuleCacheDiagnosis`'s own doc comment).
        //
        // `ReadinessCheck.deduplicated(...)` already ran once, inside
        // `ReadinessCheck.diagnose`, before this item was ever appended —
        // this item cannot benefit from that pass merely by arriving
        // after it. Re-running the identical pass over the combined list
        // is what stops a same-named item appended here from ever
        // silently surviving alongside one `ReadinessCheck.diagnose`
        // already produced (exactly the collision this lane's own,
        // now-deleted `sharedModuleCacheSupport` diagnostic would have
        // caused against this function's `sharedModuleCache` item, had
        // both existed at once — see `DiagnosisNameUniquenessTests`).
        let diagnosis = BuildDiagnosis(
            items: ReadinessCheck.deduplicated(
                outcome.diagnosis.items + [await Self.sharedModuleCacheDiagnosis(root: root, configuration: outcome.configuration)]
            )
        )

        if json {
            try JSONOutput.emit(diagnosis)
        } else {
            print("Diagnosing \(root.path)\n")
            print(ReadinessCheck.render(diagnosis))
        }

        guard diagnosis.canProceed else {
            if !json {
                print("\nNot ready. Fix the failures above, then run `mutantkit doctor` again.")
            }
            throw ExitCode(MutantKitExit.operationalError)
        }
        if !json {
            print("\nReady. Next: `mutantkit init` to write a config, then `mutantkit plan`.")
        }
    }

    /// `Configuration.execution.sharedModuleCache`'s real status on this
    /// machine — see that flag's own doc comment, and
    /// `WorkspaceManager.moduleCachePath`/`SharedModuleCacheFingerprint` for
    /// what these three values mean and how they are derived. Narrowly
    /// scoped on purpose (see this method's call site above): only this one
    /// diagnostic item, nothing broader added to `doctor`'s general
    /// environment summary in this pass.
    ///
    /// Informational only — `status` is always `.ok`, never `.warning`/
    /// `.failure`: whether this flag would help is a call the user makes
    /// for their own project, not something `doctor` gates readiness on.
    /// The flag itself stays off by default regardless of what this
    /// diagnostic reports.
    ///
    /// Computed unconditionally, regardless of `--skip-build` or whether
    /// the flag is already on in the loaded configuration: probing the
    /// toolchain and testing `clonefile(2)` needs no trial build, so this
    /// stays available even on the fast `--skip-build` path — a user still
    /// deciding whether to opt in needs to see what the flag would resolve
    /// to *before* turning it on, not only after.
    static func sharedModuleCacheDiagnosis(root: URL, configuration: Configuration) async -> DiagnosisItem {
        let cloneSupported = WorkspaceManager.probeAPFSCloneSupport(at: root)
        let fingerprint = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: root)
        // The scratch root a real `mutantkit run` resolves (`RunCommand`'s
        // own `root.appendingPathComponent(".mutantkit")` +
        // `"sandboxes"`) — previewed here purely so this report can show a
        // concrete path, not because `doctor` creates or touches it.
        let previewScratchRoot = root.appendingPathComponent(".mutantkit/sandboxes", isDirectory: true)
        let cachePath = WorkspaceManager.moduleCachePath(underScratchRoot: previewScratchRoot, fingerprint: fingerprint.digest)

        return DiagnosisItem(
            name: "Shared module cache",
            status: .ok,
            code: .sharedModuleCache,
            detail: """
            execution.sharedModuleCache: \(configuration.execution.sharedModuleCache ? "on" : "off (default)") \
            (isolated SwiftPM/macOS builds only today — no effect on an Xcode project/workspace or a non-macOS \
            Swift package). APFS clonefile: \(cloneSupported ? "supported" : "not supported — falls back to a plain copy"). \
            Toolchain fingerprint \(fingerprint.digest) (\(fingerprint.canonicalDescription)). \
            Resolved cache path for `mutantkit run`: \(cachePath.path).
            """
        )
    }
}
