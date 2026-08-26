import MutationModel
import MutationPlanner

/// One stratum's raw test result (protocol §5.5) — the Bonferroni
/// correction against the full joint family (§5.6, spanning every corpus
/// and both metrics) is applied by a separate aggregation step once every
/// corpus has been screened, not here.
struct StratumTestResult: Codable {
    enum Dimension: String, Codable { case outer, inner }
    enum Decision: String, Codable {
        case degeneratePass
        case tested
        case indeterminateInsufficientData
        case indeterminateDefinednessImbalance
    }

    let corpus: String
    let metric: String
    let dimension: Dimension
    /// The outer stratum ID this test concerns; for an inner test, the
    /// parent operator this inner stratum belongs to.
    let parent: String?
    let stratum: String
    let decision: Decision
    /// Present only when `decision == .tested`.
    let pValue: Double?
    let effectSize: Double?
    /// The range of `M_b` observed across all rounds — needed by the
    /// aggregation step to interpret `effectSize` relative to it, since the
    /// 10%-of-range floor (§5.5) is itself corpus/parent-specific.
    let observedRange: Double?
}

enum Screen {
    static let roundCount = 3000
    static let minimumObservationsPerTercile = 30
    static let definednessImbalanceThreshold = 0.10
    static let effectSizeFloorFraction = 0.10

    /// Runs both the outer screen and every applicable inner (per-parent)
    /// screen for one corpus and one metric. `seed` is this corpus's §4
    /// seed; `budget` is this corpus's §4 `maxMutants`.
    static func run(corpusName: String, corpus: Corpus, metric: Metric, seed: UInt64, budget: Int) throws -> [StratumTestResult] {
        var results: [StratumTestResult] = []

        var byOperator: [String: [MutationPoint]] = [:]
        for point in corpus.points { byOperator[point.operatorID, default: []].append(point) }
        let outerStrata = byOperator.keys.sorted().map { BudgetStratumV2(id: $0, candidates: byOperator[$0] ?? []) }

        // S_default: the real allocator at production defaults, computed once, reused by both screens.
        let sDefault = try BudgetSelectorV2.allocate(
            strata: outerStrata, limit: budget, seed: seed, minimumPerStratum: BudgetFormula.minimumPerStratum,
            weight: [:], innerDimension: Corpus.subtypeKey, innerMinimumPerStratum: 1
        ).map(\.point)

        results += try runOuterScreen(
            corpusName: corpusName, corpus: corpus, metric: metric, seed: seed, budget: budget, outerStrata: outerStrata
        )
        results += try runInnerScreens(
            corpusName: corpusName, corpus: corpus, metric: metric, seed: seed, byOperator: byOperator, sDefault: sDefault
        )
        return results
    }

    private static func runOuterScreen(
        corpusName: String, corpus: Corpus, metric: Metric, seed: UInt64, budget: Int, outerStrata: [BudgetStratumV2]
    ) throws -> [StratumTestResult] {
        let operatorIDs = outerStrata.map(\.id).sorted()
        guard operatorIDs.count >= 2 else {
            return [notApplicableMarker(corpusName: corpusName, metric: metric, dimension: .outer, parent: nil)]
        }

        var weightShareByStratumRound: [String: [Double]] = Dictionary(uniqueKeysWithValues: operatorIDs.map { ($0, []) })
        var metricValueByRound: [Int?] = []

        for round in 1 ... roundCount {
            var weights: [String: Int] = [:]
            for stratumID in operatorIDs {
                weights[stratumID] = syntheticWeight(seed: seed, tag: "weight-screen-outer-round-\(round)-\(stratumID)")
            }
            let total = Double(weights.values.reduce(0, +))
            for stratumID in operatorIDs {
                weightShareByStratumRound[stratumID]?.append(Double(weights[stratumID] ?? 0) / total)
            }

            let selection = try BudgetSelectorV2.allocate(
                strata: outerStrata, limit: budget, seed: seed, minimumPerStratum: BudgetFormula.minimumPerStratum,
                weight: weights, innerDimension: Corpus.subtypeKey, innerMinimumPerStratum: 1
            ).map(\.point)

            if selection.contains(where: { corpus.outcomes[$0.id]?.isKilled == true || corpus.outcomes[$0.id] == .survived }) {
                metricValueByRound.append(metric.value(selected: selection, corpus: corpus))
            } else {
                metricValueByRound.append(nil)
            }
        }

        return operatorIDs.map { stratumID in
            decide(
                corpusName: corpusName, metric: metric, dimension: .outer, parent: nil, stratum: stratumID,
                weightShares: weightShareByStratumRound[stratumID] ?? [], metricValues: metricValueByRound
            )
        }
    }

