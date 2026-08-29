import ArgumentParser
import Foundation

/// Chains the detection `mutantkit init` performs with the diagnostics
/// `mutantkit doctor` performs, in one command, so a brand-new project can go
/// from nothing to a runnable `mutantkit.yml` without first learning which of
/// several commands answers which question.
///
/// `setup` orchestrates the same shared-library calls `init`/`doctor` already
/// use — via `ProjectDetectionPlan` and `ReadinessCheck`, both factored out of
/// those commands for exactly this reuse — rather than reimplementing
/// detection or diagnostics, and rather than invoking another command's
/// `run()` (this codebase's orchestration convention is shared-library calls,
/// not commands calling commands).
///
/// It still writes nothing it was not explicitly allowed to write (never
/// overwrites an existing `mutantkit.yml` without `--force`), never guesses
/// an ambiguous scheme or test target, and never starts a mutation run: the
/// actual campaign (`mutantkit plan` + `mutantkit run`) is left for a human
/// or agent to start deliberately, once `setup`'s own suggested `mutantkit
/// dry-run` has passed.
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Detect this project, check readiness, and write mutantkit.yml in one step.",
        discussion: """
        Equivalent to running `mutantkit init` and then `mutantkit doctor` against the config \
        it just wrote, and telling you the next command to run. It never overwrites an existing \
        mutantkit.yml without --force, never guesses an ambiguous scheme or test target — it \
        reports those and stops short of a verdict — and never starts a mutation run itself.

        Pass --dry-run to preview exactly what would be detected and written, without writing \
        anything. Safe to run repeatedly, including from an agent deciding whether to proceed.
        """
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Overwrite an existing mutantkit.yml.")
    var force = false

    @Flag(name: .long, help: "Show what setup would detect and write, without writing anything.")
    var dryRun = false

    @Flag(name: .long, help: "Skip the trial build during the readiness check. Faster, but proves much less.")
    var skipBuild = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let destination = root.appendingPathComponent(ConfigurationLoader.fileName)
        let alreadyExists = FileManager.default.fileExists(atPath: destination.path)

        if alreadyExists, !force, !dryRun {
            print("\(destination.path) already exists. Pass --force to overwrite it, or --dry-run to preview without writing.")
            throw ExitCode(MutantKitExit.operationalError)
        }

        print("Detecting \(root.path)\n")
        let plan = await ProjectDetectionPlan.detect(root: root)
        print(plan.summaryLines.joined(separator: "\n"))

        if dryRun {
            print("\n--- \(ConfigurationLoader.fileName) (preview; not written) ---\n\(plan.template)")
        } else {
            try Data(plan.template.utf8).write(to: destination, options: .atomic)
            print("\nWrote \(destination.path)")
        }

        // Same checks `doctor` runs, against the config `setup` just wrote (or,
        // in --dry-run, whatever is already on disk — the preview above already
        // covers what would change). This is what actually proves the golden
        // path end to end: a freshly-detected config that also passes the real
        // toolchain/build/host checks, not just one that looks plausible.
        print("\nChecking readiness…\n")
        let readiness = await ReadinessCheck.run(root: root, configPath: common.configPath, skipBuild: skipBuild)
        print(ReadinessCheck.render(readiness.diagnosis))

        let step = Self.nextStep(
            dryRun: dryRun,
            hasTestTargets: plan.hasTestTargets,
            schemeAmbiguous: plan.schemeAmbiguous,
            environmentReady: readiness.diagnosis.canProceed
        )
        print("\n\(Self.message(for: step, configPath: destination.path))")

        if case .environmentNotReady = step {
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    /// What `setup` should tell the user to do next. Pure decision logic,
    /// factored out of `run()` so every combination of outcome can be unit
    /// tested directly, without running real detection, `xcodebuild`, or a
    /// trial build.
    enum NextStep: Equatable {
        /// `--dry-run` was passed: nothing was written, regardless of
        /// anything else this run found.
        case previewOnly
        /// A human still has to resolve an ambiguous scheme or fill in a
        /// test target by hand. Matches `init`'s own existing behavior for
        /// the identical scenario — it still writes the file and still
        /// exits 0 — so `setup` does not newly fail a case plain `init`
        /// would not have failed either.
        case needsManualCompletion(details: [String])
        /// The written config is unambiguous, but `doctor`'s own checks
        /// found a real failure (e.g. the project does not build). Matches
        /// `doctor`'s own exit-non-zero behavior for the identical scenario.
        case environmentNotReady
        case ready
    }

    static func nextStep(dryRun: Bool, hasTestTargets: Bool, schemeAmbiguous: Bool, environmentReady: Bool) -> NextStep {
        if dryRun { return .previewOnly }

        var unresolved: [String] = []
        if schemeAmbiguous { unresolved.append("the ambiguous Xcode scheme") }
        if !hasTestTargets { unresolved.append("the missing test target(s)") }
        guard unresolved.isEmpty else { return .needsManualCompletion(details: unresolved) }

        return environmentReady ? .ready : .environmentNotReady
    }

    static func message(for step: NextStep, configPath: String) -> String {
        switch step {
        case .previewOnly:
            "This was a preview — nothing was written. Re-run without --dry-run to write \(configPath)."
        case let .needsManualCompletion(details):
            "Resolve \(details.joined(separator: " and ")) in \(configPath), then run `mutantkit doctor` to confirm."
        case .environmentNotReady:
            "Not ready. Fix the failures above, then run `mutantkit setup` (or `mutantkit doctor`) again."
        case .ready:
            "Ready. Next: `mutantkit dry-run` to verify the baseline builds and tests once, then `mutantkit plan` "
                + "and `mutantkit run --fail-on-survivors` for a CI-meaningful run."
        }
    }
}
