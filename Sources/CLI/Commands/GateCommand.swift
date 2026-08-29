import ArgumentParser
import Foundation
import MutationModel

/// Applies CI quality thresholds to an already-finished report.
/// Keeping the gate separate from `run` lets CI change policy without
/// invalidating or re-running an expensive mutation campaign.
///
/// Thresholds come from two places, merged with CLI flags winning: the
/// `qualityGate` section of `mutantkit.yml` (if a config file is found —
/// `gate` works with no config at all, CLI-only, unlike `plan`/`run`) and
/// the flags below. `--baseline` unlocks the two regression checks
/// (`regression.maximumDrop`, `survived.newMaximum`), which answer "did
/// this PR make things worse," not just "is the absolute number good
/// enough" — the question that actually blocks a merge day to day.
struct GateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate",
        abstract: "Fail CI when a trusted mutation report misses configured thresholds."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Path to a MutantKit JSON report.")
    var report = ".mutantkit/report.json"

    @Option(name: .long, help: "Path to a prior MutantKit JSON report to compare against for regression checks.")
    var baseline: String?

    @Option(name: .long, help: "Minimum Tested Mutation Score as a percent, e.g. 80.")
    var minimumTested: Double?

    @Option(name: .long, help: "Minimum Effective Mutation Score as a percent, e.g. 60.")
    var minimumEffective: Double?

    @Option(name: .long, help: "Maximum allowed surviving mutants.")
    var maximumSurvivors: Int?

    @Option(name: .long, help: "Fail if a score drops by more than this many percentage points versus --baseline.")
    var regressionMaximumDrop: Double?

    @Option(name: .long, help: "Fail if more than this many mutants survive now but not in --baseline.")
    var newSurvivorsMaximum: Int?

    func run() throws {
        let runReport = try decode(reportPath: report)
        let baselineReport = try baseline.map { try decode(reportPath: $0) }

        var thresholds = try loadConfiguredThresholds()
        if let minimumTested { thresholds.minimumTested = minimumTested / 100 }
        if let minimumEffective { thresholds.minimumEffective = minimumEffective / 100 }
        if let maximumSurvivors { thresholds.maximumSurvivors = maximumSurvivors }
        if let regressionMaximumDrop { thresholds.regressionMaximumDrop = regressionMaximumDrop / 100 }
        if let newSurvivorsMaximum { thresholds.newSurvivorsMaximum = newSurvivorsMaximum }

        let result = QualityGate.evaluate(report: runReport, thresholds: thresholds, baseline: baselineReport)

        if result.passed {
            print("Mutation quality gate passed.")
            return
        }

        print("Mutation quality gate failed:")
        for violation in result.violations {
            print("  - \(violation.detail)")
        }
        throw ExitCode(MutantKitExit.qualityGateFailure)
    }

    private func decode(reportPath: String) throws -> RunReport {
        try MutantKitExit.onFailure {
            let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
            return try MutationPlan.decoder().decode(RunReport.self, from: data)
        }
    }

    /// `gate` tolerates having no `mutantkit.yml` at all (CLI flags alone are
    /// enough to run it standalone against a report), but if a config file
    /// *is* found, its `qualityGate` section is the base that CLI flags
    /// then override.
    private func loadConfiguredThresholds() throws -> QualityGateThresholds {
        guard let url = try? ConfigurationLoader.locate(
            explicitPath: common.configPath, projectRoot: common.resolvedProjectRoot
        ) else {
            return QualityGateThresholds()
        }
        let configuration = try ConfigurationLoader.load(
            explicitPath: url.path, projectRoot: common.resolvedProjectRoot
        )
        return try configuration.qualityGate.resolvedThresholds()
    }
}
