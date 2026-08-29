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

    func run() async throws {
        let root = common.resolvedProjectRoot
        print("Diagnosing \(root.path)\n")

        let outcome = await ReadinessCheck.run(root: root, configPath: common.configPath, skipBuild: skipBuild)
        print(ReadinessCheck.render(outcome.diagnosis))

        guard outcome.diagnosis.canProceed else {
            print("\nNot ready. Fix the failures above, then run `mutantkit doctor` again.")
            throw ExitCode(MutantKitExit.operationalError)
        }
        print("\nReady. Next: `mutantkit init` to write a config, then `mutantkit plan`.")
    }
}
