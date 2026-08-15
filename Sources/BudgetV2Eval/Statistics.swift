import Foundation

/// Tie-corrected Kruskal-Wallis H statistic + its asymptotic chi-squared
/// (df=2) p-value, exactly as specified in
/// `Research/budget-selection-v2/evaluation-protocol.md` §5.5 — the same
/// tie correction `scipy.stats.kruskal`/R `kruskal.test` apply by default.
///
/// Three groups only (the screen's low/mid/high weight terciles), so `df`
/// is always 2 and the chi-squared(2) CDF has the closed form
/// `1 - exp(-x/2)`, needing no special-function library.
enum KruskalWallis {
    struct Result {
        let h: Double
        let pValue: Double
    }

    /// `groups`: three non-empty arrays of `Int` metric values (`M_b`).
    /// Returns `nil` only if any group is empty (a precondition violation
    /// the caller must never hit — the minimum-observations rule in §5.5
    /// is checked separately, before this is called).
    static func test(_ groups: [[Int]]) -> Result? {
        precondition(groups.count == 3, "This screen's tercile design always compares exactly 3 groups.")
        guard groups.allSatisfy({ !$0.isEmpty }) else { return nil }

        let n = groups.reduce(0) { $0 + $1.count }
        // Pool, rank (average rank for ties), split back into groups.
        let pooled = groups.enumerated().flatMap { groupIndex, values in
            values.map { (groupIndex: groupIndex, value: $0) }
        }
        let order = pooled.indices.sorted { pooled[$0].value < pooled[$1].value }

        var ranks = [Double](repeating: 0, count: pooled.count)
        var index = 0
        while index < order.count {
            var end = index
            while end + 1 < order.count, pooled[order[end + 1]].value == pooled[order[index]].value {
                end += 1
            }
            // Average rank (1-based) across the tie block [index...end].
            let averageRank = Double(index + end + 2) / 2.0
            for position in index ... end {
                ranks[order[position]] = averageRank
            }
            index = end + 1
        }

        var rankSumByGroup = [Double](repeating: 0, count: 3)
        for (position, entry) in pooled.enumerated() {
            rankSumByGroup[entry.groupIndex] += ranks[position]
        }

        let nD = Double(n)
        var h = 0.0
        for groupIndex in 0 ..< 3 {
            let ni = Double(groups[groupIndex].count)
            h += (rankSumByGroup[groupIndex] * rankSumByGroup[groupIndex]) / ni
        }
        h = (12.0 / (nD * (nD + 1))) * h - 3.0 * (nD + 1)

        // Tie correction: 1 - sum(t_i^3 - t_i) / (n^3 - n), t_i = size of each tied-value group.
        var tieCounts: [Int: Int] = [:]
        for entry in pooled { tieCounts[entry.value, default: 0] += 1 }
        let tieSum = tieCounts.values.reduce(0.0) { partial, count in
            let t = Double(count)
            return partial + (t * t * t - t)
        }
        let denominator = nD * nD * nD - nD
        // denominator == 0 only when n < 2, which the minimum-observations
        // rule (>= 30 per group) already precludes; guard anyway rather than
        // trap.
        let correction = denominator > 0 ? 1.0 - tieSum / denominator : 1.0
        let hCorrected = correction > 0 ? h / correction : h

        // Chi-squared(df=2) CDF has the closed form 1 - exp(-x/2); p-value
        // is the upper tail, 1 - CDF(h) = exp(-h/2).
        let pValue = exp(-hCorrected / 2.0)

        return Result(h: hCorrected, pValue: min(1.0, max(0.0, pValue)))
    }
}

enum Median {
    /// Exact median of an `Int` array (average of the two middle values on
    /// an even count), as a `Double`.
    static func of(_ values: [Int]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[mid]) }
        return Double(sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
