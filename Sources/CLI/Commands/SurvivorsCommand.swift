import ArgumentParser
import Foundation
import MutationModel
import Reporting

/// The aggregate view over survivors `InspectCommand` never tried to
/// be — that command is deliberately about one mutant; this one is about
/// "what should I actually go fix," grouped by declaration and collapsed to
/// one entry per distinct root cause. See `SurvivorActionabilityReport`'s
/// own doc comment for the full design.
struct SurvivorsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "survivors",
        abstract: "Group surviving and uncovered mutants by declaration, collapsed to one entry per root cause."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "A report to read survivors from.")
    var report = ".mutantkit/report.json"

    @Flag(name: .long, help: "Emit the grouped record as JSON instead of the text summary below.")
    var json = false

    func run() throws {
        let runReport = try decode(reportPath: report)
        let actionability = SurvivorActionabilityReport.build(from: runReport)

        if json {
            try JSONOutput.emit(actionability)
            return
        }

        guard !actionability.groups.isEmpty else {
            print("No surviving or uncovered mutants.")
            return
        }

        let totalClusters = actionability.groups.reduce(0) { $0 + $1.clusters.count }
        let totalMutants = actionability.groups.reduce(0) { $0 + $1.clusters.reduce(0) { $0 + $1.members.count } }
        print("\(totalMutants) surviving/uncovered mutant(s), \(totalClusters) distinct issue(s), \(actionability.groups.count) declaration(s)\n")

        for group in actionability.groups {
            print("\(group.file) — \(group.declaration)")
            for cluster in group.clusters {
                printCluster(cluster)
            }
            print("")
        }
    }

    private func printCluster(_ cluster: SurvivorActionabilityReport.IssueCluster) {
        let members = cluster.members
        let countLabel = members.count == 1 ? "1 mutant" : "\(members.count) mutants"
        switch cluster.reason {
        case .mutationSiteNotCovered:
            print("  [\(countLabel), \(cluster.operatorIDs.joined(separator: ", "))] NOT COVERED — no test executed this mutation site.")
            print("    Fix: add or extend a test that reaches this exact path.")
        case let .coveredButNotCaught(testScope):
            print("  [\(countLabel), \(cluster.operatorIDs.joined(separator: ", "))] covered but not caught.")
            switch testScope {
            case .unknown:
                print("    Fix: strengthen the assertions in whichever test(s) reached this — the run's own evidence")
                print("    does not record which tests ran in this mutant's deciding attempt.")
            case .fullSuite:
                print("    Fix: strengthen the suite's own assertions — the full configured suite ran and still missed this.")
            case let .narrowed(tests):
                print("    Fix: strengthen the assertions in (tests known to have run, not necessarily")
                print("    all of which cover this exact line):")
                for test in tests.prefix(5) {
                    print("      - \(test)")
                }
                if tests.count > 5 {
                    print("      ...and \(tests.count - 5) more")
                }
            }
        }
        for member in members.prefix(3) {
            print("    e.g. \(member.file):\(member.line)  \(member.original) → \(member.replacement.isEmpty ? "(removed)" : member.replacement)")
        }
        if members.count > 3 {
            print("    ...and \(members.count - 3) more mutant(s) in this cluster")
        }
        let reproduceCommands = cluster.reproduceCommands
        if reproduceCommands.count == 1 {
            print("    \(reproduceCommands[0])")
        } else {
            print("    \(reproduceCommands.count) mutants clustered — reproduce any of:")
            for command in reproduceCommands.prefix(3) {
                print("      \(command)")
            }
            if reproduceCommands.count > 3 {
                print("      ...and \(reproduceCommands.count - 3) more")
            }
        }
    }

    /// Same shape as `GateCommand`'s own `decode(reportPath:role:)`: a
    /// structured `--json` error instead of thrown prose when the report is
    /// missing or malformed, and the same operational-error exit code on
    /// the text path.
    private func decode(reportPath: String) throws -> RunReport {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
            return try MutationPlan.decoder().decode(RunReport.self, from: data)
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            let code = error is DecodingError ? "reportMalformed" : "reportUnreadable"
            try JSONOutput.emitError(
                code: code,
                message: "Could not read the report at \"\(reportPath)\" as a MutantKit JSON report: \(error)",
                remedy: "Check --report points at a real report.json written by `mutantkit run`."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