    private static func runInnerScreens(
        corpusName: String, corpus: Corpus, metric: Metric, seed: UInt64, byOperator: [String: [MutationPoint]], sDefault: [MutationPoint]
    ) throws -> [StratumTestResult] {
        var sDefaultByID: [MutationID: MutationPoint] = [:]
        for point in sDefault { sDefaultByID[point.id] = point }
        var sDefaultIDsByOperator: [String: Set<MutationID>] = [:]
        for point in sDefault { sDefaultIDsByOperator[point.operatorID, default: []].insert(point.id) }

        var results: [StratumTestResult] = []

        for parent in byOperator.keys.sorted() {
            let parentCandidates = byOperator[parent] ?? []
            let innerIDs = Set(parentCandidates.map(Corpus.subtypeKey)).sorted()
            guard innerIDs.count >= 2 else {
                results.append(notApplicableMarker(corpusName: corpusName, metric: metric, dimension: .inner, parent: parent))
                continue
            }

            let nParent = sDefaultIDsByOperator[parent]?.count ?? 0
            guard nParent > 0 else {
                results.append(notApplicableMarker(corpusName: corpusName, metric: metric, dimension: .inner, parent: parent))
                continue
            }

            let baseline = sDefault.filter { $0.operatorID != parent }

            var weightShareByStratumRound: [String: [Double]] = Dictionary(uniqueKeysWithValues: innerIDs.map { ($0, []) })
            var metricValueByRound: [Int?] = []

            for round in 1 ... roundCount {
                var weights: [String: Int] = [:]
                for stratumID in innerIDs {
                    weights[stratumID] = syntheticWeight(seed: seed, tag: "weight-screen-inner-\(parent)-round-\(round)-\(stratumID)")
                }
                let total = Double(weights.values.reduce(0, +))
                for stratumID in innerIDs {
                    weightShareByStratumRound[stratumID]?.append(Double(weights[stratumID] ?? 0) / total)
                }

                // Single-element outer strata array: exact-fill guarantees this
                // one stratum receives the entire `limit` (nParent), so this
                // is `allocate()`'s real internal computation for `parent`,
                // isolated — see protocol §5.3's access note.
                let parentSelection = try BudgetSelectorV2.allocate(
                    strata: [BudgetStratumV2(id: parent, candidates: parentCandidates)],
                    limit: nParent, seed: seed, minimumPerStratum: 1, weight: [:],
                    innerDimension: Corpus.subtypeKey, innerMinimumPerStratum: 1, innerWeight: weights
                ).map(\.point)

                let sB = baseline + parentSelection
                if sB.contains(where: { corpus.outcomes[$0.id]?.isKilled == true || corpus.outcomes[$0.id] == .survived }) {
                    metricValueByRound.append(metric.value(selected: sB, corpus: corpus))
                } else {
                    metricValueByRound.append(nil)
                }
            }

            for stratumID in innerIDs {
                results.append(decide(
                    corpusName: corpusName, metric: metric, dimension: .inner, parent: parent, stratum: stratumID,
                    weightShares: weightShareByStratumRound[stratumID] ?? [], metricValues: metricValueByRound
                ))
            }
        }

        return results
    }

    private static func notApplicableMarker(corpusName: String, metric: Metric, dimension: StratumTestResult.Dimension, parent: String?) -> StratumTestResult {
        StratumTestResult(
            corpus: corpusName, metric: metric.rawValue, dimension: dimension, parent: parent, stratum: "<not-applicable>",
            decision: .degeneratePass, pValue: nil, effectSize: nil, observedRange: nil
        )
    }

    private static func syntheticWeight(seed: UInt64, tag: String) -> Int {
        var generator = SplitMix64(seed: seed ^ StableHash.fnv1a64(tag))
        return 1 + Int(generator.next() % 1_000_000)
    }

    /// Terciles (protocol §5.5): ranked by weight share, formed from *all*
    /// rounds before any round is excluded for an undefined metric value.
    private static func decide(
        corpusName: String, metric: Metric, dimension: StratumTestResult.Dimension, parent: String?, stratum: String,
        weightShares: [Double], metricValues: [Int?]
    ) -> StratumTestResult {
        let n = weightShares.count
        let order = (0 ..< n).sorted { weightShares[$0] < weightShares[$1] }
        let terciles = [
            Array(order.prefix(n / 3)),
            Array(order.dropFirst(n / 3).prefix(n / 3)),
            Array(order.suffix(n - 2 * (n / 3)))
        ]

        let definedGroups: [[Int]] = terciles.map { indices in indices.compactMap { metricValues[$0] } }
        let definedCounts = definedGroups.map(\.count)

        guard definedCounts.allSatisfy({ $0 >= minimumObservationsPerTercile }) else {
            return StratumTestResult(
                corpus: corpusName, metric: metric.rawValue, dimension: dimension, parent: parent, stratum: stratum,
                decision: .indeterminateInsufficientData, pValue: nil, effectSize: nil, observedRange: nil
            )
        }

        let definedProportions = zip(terciles, definedCounts).map { Double($1) / Double($0.count) }
        let maxImbalance = definedProportions.max()! - definedProportions.min()!
        guard maxImbalance <= definednessImbalanceThreshold else {
            return StratumTestResult(
                corpus: corpusName, metric: metric.rawValue, dimension: dimension, parent: parent, stratum: stratum,
                decision: .indeterminateDefinednessImbalance, pValue: nil, effectSize: nil, observedRange: nil
            )
        }

        let allDefined = definedGroups.flatMap { $0 }
        let distinctValues = Set(allDefined)
        guard distinctValues.count > 1 else {
            return StratumTestResult(
                corpus: corpusName, metric: metric.rawValue, dimension: dimension, parent: parent, stratum: stratum,
                decision: .degeneratePass, pValue: nil, effectSize: nil, observedRange: nil
            )
        }

        let kw = KruskalWallis.test(definedGroups)
        let medians = definedGroups.map(Median.of)
        let pairwise = [
            abs(medians[0] - medians[1]), abs(medians[0] - medians[2]), abs(medians[1] - medians[2])
        ]
        let effectSize = pairwise.max() ?? 0
        let range = Double((allDefined.max() ?? 0) - (allDefined.min() ?? 0))

        return StratumTestResult(
            corpus: corpusName, metric: metric.rawValue, dimension: dimension, parent: parent, stratum: stratum,
            decision: .tested, pValue: kw?.pValue, effectSize: effectSize, observedRange: range
        )
    }
}
