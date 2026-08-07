import ArgumentParser
import Foundation
import MutationModel

/// Applies CI quality thresholds to an already-finished report.
/// Keeping the gate separate from `run` lets CI change policy without
/// invalidating or re-running an expensive mutation campaign.
struct GateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate",
        abstract: "Fail CI when a trusted mutation report misses configured thresholds."
    )

    @Option(name: .long, help: "Path to a MutantKit JSON report.")
    var report = ".mutantkit/report.json"

    @Option(name: .long, help: "Minimum Tested Mutation Score as a percent, e.g. 80.")
    var minimumTested: Double?

    @Option(name: .long, help: "Minimum Effective Mutation Score as a percent, e.g. 60.")
    var minimumEffective: Double?

    @Option(name: .long, help: "Maximum allowed surviving mutants.")
    var maximumSurvivors: Int?

    func run() throws {
        let url = URL(fileURLWithPath: report)
        let data = try Data(contentsOf: url)
        let runReport = try MutationPlan.decoder().decode(RunReport.self, from: data)

        let thresholds = QualityGateThresholds(
            minimumTested: minimumTested.map { $0 / 100 },
            minimumEffective: minimumEffective.map { $0 / 100 },
            maximumSurvivors: maximumSurvivors
        )
        let result = QualityGate.evaluate(report: runReport, thresholds: thresholds)

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
}
