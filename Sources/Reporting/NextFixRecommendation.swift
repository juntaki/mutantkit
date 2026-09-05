import MutationModel

/// Picks exactly one surviving/uncovered mutant to fix next, out of every
/// entry `TestObligationAnalyzer.buildFixPlan(from:)` produces — the
/// "what should I actually go do" question `mutantkit survivors`/
/// `mutantkit fix-plan` deliberately leave to the reader.
///
/// The ranking is entirely over real, already-computed data — nothing new is
/// measured or guessed to produce it:
///
/// 1. `coveredButNotCaught` (a `.survived` mutant) ranks above `.noCoverage`.
///    A distinguishing-test gap is directly actionable at the mutation site
///    right now; a reachability gap needs new coverage to exist before any
///    assertion could even matter — the more tractable fix goes first.
/// 2. Higher `TestObligation.Confidence` ranks above lower. A mechanically-
///    certain obligation (a fixed table lookup — see `TestObligation`'s own
///    doc comment) is safer to act on immediately than one this analyzer
///    itself flagged as one hop removed from the mutation site, or entirely
///    unmodeled.
/// 3. Fewer tests recorded in the deciding attempt
///    (`MutantFixPlanEntry.Facts.testsRun`) ranks above more, and no
///    recorded count (an outcome this analyzer cannot size at all) ranks
///    last. This is real data straight off `MutationResult.testSummary`,
///    not a new field: for a `.narrowed` scope it is the small covering set
///    that actually ran; for a `.fullSuite` scope it is the whole
///    configured suite; either way it is exactly "how many tests would I
///    need to read through to start investigating."
/// 4. A larger cluster (`MutantFixPlanEntry.Facts.clusterSize` — how many
///    mutants share this exact declaration and root cause,
///    `SurvivorActionabilityReport.IssueCluster.members.count` reused
///    directly) ranks above a smaller one: one fix addresses more surviving
///    mutants at once.
/// 5. Ties break on the mutant ID string, for a total, deterministic
///    ordering — the same discipline `SurvivorActionabilityReport.buildGroup`
///    already applies to its own cluster ordering, and for the identical
///    reason: two runs over the same report must recommend the same mutant,
///    never one that happens to depend on `Dictionary`'s unspecified
///    iteration order.
public struct NextFixRecommendation: Codable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    /// How many surviving/uncovered mutants were considered — `0` means
    /// `recommendation` is `nil` because there was nothing to recommend,
    /// not because ranking failed.
    public let candidateCount: Int
    public let recommendation: MutantFixPlanEntry?
    /// The ranking criteria above, in the exact priority order `rank(_:)`
    /// applies them — carried on the value itself so "why this one" is
    /// never a black box, in `--json` output as much as in text.
    public let rankingCriteria: [String]

    public init(planID: String, candidateCount: Int, recommendation: MutantFixPlanEntry?, rankingCriteria: [String]) {
        schemaVersion = SchemaVersion.nextFixRecommendation
        self.planID = planID
        self.candidateCount = candidateCount
        self.recommendation = recommendation
        self.rankingCriteria = rankingCriteria
    }

    public static let rankingCriteria: [String] = [
        "coveredButNotCaught (a survived mutant) ranks above noCoverage: a distinguishing-test gap is directly " +
            "actionable now, a reachability gap needs new coverage to exist first",
        "higher inference confidence ranks above lower: a mechanically-certain obligation is safer to act on than " +
            "one this analyzer flagged as indirect or unmodeled",
        "fewer tests recorded in the deciding attempt ranks above more, and no recorded count ranks last: less to " +
            "read through before investigating",
        "a larger cluster (more mutants sharing this exact declaration and root cause) ranks above a smaller one: " +
            "one fix addresses more survivors at once",
        "ties break on mutant ID, for a deterministic recommendation"
    ]

    /// Builds the fix plan (`TestObligationAnalyzer.buildFixPlan`) and picks
    /// its highest-ranked entry. `recommendation` is `nil` only when
    /// `candidateCount == 0` — no surviving or uncovered mutants in this
    /// report at all.
    public static func build(from report: RunReport) -> NextFixRecommendation {
        let entries = TestObligationAnalyzer.buildFixPlan(from: report)
        return NextFixRecommendation(
            planID: report.planID, candidateCount: entries.count, recommendation: rank(entries).first, rankingCriteria: rankingCriteria
        )
    }

    /// Every entry, best-first, by the five criteria this type's own doc
    /// comment enumerates. `public` (not just used internally by `build`)
    /// so a caller that wants "the top N" rather than just the single best
    /// can reuse the identical ordering instead of re-deriving it.
    public static func rank(_ entries: [MutantFixPlanEntry]) -> [MutantFixPlanEntry] {
        entries.sorted { lhs, rhs in
            let lhsNoCoverage = lhs.facts.outcome == .noCoverage
            let rhsNoCoverage = rhs.facts.outcome == .noCoverage
            if lhsNoCoverage != rhsNoCoverage { return !lhsNoCoverage }

            if lhs.inference.confidence != rhs.inference.confidence {
                return lhs.inference.confidence > rhs.inference.confidence
            }

            let lhsScope = lhs.facts.testsRun ?? Int.max
            let rhsScope = rhs.facts.testsRun ?? Int.max
            if lhsScope != rhsScope { return lhsScope < rhsScope }

            if lhs.facts.clusterSize != rhs.facts.clusterSize { return lhs.facts.clusterSize > rhs.facts.clusterSize }

            return lhs.facts.mutantID < rhs.facts.mutantID
        }
    }
}
