import Foundation
import MutationModel

enum CorpusLoadError: Error, CustomStringConvertible {
    case decode(String)

    var description: String {
        switch self {
        case let .decode(detail): "Failed to load corpus data: \(detail)"
        }
    }
}

/// The full discovered pool for one corpus (protocol §5.2): every mutant an
/// unbudgeted `mutantkit plan` found, joined with `mutantkit run`'s real
/// outcomes where available. Keeps real `MutationPoint` values (not a
/// flattened projection) because `BudgetSelectorV2.allocate` requires them
/// directly for the screen's synthetic allocations.
struct Corpus {
    let points: [MutationPoint]
    let outcomes: [MutationID: MutationOutcome]
    let failingTests: [MutationID: [String]]

    var discoveredCount: Int { points.count }
    var distinctOperatorCount: Int { Set(points.map(\.operatorID)).count }

    static func load(planPath: String, reportPath: String?) throws -> Corpus {
        let plan: MutationPlan
        do {
            plan = try MutationPlan.decode(from: try Data(contentsOf: URL(fileURLWithPath: planPath)))
        } catch {
            throw CorpusLoadError.decode("loading plan at \(planPath): \(error)")
        }

        var outcomes: [MutationID: MutationOutcome] = [:]
        var failingTests: [MutationID: [String]] = [:]
        if let reportPath {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report: RunReport
            do {
                report = try decoder.decode(RunReport.self, from: try Data(contentsOf: URL(fileURLWithPath: reportPath)))
            } catch {
                throw CorpusLoadError.decode("loading report at \(reportPath): \(error)")
            }
            for result in report.results {
                outcomes[result.id] = result.outcome
                failingTests[result.id] = result.testSummary?.failingTests ?? []
            }
        }

        return Corpus(points: plan.mutations, outcomes: outcomes, failingTests: failingTests)
    }

    /// The inner stratification key, matching
    /// `MutationPlanner.budgetV2SubtypeKey` exactly.
    static func subtypeKey(_ point: MutationPoint) -> String {
        "\(point.originalText)\u{1F}\(point.replacementText)"
    }

    /// `file` + declaration path, so two same-named declarations in
    /// different files are never conflated (protocol §3.2).
    static func declarationKey(_ point: MutationPoint) -> String {
        "\(point.file)#\(point.enclosingDeclaration.description)"
    }
}
