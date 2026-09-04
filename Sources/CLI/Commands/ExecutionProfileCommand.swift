import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationModel

/// Shows what `execution.profile: optimized`/`experimental` would actually
/// do for *this* project, before anything runs — the "recommended profile"
/// report named in this feature's own design. Reads an already-written
/// `plan.json` (never plans one itself: planning belongs to `mutantkit
/// plan`) and the same adapter resolution `mutantkit run` uses, then prints
/// exactly the decisions `ExecutionProfileResolver` would make, so a
/// project that gets nothing from `optimized` can see *why*, not just that
/// nothing changed — and so this report can never promise something a real
/// `mutantkit run --config ...` with `execution.profile: optimized` would
/// not actually do: both read `ExecutionProfileResolver.decisions(for:
/// current:)`.
///
/// A dedicated command rather than output folded into `plan`: `plan`'s own
/// contract is unconditional and offline (it never needs a resolvable
/// build destination — a project with no booted simulator can still
/// produce a `plan.json`), and answering "what would preferSchemataExecution/
/// selectCoveringTests do here" needs a resolved `ProjectAdapter`, which
/// can fail to resolve (no destination available) for an Xcode/simulator
/// project. Keeping that failure mode in a new, explicitly opt-in command
/// means it can never turn a `plan.json` that used to write successfully
/// into one that suddenly cannot.
///
/// Never mutates `plan.json`, `mutantkit.yml`, or anything else on disk —
/// and, unlike an earlier revision, never creates or removes a scratch
/// directory either: `ExecutionProfileSupport.characteristics` no longer
/// probes the filesystem at all (see that function's own doc comment).
struct ExecutionProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "execution-profile",
        abstract: "Show what execution.profile: optimized would enable for this project, before running anything."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    @Option(name: .long, help: "The plan to evaluate.")
    var plan = "plan.json"

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)
        try ConfigurationPreflight.run(settings)

        let planURL = URL(fileURLWithPath: plan)
        guard FileManager.default.fileExists(atPath: planURL.path) else {
            print("No plan at \(planURL.path). Run `mutantkit plan` first.")
            throw ExitCode(MutantKitExit.operationalError)
        }
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: planURL))

        let resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
        print("Project: \(resolution.detection.kind.rawValue) — \(resolution.detection.reason)")

        let characteristics = await ExecutionProfileSupport.characteristics(plan: loadedPlan, resolution: resolution)

        print(Self.render(
            projectRoot: root, planPath: planURL.path, configuredProfile: settings.execution.profile,
            currentExecution: settings.execution, characteristics: characteristics
        ))
    }
}

