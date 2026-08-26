import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner

/// Implements `Research/budget-selection-v2/evaluation-protocol.md`
/// (revision 6, independently reviewed GO) §4–§6: budget/seed derivation,
/// the proxy-dependence screen, cross-corpus/cross-metric eligibility
/// aggregation, and the final acceptance rule. All real discovery/execution
/// is done by the existing `mutantkit` CLI (`plan`/`run`) — this tool only
/// post-processes the resulting `plan.json`/`report.json` files.
@main
struct BudgetV2EvalCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget-v2-eval",
        subcommands: [Budget.self, ScreenCommand.self, Aggregate.self, Compare.self, Select.self]
    )
}

struct Select: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: """
        Materializes v1's and v2's real, production-default selections (protocol §6 step 5) as \
        standalone plan.json subsets of an allocation-universe plan, via PlanSharding.subset — \
        pure post-processing over already-computed selector output, no new mutation execution.
        Feed the resulting plans, alongside the corpus's already-collected outcome report, to \
        `compare`.
        """
    )

    @Argument(help: "Path to the corpus's allocation-universe plan.json (the full discovered pool -- unbudgeted).")
    var planPath: String

    @Option(help: "This corpus's §4-derived seed.")
    var seed: UInt64

    @Option(help: "This corpus's §4-derived maxMutants.")
    var budget: Int

    @Option(help: "Where to write v1's selected plan.json (BudgetSelector.selectByOperatorSubtype, minimumPerOperator: 1).")
    var outputV1Plan: String

    @Option(help: "Where to write v2's selected plan.json (BudgetSelectorV2.allocate at production defaults -- S_default).")
    var outputV2Plan: String

    func run() throws {
        let corpus = try Corpus.load(planPath: planPath, reportPath: nil)
        let plan = try MutationPlan.decode(from: try Data(contentsOf: URL(fileURLWithPath: planPath)))

        // v1 baseline (protocol §1): stratifyBy: operatorSubtype, minimumPerOperator: 1.
        let v1Selection = BudgetSelector.selectByOperatorSubtype(
            corpus.points, limit: budget, seed: seed, minimumPerOperator: 1
        ).selected

        // v2 S_default (protocol §5.3/§6 step 5): production defaults, weight
        // unset at both levels -- the exact same computation `screen` performs
        // internally for S_default, materialized here as a standalone plan.
        var byOperator: [String: [MutationPoint]] = [:]
        for point in corpus.points { byOperator[point.operatorID, default: []].append(point) }
        let outerStrata = byOperator.keys.sorted().map { BudgetStratumV2(id: $0, candidates: byOperator[$0] ?? []) }
        let v2Selection = try BudgetSelectorV2.allocate(
            strata: outerStrata, limit: budget, seed: seed, minimumPerStratum: BudgetFormula.minimumPerStratum,
            weight: [:], innerDimension: Corpus.subtypeKey, innerMinimumPerStratum: 1
        ).map(\.point)

        let v1Plan = try PlanSharding.subset(of: plan, mutationIDs: v1Selection.map(\.id))
        let v2Plan = try PlanSharding.subset(of: plan, mutationIDs: v2Selection.map(\.id))

        try v1Plan.encoded().write(to: URL(fileURLWithPath: outputV1Plan))
        try v2Plan.encoded().write(to: URL(fileURLWithPath: outputV2Plan))

        print("v1 selection (selectByOperatorSubtype): \(v1Selection.count) mutants -> \(outputV1Plan)")
        print("v2 selection (S_default): \(v2Selection.count) mutants -> \(outputV2Plan)")
    }
}

