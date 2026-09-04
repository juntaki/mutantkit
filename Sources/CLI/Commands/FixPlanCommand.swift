import ArgumentParser
import Foundation
import MutationModel
import Reporting

/// Prints a real, per-survivor test-obligation fix plan for an already-
/// produced `report.json`: what each surviving/uncovered mutant's real
/// facts are, what kind of gap the evidence shows, the concrete distinction
/// a new test would need to make to kill it, and a working reproduce
/// command.
///
/// This is a NEW SUMMARY VIEW over data `mutantkit run` already computed,
/// like `TrustCommand`/`SurvivorsCommand` before it — every entry comes from
/// `TestObligationAnalyzer.buildFixPlan(from:)` reading `SurvivorActionabilityReport`
/// and `MutationResult`'s own real fields (operator ID, original/replacement
/// text, test summary, diagnosis). Nothing here re-runs a mutant, re-derives
/// coverage, or invents an obligation the operator's own mechanical
/// semantics do not actually support — see `TestObligationAnalyzer`'s own
/// doc comment for exactly which operators are modeled and how.
struct FixPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix-plan",
        abstract: "Print a concrete, per-survivor test-obligation fix plan: facts, inference, obligation, reproduce."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "A report to build the fix plan from.")
    var report = ".mutantkit/report.json"

    @Flag(name: .long, help: "Emit the full fix plan as JSON instead of the text summary below.")
    var json = false

    @Option(name: .long, help: "Output format: omit for text, or \"agent\" for a terser, LLM-oriented text format.")
    var format: String?

    func run() throws {
        guard format == nil || format == "agent" else {
            print("Unknown --format '\(format ?? "")'. Expected: agent (or omit --format for text).")
            throw ExitCode(MutantKitExit.operationalError)
        }

        let runReport = try decode(reportPath: report)
        let plan = TestObligationFixPlan.build(from: runReport)

        if json {
            try JSONOutput.emit(plan)
            return
        }

        guard !plan.entries.isEmpty else {
            print("No surviving or uncovered mutants.")
            return
        }

        if format == "agent" {
            try printAgent(plan)
        } else {
            printText(plan)
        }
    }

    private func printText(_ plan: TestObligationFixPlan) {
        print("Test obligation fix plan for \(plan.planID) — \(plan.entries.count) surviving/uncovered mutant(s)\n")

        for (index, entry) in plan.entries.enumerated() {
            let facts = entry.facts
            print("[\(index + 1)/\(plan.entries.count)] \(facts.mutantID)  \(facts.operatorID)")
            print("    \(facts.displayLocation)  \(facts.declaration)")
            print("    Mutation: `\(facts.original)` → `\(facts.replacement.isEmpty ? "(removed)" : facts.replacement)`")
            print("    Facts: outcome=\(facts.outcome.rawValue), \(testsSummaryText(facts)), \(scopeText(facts)), clusterSize=\(facts.clusterSize)")
            print("    Inference: \(entry.inference.gapKind.rawValue) (confidence: \(entry.inference.confidence.rawValue))")
            print("      \(entry.inference.rationale)")
            print("    Obligation: \(entry.obligation.description)")
            print("    Reproduce: \(entry.reproduceCommand)")
            print("")
        }
    }

    /// Compact, LLM-oriented alternative to `--json`: one JSON object per
    /// surviving/uncovered mutant, one per line (NDJSON) — not the full
    /// `--json` envelope's pretty-printed, multi-line shape, and not the
    /// unquoted `key=value` line format this used to be. That earlier format
    /// broke on its own delimiter: `original`/`replacement` are real Swift
    /// source text lifted verbatim from the mutated file, so either can
    /// itself contain a space (making `key=value value` ambiguous to split),
    /// an `=` (ambiguous which `=` is the separator), or even an embedded
    /// newline (a multi-line ternary/return-value swap, which would have
    /// split one logical entry across lines a naive line-oriented parser
    /// reads as two). `JSONOutput.compactLine(for:)` makes every field a
    /// properly escaped JSON string, so none of that is ambiguous by
    /// construction — a consumer can split this stream on `\n` and feed
    /// each line straight to a JSON parser. Deliberately smaller than the
    /// full `MutantFixPlanEntry` (omits `inference.rationale`, present in
    /// `--json` and in the full text format above) to stay genuinely terser
    /// rather than merely reformatted: `kind`/`confidence` alone already
    /// tell an agent how much to trust the obligation without restating the
    /// derivation.
    private func printAgent(_ plan: TestObligationFixPlan) throws {
        for entry in plan.entries {
            let facts = entry.facts
            let line = AgentLine(
                id: facts.mutantID,
                operatorID: facts.operatorID,
                location: facts.displayLocation,
                declaration: facts.declaration,
                outcome: facts.outcome.rawValue,
                original: facts.original,
                replacement: facts.replacement,
                testsRun: facts.testsRun,
                testsPassed: facts.testsPassed,
                scope: scopeValue(facts),
                clusterSize: facts.clusterSize,
                kind: entry.inference.gapKind.rawValue,
                confidence: entry.inference.confidence.rawValue,
                obligation: entry.obligation.description,
                reproduceCommand: entry.reproduceCommand
            )
            print(try JSONOutput.compactLine(for: line))
        }
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
        let testsRun: Int?
        let testsPassed: Int?
        let scope: String
        let clusterSize: Int
        let kind: String
        let confidence: String
        let obligation: String
        let reproduceCommand: String

        enum CodingKeys: String, CodingKey {
            case id, location, declaration, outcome, original, replacement, testsRun, testsPassed, scope, clusterSize
            case kind, confidence, obligation
            case operatorID = "operator"
            case reproduceCommand = "reproduce"
        }
    }

    private func testsSummaryText(_ facts: MutantFixPlanEntry.Facts) -> String {
        guard let run = facts.testsRun else { return "tests=unrecorded" }
        return "tests=\(facts.testsPassed ?? 0)/\(run) passed"
    }

    private func scopeText(_ facts: MutantFixPlanEntry.Facts) -> String {
        "scope=\(scopeValue(facts))"
    }

    /// The bare scope value, with no `scope=` label — for `AgentLine`, whose
    /// JSON key already says `scope`; `scopeText` above adds the label back
    /// on for the plain-text `Facts:` line, which has no key of its own.
    private func scopeValue(_ facts: MutantFixPlanEntry.Facts) -> String {
        guard let scope = facts.testScope else { return "n/a" }
        switch scope {
        case .fullSuite: return "fullSuite"
        case .unknown: return "unknown"
        case let .narrowed(tests): return "narrowed(\(tests.count))"
        }
    }

    /// Same shape as `TrustCommand`/`SurvivorsCommand`'s own
    /// `decode(reportPath:)`: a structured `--json` error instead of thrown
    /// prose when the report is missing or malformed, and the same
    /// operational-error exit code on the text path.
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
