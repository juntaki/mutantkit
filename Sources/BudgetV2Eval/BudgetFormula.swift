import MutationPlanner

/// Protocol §4's deterministic budget/seed derivation — a pure function of
/// a corpus's own discovered-pool facts and its canonical name, with no
/// discretionary input.
enum BudgetFormula {
    static let minimumPerStratum = 1

    struct Result {
        let maxMutants: Int
        let seed: UInt64
        /// True when the formula's floor/minimum-reservation term alone
        /// consumes the entire discovered pool (§4: the corpus cannot
        /// support a real budgeted comparison and must be excluded).
        let degenerate: Bool
    }

    static func compute(discoveredCount: Int, distinctOperatorCount: Int, corpusName: String, freezeCommitSHA: String) -> Result {
        let n = discoveredCount
        let floorTerm = 2 * minimumPerStratum * distinctOperatorCount
        let proportionalTerm = Int((0.4 * Double(n)).rounded(.down))
        let maxMutants = min(n, max(floorTerm, proportionalTerm))
        let seed = StableHash.fnv1a64("budget-v2-eval-\(corpusName)-\(freezeCommitSHA)")
        return Result(maxMutants: maxMutants, seed: seed, degenerate: maxMutants == n)
    }
}
