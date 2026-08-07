import ArgumentParser
import Foundation
import MutationModel
import Reporting

struct PerfCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "perf",
        abstract: "Summarize mutation-run performance from a JSON report."
    )

    @Option(name: .long, help: "Path to a MutantKit JSON report.")
    var report = ".mutantkit/report.json"

    @Option(name: .long, help: "Optional path for machine-readable performance JSON.")
    var output: String?

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: report))
        let runReport = try MutationPlan.decoder().decode(RunReport.self, from: data)
        print(try PerformanceReporter().render(runReport))

        if let output {
            let encoded = try MutationPlan.encoder().encode(PerformanceSummary(report: runReport))
            try encoded.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
