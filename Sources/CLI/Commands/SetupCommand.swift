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
        anything — and to run readiness against that exact preview, so a failure means the \
        previewed config would not be ready, not that something already on disk isn't. Exits \
        non-zero in that case. Safe to run repeatedly, including from an agent deciding whether \
        to proceed.
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
        // Wherever `--config` names is where `setup` writes, same as every
        // other command that accepts it treats it as "the config this
        // invocation is about" — not just where readiness happens to read
        // from while a hardcoded `<root>/mutantkit.yml` gets written
        // instead.
        let destination = common.configPath.map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(ConfigurationLoader.fileName)
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

        // Same checks `doctor` runs, against the *exact* `Configuration` this
        // run just wrote, or — in --dry-run — the exact one it would write:
        // parsed from `plan.template` directly, never re-read from
        // `destination` on disk. Re-reading the path would answer "is
        // whatever's already there ready", which in --dry-run is a
        // completely different question from "would writing this preview
        // leave the project ready" — the one thing a preview exists to
        // answer. This is what actually proves the golden path end to end: a
        // freshly-detected config that also passes the real
        // toolchain/build/host checks, not just one that looks plausible.
        print("\nChecking readiness…\n")
        let configuration = try ConfigurationLoader.parse(plan.template)
        let readiness = await ReadinessCheck.run(root: root, configuration: configuration, skipBuild: skipBuild)
        print(ReadinessCheck.render(readiness.diagnosis))

        let step = Self.nextStep(
            dryRun: dryRun,
            hasTestTargets: plan.hasTestTargets,
            schemeAmbiguous: plan.schemeAmbiguous,
            environmentReady: readiness.diagnosis.canProceed
        )
        print("\n\(Self.message(for: step, configPath: destination.path, configFlag: common.configPath))")

        switch step {
        case .environmentNotReady, .previewNotReady, .previewNeedsManualCompletion:
            throw ExitCode(MutantKitExit.operationalError)
        case .previewOnly, .needsManualCompletion, .ready:
            break
        }
    }

    /// What `setup` should tell the user to do next. Pure decision logic,
    /// factored out of `run()` so every combination of outcome can be unit
    /// tested directly, without running real detection, `xcodebuild`, or a
    /// trial build.
    enum NextStep: Equatable {
        /// `--dry-run` was passed and the previewed config — the exact one
        /// that would be written — already passes readiness, with no
        /// unresolved scheme or test-target ambiguity either.
        case previewOnly
        /// `--dry-run` was passed, nothing was written, and the previewed
        /// config would *not* pass readiness. Distinct from `.previewOnly`:
        /// an agent deciding whether to run `setup` for real needs to see a
        /// genuine would-fail diagnosis here, not a blanket "preview done"
        /// that reads the same whether the previewed config works or not.
        case previewNotReady
        /// `--dry-run` was passed and the previewed config has an unresolved
        /// ambiguous scheme or missing test target(s) — regardless of what
        /// the readiness diagnosis of that same preview says. These two can
        /// disagree: an ambiguous scheme or an empty `tests.targets` does
        /// not reliably show up as a `doctor`-style failure on its own (an
        /// adapter can still resolve *a* scheme/target and report ready),
        /// so treating `environmentReady` as the only signal let a preview
        /// with a genuinely unresolved choice report `.previewOnly` —
        /// implying "safe to write and proceed" — which is exactly the
        /// guess `setup` documents itself as never making.
        ///
        /// Deliberately distinct from `.needsManualCompletion` (the
        /// non-dry-run case) in more than name: this exits non-zero, that
        /// does not. `.needsManualCompletion` still exits 0 because it
        /// mirrors `init`'s own established contract — a file was actually
        /// written, so leaving the user a starting point outweighs failing
        /// the command outright. A dry-run preview writes nothing, so that
        /// tradeoff does not apply: the only thing `--dry-run`'s exit code
        /// exists to answer is "would committing this leave the project
        /// ready", and an unresolved scheme/test-target choice means the
        /// honest answer is no — an agent deciding whether to proceed from
        /// dry-run's exit code alone must not be told this is fine.
        case previewNeedsManualCompletion(details: [String])
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
        // Computed unconditionally, dry-run or not: an unresolved scheme or
        // missing test target(s) is a fact about the previewed/written
        // config itself, independent of whatever `environmentReady` (a
        // `doctor`-style diagnosis of the same config) happens to say — the
        // two can disagree, and unresolved detection must win either way
        // (mirrors the non-dry-run path's own "unresolved detection
        // outranks a failed readiness check" rule below).
        var unresolved: [String] = []
        if schemeAmbiguous { unresolved.append("the ambiguous Xcode scheme") }
        if !hasTestTargets { unresolved.append("the missing test target(s)") }

        if dryRun {
            guard unresolved.isEmpty else { return .previewNeedsManualCompletion(details: unresolved) }
            return environmentReady ? .previewOnly : .previewNotReady
        }

        guard unresolved.isEmpty else { return .needsManualCompletion(details: unresolved) }
        return environmentReady ? .ready : .environmentNotReady
    }

    /// - Parameter configFlag: the raw `--config` value this `setup`
    ///   invocation was given, if any (`common.configPath`, not the resolved
    ///   destination path). Appended to every suggested command below so a
    ///   custom `--config` actually survives into the *next* command an
    ///   agent or user is told to run — `mutantkit dry-run`/`plan`/`doctor`
    ///   all default to `<projectRoot>/mutantkit.yml` when `--config` is
    ///   omitted, so a suggestion that dropped it would send a custom
    ///   `setup --config foo.yml` straight into a next command that looks at
    ///   the wrong file.
    static func message(for step: NextStep, configPath: String, configFlag: String? = nil) -> String {
        let suffix = configFlag.map { " --config \($0)" } ?? ""
        return switch step {
        case .previewOnly:
            "This was a preview — nothing was written. Re-run without --dry-run\(suffix) to write \(configPath)."
        case .previewNotReady:
            "This was a preview — nothing was written, and the previewed \(configPath) would not be ready. "
                + "Fix the failures above, then re-run --dry-run\(suffix) to confirm before writing for real."
        case let .previewNeedsManualCompletion(details):
            "This was a preview — nothing was written, and \(details.joined(separator: " and ")) would still be "
                + "unresolved in \(configPath). Resolve \(details.count > 1 ? "them" : "it") by hand, then re-run "
                + "--dry-run\(suffix) to confirm before writing for real."
        case let .needsManualCompletion(details):
            "Resolve \(details.joined(separator: " and ")) in \(configPath), then run `mutantkit doctor\(suffix)` to confirm."
        case .environmentNotReady:
            "Not ready. Fix the failures above, then run `mutantkit setup\(suffix)` (or `mutantkit doctor\(suffix)`) again."
        case .ready:
            "Ready. Next: `mutantkit dry-run\(suffix)` to verify the baseline builds and tests once, then `mutantkit plan\(suffix)` "
                + "and `mutantkit run --fail-on-survivors\(suffix)` for a CI-meaningful run."
        }
    }
}
