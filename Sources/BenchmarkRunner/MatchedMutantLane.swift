import Foundation

/// Phase B2 (rigorous-benchmark program): the "matched-mutant lane" —
/// distinct from the ordinary end-to-end lane (`BenchmarkOrchestrator`'s
/// own existing flow, unchanged: tool invocation → discovery → build →
/// mutation execution → report, each tool used exactly as a real user
/// would). No tool under comparison exposes a "run exactly this one
/// specified mutation" flag, so this lane cannot *drive* a narrower run —
/// what it *can* do, honestly, is take a tool's own already-completed
/// full E2E run and filter its results down to only the mutations
/// present in a `CanonicalMutationCorpus`, so every later metric is
/// computed over a mutation set every tool being compared is doing real,
/// provably-identical work on — the thing B1's whole corpus exists to
/// make possible.
public enum MatchedMutantLane {
    /// One tool's own results, narrowed to the corpus.
    public struct Measurement: Sendable {
        public let tool: String
        /// How many of the corpus's own mutations this tool's results
        /// actually covered — normally every one of them, since the
        /// corpus was built *from* this tool's own discovery in the first
        /// place, but a `Measurement` can also be computed from a fresh,
        /// independent run of the same tool against the same project,
        /// where real drift (a mutation the corpus recorded no longer
        /// exists, or the tool's own operator implementation changed) is
        /// a real, reportable possibility, not assumed impossible.
        public let matchedCount: Int
        /// How many of this tool's own keys were excluded from matching
        /// because this tool itself reported >1 distinct mutation at the
        /// same canonical position/family — real, reportable evidence
        /// that this tool's own results contain an internal ambiguity at
        /// a position the corpus expected a single, provable mutation.
        /// Never silently resolved by picking one arbitrarily.
        public let ambiguousKeyCount: Int
        /// The corpus's own total, for context — `matchedCount` out of
        /// `corpusSize`, never silently just "matchedCount" alone, since
        /// a lower match rate is itself real evidence (drift, a version
        /// change, or a real discrepancy) worth surfacing.
        public let corpusSize: Int
        public let byBucket: [String: Int]
        /// Sum of `NormalizedMutant.durationSeconds` across every matched
        /// mutation that has one — `nil` when the tool's own report
        /// exposes no per-mutant timing at all (confirmed real for Muter
        /// and swift-mutation-testing; see `NormalizedMutant
        /// .durationSeconds`'s own doc comment), never a fabricated
        /// estimate standing in for a real measurement the tool does not
        /// provide.
        public let sumMatchedDurationSeconds: Double?
        /// `matchedCount / sumMatchedDurationSeconds` — `nil` under the
        /// same condition as `sumMatchedDurationSeconds` itself, for the
        /// same reason.
        public var matchedMutantsPerSecond: Double? {
            guard let sumMatchedDurationSeconds, sumMatchedDurationSeconds > 0 else { return nil }
            return Double(matchedCount) / sumMatchedDurationSeconds
        }

        public init(
            tool: String, matchedCount: Int, ambiguousKeyCount: Int, corpusSize: Int,
            byBucket: [String: Int], sumMatchedDurationSeconds: Double?
        ) {
            self.tool = tool
            self.matchedCount = matchedCount
            self.ambiguousKeyCount = ambiguousKeyCount
            self.corpusSize = corpusSize
            self.byBucket = byBucket
            self.sumMatchedDurationSeconds = sumMatchedDurationSeconds
        }
    }

    /// - Parameters:
    ///   - mutants: one tool's own real, already-parsed results — from
    ///     the same real E2E run the corpus itself may have been built
    ///     from, or a fresh, independent one against the same project.
    ///   - corpus: the fixed `CanonicalMutationCorpus` to narrow to.
    ///
    /// Matches on the full canonical identity (`CanonicalMutationMatcher
    /// .FamilyKey` — path + line + column + operatorFamily), the same
    /// primitive `CanonicalMutationCorpusBuilder` itself uses, not
    /// `(path, line, column)` alone. A real review found the previous,
    /// position-only key let a *different* mutation at the same source
    /// position than the one actually in the corpus silently count as
    /// "matched" — able to inflate `matchedCount` past `corpusSize` in
    /// the worst case. `mutants` is also indexed with the same
    /// fail-closed ambiguity handling as every other caller of
    /// `CanonicalMutationMatcher`: if this tool's own results report more
    /// than one distinct mutation at a canonical key, that key is
    /// excluded from matching entirely (`ambiguousKeyCount`), never
    /// resolved by picking one arbitrarily.
    public static func measure(tool: String, mutants: [NormalizedMutant], corpus: CanonicalMutationCorpus) -> Measurement {
        let corpusKeys = Set(corpus.mutations.map {
            CanonicalMutationMatcher.FamilyKey(
                relativePath: $0.canonical.relativePath, line: $0.canonical.line,
                column: $0.canonical.column, operatorFamily: $0.canonical.operatorFamily
            )
        })

        let (indexed, ambiguousKeyCount) = CanonicalMutationMatcher.indexedByFamilyKey(mutants)
        let matched = indexed.filter { corpusKeys.contains($0.key) }.map(\.value)

        var byBucket: [String: Int] = [:]
        for mutant in matched { byBucket[mutant.bucket.rawValue, default: 0] += 1 }

        let durations = matched.compactMap(\.durationSeconds)
        // Only a sum when *every* matched mutant actually has a duration
        // — a partial sum (some mutants counted, others silently
        // skipped) would understate the real total and inflate the
        // derived throughput, exactly the kind of "wrong-but-plausible"
        // number this whole program exists to avoid.
        let sumDuration: Double? = durations.count == matched.count && !matched.isEmpty ? durations.reduce(0, +) : nil

        return Measurement(
            tool: tool, matchedCount: matched.count, ambiguousKeyCount: ambiguousKeyCount,
            corpusSize: corpus.mutations.count, byBucket: byBucket, sumMatchedDurationSeconds: sumDuration
        )
    }
}
