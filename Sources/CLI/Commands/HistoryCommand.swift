import ArgumentParser
import Foundation
import MutationModel
import Reporting

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show mutation score and runtime history recorded by previous runs."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Maximum number of recent runs to show.")
    var limit = 20

    @Flag(name: .long, help: "Emit history as JSON instead of a text table.")
    var json = false

    func run() throws {
        let store = RunHistoryStore(
            root: common.resolvedProjectRoot.appendingPathComponent(".mutantkit/history")
        )
        let records = store.records(limit: max(0, limit))

        if json {
            try JSONOutput.emit(records)
            return
        }

        guard !records.isEmpty else {
            print("No mutation run history recorded yet.")
            return
        }

        let formatter = ISO8601DateFormatter()
        print("DATE                         TESTED   EFFECTIVE  KILLED  SURVIVED  NO-COV  RUNTIME  INTEGRITY")
        for record in records {
            let tested = record.testedScore.map { String(format: "%6.1f%%", $0 * 100) } ?? "   n/a "
            let effective = record.effectiveScore.map { String(format: "%6.1f%%", $0 * 100) } ?? "   n/a "
            let killed = record.killed.map { String($0) } ?? "-"
            let survived = record.survived.map { String($0) } ?? "-"
            let noCoverage = record.noCoverage.map { String($0) } ?? "-"
            let runtime = String(format: "%.0fs", record.wallClockSeconds)
            print("\(formatter.string(from: record.finishedAt))  \(tested)  \(effective)  \(killed)  \(survived)  \(noCoverage)  \(runtime)  \(record.integrityPassed ? "passed" : "FAILED")")
        }
    }
}
