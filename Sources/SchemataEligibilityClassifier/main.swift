import ArgumentParser
import Foundation
import MutationPlanner

/// Research-only, outcome-blind classification tool for
/// `Research/adr-0008-validation/protocol.md`'s Protocol v3 addendum
/// (Corpus B calibration population selection rule) — see
/// `EligibilityClassification.swift` for what "outcome-blind" and the
/// `lowererEligible`/`plannerEmbedded` split actually mean. This file is
/// only the CLI wrapper; all classification logic lives there so a test
/// target can call it directly.
///
/// A plain, synchronous `ParsableCommand` — not `AsyncParsableCommand` —
/// deliberately: this package's other `main.swift`-based executables
/// (`PlanSubsetDerivation`, `BudgetV2Eval`) are synchronous, and
/// `AsyncParsableCommand`'s `main()`/`main(_:)` entry points proved
/// ambiguous to invoke correctly from a `main.swift` top-level statement
/// in practice (overload resolution silently picked `ParsableCommand`'s
/// own synchronous `main()`, which ArgumentParser's own `#if DEBUG` guard
/// then rejected at runtime; working around that by hand-rolling
/// `asyncParseAsRoot()` + a downcast instead ran the protocol's *default*
/// `run()` — "print the help screen" — rather than this type's override).
/// `blocking(_:)` below bridges the one genuinely async call
/// (`SwiftPMTargetResolver.resolveTargetInfo`, transitively inside
/// `EligibilityClassifier.classify`) back to this file's synchronous
/// `run()`, avoiding the whole async-root-command class of issue.
///
/// Not `@main`: this file is `main.swift`.
struct SchemataEligibilityClassifierCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schemata-eligibility-classifier",
        abstract: "Classify each candidate in a plan by actual SchemataChunkPlanner embedded membership, with zero test execution."
    )

    @Option(help: "Path to the plan.json to classify.")
    var plan: String

    @Option(help: "Project root the plan's file paths are relative to.")
    var projectRoot: String

    @Option(help: "Operator ID to classify, e.g. swift.core.arithmetic-operator-replacement.")
    var operatorID: String

    @Option(help: "Where to write the classification JSON.")
    var output: String

    func run() throws {
        let planURL = URL(fileURLWithPath: plan)
        let planData = try Data(contentsOf: planURL)
        let registry = try SchemataLowererRegistry()

        let result = try blocking {
            try await EligibilityClassifier.classify(
                planData: planData, planPath: plan, projectRoot: URL(fileURLWithPath: projectRoot),
                operatorID: operatorID, registry: registry
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: output))

        print("Classified \(result.totalCandidates) \(operatorID) candidates:")
        print("  lowererEligible: \(result.lowererEligibleCount)")
        print("  plannerEmbedded: \(result.plannerEmbeddedCount)  <- authoritative for calibration population")
    }
}

SchemataEligibilityClassifierCLI.main()
