import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Discover mutations and write a Mutation Plan.",
        discussion: """
        Planning never writes to your source. It produces a JSON plan that is the \
        single source of truth for everything downstream — running, sharding, \
        resuming and reproducing all read it and nothing else.
        """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    @Option(name: [.customLong("output"), .customShort("o")], help: "Where to write the plan.")
    var output = "plan.json"

    @Option(name: .long, help: "Only mutate code changed against this git ref, e.g. origin/main.")
    var diffBase: String?

    @Option(name: .long, help: "Alias for --diff-base, matching incremental mutation-testing terminology.")
    var since: String?

    @Option(name: .long, help: "Mutation suppression file. Defaults to .mutantkitignore when that file exists.")
    var ignoreFile: String?

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        try Self.validateDiffBaseAndSince(diffBase: diffBase, since: since)
        if let base = diffBase ?? since {
            settings.execution.diffBase = base
        }

        // Gathered here because the planner runs no subprocesses — keeping it
        // pure is what makes plans testable without a toolchain.
        let toolchain = await ToolchainProbe.fingerprint(workingDirectory: root)

        var scope: DiffScope?
        if let base = settings.execution.diffBase {
            scope = try await GitDiff.changedLines(since: base, in: root)
            print("Diff scope against \(base): \(scope?.changedFiles.count ?? 0) changed file(s)")
        }

        let discoveredPlan = try await MutationPlanner().makePlan(
            configuration: settings,
            projectRoot: root,
            toolchain: toolchain,
            diffScope: scope
        )

        let defaultIgnore = root.appendingPathComponent(".mutantkitignore")
        let suppressionURL: URL? = if let ignoreFile {
            URL(fileURLWithPath: ignoreFile, relativeTo: root).standardizedFileURL
        } else if FileManager.default.fileExists(atPath: defaultIgnore.path) {
            defaultIgnore
        } else {
            nil
        }

        var suppressionRules: [MutationSuppressionRule] = []
        if let suppressionURL {
            let contents = try String(contentsOf: suppressionURL, encoding: .utf8)
            suppressionRules += try MutationSuppressionSet.parse(contents).rules
        }

        // Only files that actually produced a candidate need scanning — an
        // inline `mutantkit:disable` comment anywhere else has nothing to
        // suppress and would just cost a read for no effect.
        for file in Set(discoveredPlan.mutations.map(\.file)).sorted() {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            suppressionRules += InlineMutationSuppressionScanner.scan(source: source, file: file)
        }

        let plan: MutationPlan
        if !suppressionRules.isEmpty {
            let suppressions = MutationSuppressionSet(rules: suppressionRules)
            plan = suppressions.applying(to: discoveredPlan)
            let suppressed = plan.skipped.count - discoveredPlan.skipped.count
            print("Mutation suppressions: \(suppressed) mutation(s) skipped "
                + "(\(suppressionURL.map { "\($0.path), " } ?? "")inline source comments)")
        } else {
            plan = discoveredPlan
        }

        let url = URL(fileURLWithPath: output)
        let encoded = try plan.encoded()
        try encoded.write(to: url, options: .atomic)

        print("""

        Plan \(plan.planID)
          discovered: \(plan.discoveredCount)
          planned:    \(plan.mutations.count)
          skipped:    \(plan.skipped.count)
          operators:  \(plan.operators.map(\.id).joined(separator: ", "))
          files:      \(plan.sourceFileHashes.count)

        Wrote \(url.path)
        Next: `mutantkit run --plan \(output)`
        """)

        if !plan.skipped.isEmpty {
            let summary = SkipReasonCount.tally(plan.skipped)
                .map { "\($0.reason.rawValue): \($0.count)" }
                .joined(separator: ", ")
            print("\nSkipped breakdown — \(summary)")
        }

        // Only budget sampling narrows an eligible pool per operator, so this
        // is silent when nothing was budget-dropped — an unbudgeted plan (or
        // one small enough that every eligible mutant was kept) has nothing
        // here worth printing.
        let operatorBudget = OperatorBudgetSummary.tally(mutations: plan.mutations, skipped: plan.skipped)
        if operatorBudget.contains(where: { $0.budgetDropped > 0 }) {
            print("\nBudget selection by operator:")
            for entry in operatorBudget {
                print("  \(entry.operatorID): eligible \(entry.eligible), selected \(entry.selected), " +
                    "budgetDropped \(entry.budgetDropped)")
            }
        }
    }

    /// Pulled out of `run()` so this bad-input check is directly testable —
    /// mirroring how `RunCommand` pulls out its own validation/history
    /// helpers for the same reason. Bad input, not a usage-syntax error:
    /// every other bad-input case in this command already throws
    /// `MutantKitExit.operationalError` explicitly rather than
    /// `ArgumentParser`'s own `ValidationError` (exit 64), and this one
    /// should be no different (see `MutantKitExit`'s own exit-code
    /// contract).
    static func validateDiffBaseAndSince(diffBase: String?, since: String?) throws {
        if diffBase != nil, since != nil, diffBase != since {
            print("Pass either --diff-base or --since, not two different refs.")
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
