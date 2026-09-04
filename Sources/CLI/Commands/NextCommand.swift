import ArgumentParser
import Foundation
import MutationModel
import Reporting

/// Prints exactly one recommended-next survivor to fix, out of an already-
/// produced `report.json`.
///
/// `mutantkit survivors`/`mutantkit fix-plan` both deliberately leave "which
/// one first" to the reader. This command answers it, using
/// `NextFixRecommendation`'s real, explained ranking over
/// `TestObligationAnalyzer`'s own fix plan — see that type's own doc comment
/// for the five criteria, in priority order, and why each one is grounded in
/// data this tool already computed rather than a new heuristic.
struct NextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next",
        abstract: "Print the single recommended-next surviving/uncovered mutant to fix, with a real, explained ranking."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "A report to recommend from.")
    var report = ".mutantkit/report.json"

    @Flag(name: .long, help: "Emit the recommendation as JSON instead of the text summary below.")
    var json = false

    @Option(name: .long, help: "Output format: omit for text, or \"agent\" for a terser, LLM-oriented text format.")
    var format: String?

    func run() throws {
        guard format == nil || format == "agent" else {
            print("Unknown --format '\(format ?? "")'. Expected: agent (or omit --format for text).")
            throw ExitCode(MutantKitExit.operationalError)
        }

        let runReport = try decode(reportPath: report)
        let next = NextFixRecommendation.build(from: runReport)

        if json {
            try JSONOutput.emit(next)
            return
        }

        guard let entry = next.recommendation else {
            print("No surviving or uncovered mutants — nothing to recommend.")
            return
        }

        if format == "agent" {
            try printAgent(entry: entry, next: next)
        } else {
            printText(entry: entry, next: next)
        }
    }

    private func printText(entry: MutantFixPlanEntry, next: NextFixRecommendation) {
        let facts = entry.facts
        print("Next: \(facts.mutantID)  \(facts.operatorID)")
        print("  \(facts.displayLocation)  \(facts.declaration)")
        print("  Mutation: `\(facts.original)` → `\(facts.replacement.isEmpty ? "(removed)" : facts.replacement)`")
        print("  Outcome: \(facts.outcome.rawValue) — \(facts.diagnosis)")
        print("  Gap: \(entry.inference.gapKind.rawValue) (confidence: \(entry.inference.confidence.rawValue))")
        print("    \(entry.inference.rationale)")
        print("  Obligation: \(entry.obligation.description)")
        print("  Reproduce: \(entry.reproduceCommand)")

        let alternates = next.candidateCount - 1
        print("")
        if alternates > 0 {
            print("Ranked above \(alternates) other candidate(s). Ranking used, in priority order:")
        } else {
            print("Only candidate considered. Ranking used, in priority order (for context):")
        }
        for (index, criterion) in next.rankingCriteria.enumerated() {
            print("  \(index + 1). \(criterion)")
        }
    }

    /// Compact, LLM-oriented alternative to `--json`: a single NDJSON line
    /// (one JSON object) rather than the earlier unquoted `key=value` lines
    /// — see `FixPlanCommand.printAgent`'s own doc comment for why: a
    /// mutant's real `original`/`replacement` source text can itself contain
    /// a space, an `=`, or an embedded newline, any of which made that
    /// earlier format ambiguous (or, for a newline, actually split) to
    /// parse. `JSONOutput.compactLine(for:)` escapes all of that inside a
    /// single guaranteed-one-line JSON string.
    private func printAgent(entry: MutantFixPlanEntry, next: NextFixRecommendation) throws {
        let facts = entry.facts
        let line = AgentLine(
            id: facts.mutantID,
            operatorID: facts.operatorID,
            location: facts.displayLocation,
            declaration: facts.declaration,
            outcome: facts.outcome.rawValue,
            original: facts.original,
            replacement: facts.replacement,
            candidates: next.candidateCount,
            kind: entry.inference.gapKind.rawValue,
            confidence: entry.inference.confidence.rawValue,
            obligation: entry.obligation.description,
            reproduceCommand: entry.reproduceCommand
        )
        print(try JSONOutput.compactLine(for: line))
    }

    /// One `--format agent` line's full field set — see `printAgent`'s own
    /// doc comment for why this is NDJSON rather than delimited text.
    private struct AgentLine: Codable {
        let id: String
        let operatorID: String
        let location: String
        let declaration: String
        let outcome: String
        let original: String
        let replacement: String
        let candidates: Int
        let kind: String
        let confidence: String
        let obligation: String
        let reproduceCommand: String

        enum CodingKeys: String, CodingKey {
            case id, location, declaration, outcome, original, replacement, candidates, kind, confidence, obligation
            case operatorID = "operator"
            case reproduceCommand = "reproduce"
        }
    }

    /// Same shape as `TrustCommand`/`SurvivorsCommand`/`FixPlanCommand`'s
    /// own `decode(reportPath:)`.
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
