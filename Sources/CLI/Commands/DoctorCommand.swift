import ArgumentParser
import Foundation

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

        if json {
            try JSONOutput.emit(outcome.diagnosis)
        } else {
            print("Diagnosing \(root.path)\n")
            print(ReadinessCheck.render(outcome.diagnosis))
        }

        guard outcome.diagnosis.canProceed else {
            if !json {
                print("\nNot ready. Fix the failures above, then run `mutantkit doctor` again.")
            }
            throw ExitCode(MutantKitExit.operationalError)
        }
        if !json {
            print("\nReady. Next: `mutantkit init` to write a config, then `mutantkit plan`.")
        }
    }
}