extension ExecutionProfileCommand {
    /// Pulled out of `run()` so the report's exact text is directly
    /// testable without a toolchain, a plan, or a project on disk —
    /// `ExecutionProfileCommandRenderTests` hand-builds a
    /// `ProjectExecutionCharacteristics` the way `ExecutionProfileResolver`
    /// tests already do.
    static func render(
        projectRoot: URL,
        planPath: String,
        configuredProfile: ExecutionProfile,
        currentExecution: ExecutionSettings,
        characteristics: ProjectExecutionCharacteristics
    ) -> String {
        let decisions = ExecutionProfileResolver.decisions(for: characteristics, current: currentExecution)
        let optimized = ExecutionProfileResolver.resolve(profile: .optimized, current: currentExecution, characteristics: characteristics)
        let changes = fieldChanges(from: currentExecution, to: optimized)

        var lines: [String] = []
        lines.append("")
        lines.append("Execution profile report — \(projectRoot.path)")
        lines.append("Plan: \(planPath) (\(characteristics.totalMutationCount) planned mutation(s))")
        lines.append("Configured: execution.profile: \(configuredProfile.rawValue)")
        lines.append("")
        lines.append("What `optimized` would enable here:")
        for decision in decisions {
            let mark = decision.eligible ? "[enable]" : "[skip]  "
            lines.append("  \(mark) \(decision.feature.rawValue)")
            lines.append("           \(decision.rationale)")
        }
        lines.append("")

        if changes.isEmpty {
            lines.append(
                configuredProfile == .optimized || configuredProfile == .experimental
                    ? "Already resolved: nothing about the currently-configured execution settings would change."
                    : "Switching to `execution.profile: optimized` would change nothing for this project right now — none "
                    + "of the above is eligible here, or every eligible field is already set."
            )
        } else {
            lines.append("Concretely, `execution.profile: optimized` would change:")
            for change in changes { lines.append("  \(change)") }
        }
        lines.append("")

        // Real, computed number — never a guess: exactly how many of the
        // plan's own mutations use an operator this build's schemata
        // backend has a registered lowerer for (see
        // `ProjectExecutionCharacteristics.schemataEligibleMutationCount`'s
        // own doc comment for the precise, honest meaning: a necessary
        // condition for embedding, not the finer per-candidate fraction
        // `SchemataChunkPlanner.plan` itself would compute — that finer
        // number needs real target resolution and is not attempted by this
        // lightweight, side-effect-free report).
        if characteristics.totalMutationCount > 0 {
            let percent = 100.0 * Double(characteristics.schemataEligibleMutationCount) / Double(characteristics.totalMutationCount)
            lines.append(
                "Schemata-eligible (operator-level): \(characteristics.schemataEligibleMutationCount)/" +
                    "\(characteristics.totalMutationCount) (\(String(format: "%.0f", percent))%) — a necessary, not " +
                    "sufficient, condition for embedding; the exact embedded/chunk count depends on real target " +
                    "resolution this report does not attempt."
            )
        }

        // Not one of the `[enable]`/`[skip]` decisions above: `optimized`/
        // `experimental` never touch `sharedModuleCache` (see
        // `ExecutionProfile`'s own doc comment for why — the same "named,
        // unresolved risk" basis `incrementalBuild` is already excluded
        // on), so this is purely informational, for a project deciding
        // whether the manual `execution.sharedModuleCache: true` opt-in is
        // worth reading that setting's own doc comment for.
        lines.append(
            "Shared module cache (manual opt-in only — never enabled by optimized/experimental): " + (
                characteristics.sharedModuleCacheSupported
                    ? "this project's build shape supports it (SwiftPackageMacOSAdapter). " +
                    "Research/isolated-build-reuse-2026-09 measured 7.5s real / 3.9s user vs. 24.4s real / 13.4s " +
                    "user cold on its own small fixture (not re-measured for this project — the saving scales " +
                    "with how much Foundation/XCTest/SwiftShims compilation this project's own build pays for). " +
                    "Before setting execution.sharedModuleCache: true, read its own doc comment's warning against " +
                    "CI setups that run multiple concurrent destinations against this same project/scratch root."
                    : "not supported here — requires SwiftPackageMacOSAdapter (never an Xcode/simulator project)."
            )
        )
        lines.append(
            "Per-test coverage selection: test-launch-count reduction is not estimated here — it depends on " +
                "actual per-test coverage attribution, which only a real baseline run produces; this report never " +
                "fabricates that number."
        )
        lines.append("")
        lines.append(
            "`experimental` resolves identically to `optimized` today. The one real candidate looked at for its " +
                "own bucket — mixing \"safe\" mutants into shared builds — has a real, found soundness " +
                "counterexample (Research/safe-mutant-mixing-2026-09/DESIGN.md) and is deliberately not wired in " +
                "here under any profile."
        )
        return lines.joined(separator: "\n")
    }

    /// `sharedModuleCache` is deliberately absent: `ExecutionProfileResolver
    /// .resolve` never touches it (see `ExecutionProfile`'s own doc
    /// comment), so `before`/`after` can never differ on that field and a
    /// comparison here would be permanently-dead code.
    private static func fieldChanges(from before: ExecutionSettings, to after: ExecutionSettings) -> [String] {
        var changes: [String] = []
        if before.strategy != after.strategy {
            changes.append("execution.strategy: \(before.strategy.rawValue) → \(after.strategy.rawValue)")
        }
        if before.selectCoveringTests != after.selectCoveringTests {
            changes.append("execution.selectCoveringTests: \(before.selectCoveringTests) → \(after.selectCoveringTests)")
        }
        if before.measureCoverage != after.measureCoverage {
            changes.append("execution.measureCoverage: \(before.measureCoverage) → \(after.measureCoverage)")
        }
        return changes
    }
}