struct Budget: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Compute protocol §4's maxMutants/seed from an unbudgeted plan.json."
    )

    @Argument(help: "Path to an unbudgeted (maxMutants unset) plan.json.")
    var planPath: String

    @Option(help: "Canonical corpus name (protocol §4/§2.1/§2.2).")
    var corpusName: String

    @Option(help: "This evaluation protocol document's frozen commit SHA.")
    var freezeCommitSHA: String

    func run() throws {
        let corpus = try Corpus.load(planPath: planPath, reportPath: nil)
        let result = BudgetFormula.compute(
            discoveredCount: corpus.discoveredCount, distinctOperatorCount: corpus.distinctOperatorCount,
            corpusName: corpusName, freezeCommitSHA: freezeCommitSHA
        )
        print("discoveredCount: \(corpus.discoveredCount)")
        print("distinctOperatorCount: \(corpus.distinctOperatorCount)")
        print("maxMutants: \(result.maxMutants)")
        print("seed: \(result.seed)")
        print("degenerate: \(result.degenerate)")
        if result.degenerate {
            print("WARNING: budget consumes the entire discovered pool -- this corpus cannot support a real comparison (protocol §4).")
        }
    }
}

struct ScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Run protocol §5's proxy-dependence screen for one corpus and both candidate metrics."
    )

    @Argument(help: "Path to the corpus's full unbudgeted plan.json.")
    var planPath: String

    @Argument(help: "Path to the corpus's full-pool report.json (real execution outcomes).")
    var reportPath: String

    @Option(help: "Canonical corpus name.")
    var corpusName: String

    @Option(help: "This corpus's §4-derived seed.")
    var seed: UInt64

    @Option(help: "This corpus's §4-derived maxMutants.")
    var budget: Int

    @Option(help: "Where to write the raw per-stratum results (JSON array of StratumTestResult).")
    var output: String

    func run() throws {
        let corpus = try Corpus.load(planPath: planPath, reportPath: reportPath)
        var allResults: [StratumTestResult] = []
        for metric in Metric.allCases {
            allResults += try Screen.run(corpusName: corpusName, corpus: corpus, metric: metric, seed: seed, budget: budget)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(allResults).write(to: URL(fileURLWithPath: output))
        print("Wrote \(allResults.count) stratum test results to \(output)")
    }
}

struct Aggregate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aggregate",
        abstract: "Apply protocol §5.6/§5.7's joint-family Bonferroni correction and eligibility rule across every corpus's screen output."
    )

    @Argument(help: "Paths to every corpus's `screen` output JSON.")
    var screenOutputPaths: [String]

    func run() throws {
        var allResults: [StratumTestResult] = []
        for path in screenOutputPaths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            allResults += try JSONDecoder().decode([StratumTestResult].self, from: data)
        }

        // K (protocol §5.6): every test that actually ran (`.tested`) or was
        // `indeterminate` (both count as real family members -- only
        // `.degeneratePass`/not-applicable markers are excluded, matching
        // §5.8's "excluded from K entirely" rule for not-applicable strata;
        // a degenerate-pass stratum DID have a real weight vector to vary,
        // so it counts).
        let familyMembers = allResults.filter { $0.stratum != "<not-applicable>" }
        let k = familyMembers.count
        let alpha = k > 0 ? 0.01 / Double(k) : 0.01

        print("Joint family size K = \(k), corrected alpha = \(alpha)")
        print("")

        for metric in Metric.allCases {
            let metricResults = allResults.filter { $0.metric == metric.rawValue }
            let outerResults = metricResults.filter { $0.dimension == .outer }
            let innerResults = metricResults.filter { $0.dimension == .inner }

            let outerApplicable = outerResults.filter { $0.stratum != "<not-applicable>" }
            let innerApplicable = innerResults.filter { $0.stratum != "<not-applicable>" }

            func passes(_ r: StratumTestResult) -> Bool {
                switch r.decision {
                case .degeneratePass:
                    return true
                case .indeterminateInsufficientData, .indeterminateDefinednessImbalance:
                    return false
                case .tested:
                    guard let p = r.pValue, let effect = r.effectSize, let range = r.observedRange, range > 0 else { return false }
                    // Reject H0 (fail) only if BOTH conditions hold (protocol §5.5).
                    let rejects = p < alpha && effect >= Screen.effectSizeFloorFraction * range
                    return !rejects
                }
            }

            let outerApplicableSomewhere = !outerApplicable.isEmpty
            let innerApplicableSomewhere = !innerApplicable.isEmpty
            let outerPassesEverywhereApplicable = outerApplicable.allSatisfy(passes)
            let innerPassesEverywhereApplicable = innerApplicable.allSatisfy(passes)

            let eligible = outerApplicableSomewhere && innerApplicableSomewhere
                && outerPassesEverywhereApplicable && innerPassesEverywhereApplicable

            print("\(metric.rawValue):")
            print("  outer applicable-somewhere: \(outerApplicableSomewhere), passes-everywhere-applicable: \(outerPassesEverywhereApplicable)")
            print("  inner applicable-somewhere: \(innerApplicableSomewhere), passes-everywhere-applicable: \(innerPassesEverywhereApplicable)")
            print("  PRIMARY-ELIGIBLE: \(eligible)")
            for r in metricResults where !passes(r) {
                let parentDescription = r.parent ?? "-"
                let pDescription = r.pValue.map { String($0) } ?? "-"
                let effectDescription = r.effectSize.map { String($0) } ?? "-"
                var line = "    FAILING: \(r.corpus) \(r.dimension.rawValue) parent=\(parentDescription)"
                line += " stratum=\(r.stratum) decision=\(r.decision.rawValue)"
                line += " p=\(pDescription) effect=\(effectDescription)"
                print(line)
            }
            print("")
        }
    }
}

struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Protocol §6's final per-corpus acceptance check: gating metric + non-inferiority kill rate, v1 vs v2."
    )

    @Argument(help: "v1's plan.json (the budgeted, selected plan actually run).")
    var v1PlanPath: String
    @Argument(help: "v1's report.json.")
    var v1ReportPath: String
    @Argument(help: "v2's plan.json.")
    var v2PlanPath: String
    @Argument(help: "v2's report.json.")
    var v2ReportPath: String

    @Option(help: "Which metric gates this comparison (m1SoleKillerTests or m2DistinctKilledDeclarations).")
    var gatingMetric: String

    @Option(help: "Non-inferiority margin in kill-rate percentage points (protocol §3.5).")
    var nonInferiorityMarginPoints: Double = 5.0

    func run() throws {
        guard let metric = Metric(rawValue: gatingMetric) else {
            throw ValidationError("Unknown metric '\(gatingMetric)'.")
        }
        let v1Corpus = try Corpus.load(planPath: v1PlanPath, reportPath: v1ReportPath)
        let v2Corpus = try Corpus.load(planPath: v2PlanPath, reportPath: v2ReportPath)

        let v1Metric = metric.value(selected: v1Corpus.points, corpus: v1Corpus)
        let v2Metric = metric.value(selected: v2Corpus.points, corpus: v2Corpus)
        let v1Kill = killRate(selected: v1Corpus.points, corpus: v1Corpus)
        let v2Kill = killRate(selected: v2Corpus.points, corpus: v2Corpus)

        print("v1 \(gatingMetric): \(v1Metric), kill rate: \(v1Kill.map { String(format: "%.4f", $0) } ?? "undefined")")
        print("v2 \(gatingMetric): \(v2Metric), kill rate: \(v2Kill.map { String(format: "%.4f", $0) } ?? "undefined")")

        guard let v1Kill, let v2Kill else {
            print("RESULT: inconclusive (zero-denominator kill rate on at least one side)")
            return
        }

        let metricPasses = v2Metric >= v1Metric
        let killRatePasses = (v2Kill * 100) >= (v1Kill * 100 - nonInferiorityMarginPoints)

        print("Metric non-inferior: \(metricPasses)")
        print("Kill-rate non-inferior (within \(nonInferiorityMarginPoints) points): \(killRatePasses)")
        print("RESULT: \(metricPasses && killRatePasses ? "PASS" : "FAIL")")
    }
}
