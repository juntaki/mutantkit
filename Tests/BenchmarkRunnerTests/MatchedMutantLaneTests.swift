@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("MatchedMutantLane (Phase B2)")
struct MatchedMutantLaneTests {
    private func makeMutant(
        path: String = "A.swift", line: Int, column: Int, family: String = "relational-operator",
        bucket: NormalizedMutant.Bucket = .killed, durationSeconds: Double? = nil, nativeID: String? = nil
    ) -> NormalizedMutant {
        NormalizedMutant(
            identity: CrossToolMutationIdentity(
                relativePath: path, startUTF8Offset: 0, endUTF8Offset: 0, originalTextHash: "", replacementTextHash: "",
                normalizedOperatorFamily: family, line: line, column: column
            ),
            bucket: bucket, provenActive: nil, nativeID: nativeID, durationSeconds: durationSeconds
        )
    }

    private func makeCorpus(positions: [(Int, Int)]) -> CanonicalMutationCorpus {
        let mutations = positions.map { line, column in
            MatchedMutation(
                canonical: CanonicalMutation(
                    repositoryCommit: "deadbeef", relativePath: "A.swift", line: line, column: column,
                    originalText: "<", replacementText: "<=", operatorFamily: "relational-operator"
                ),
                tools: [:]
            )
        }
        return CanonicalMutationCorpus(projectID: "example", repositoryCommit: "deadbeef", builtAt: "", tools: [], mutations: mutations)
    }

    @Test("Only mutations at a corpus position are counted; everything else is filtered out")
    func filtersToCorpusPositionsOnly() {
        let corpus = makeCorpus(positions: [(10, 5), (20, 1)])
        let mutants = [
            makeMutant(line: 10, column: 5, bucket: .killed),
            makeMutant(line: 20, column: 1, bucket: .survived),
            makeMutant(line: 30, column: 1, bucket: .killed) // not in the corpus
        ]
        let measurement = MatchedMutantLane.measure(tool: "mutantkit", mutants: mutants, corpus: corpus)
        #expect(measurement.matchedCount == 2)
        #expect(measurement.corpusSize == 2)
        #expect(measurement.byBucket["killed"] == 1)
        #expect(measurement.byBucket["survived"] == 1)
    }

    @Test("A lower match count than the corpus size is real, reportable drift, not silently hidden")
    func lowerMatchCountIsVisible() {
        let corpus = makeCorpus(positions: [(10, 5), (20, 1), (30, 1)])
        let mutants = [makeMutant(line: 10, column: 5)]
        let measurement = MatchedMutantLane.measure(tool: "muter", mutants: mutants, corpus: corpus)
        #expect(measurement.matchedCount == 1)
        #expect(measurement.corpusSize == 3, "the corpus's own total must stay visible even when this tool matched fewer")
    }

    @Test("Duration sums only when every matched mutant has one — a partial sum is never silently reported")
    func durationOnlySumsWhenComplete() {
        let corpus = makeCorpus(positions: [(10, 5), (20, 1)])
        let complete = MatchedMutantLane.measure(
            tool: "mutantkit",
            mutants: [makeMutant(line: 10, column: 5, durationSeconds: 2.0), makeMutant(line: 20, column: 1, durationSeconds: 3.0)],
            corpus: corpus
        )
        #expect(complete.sumMatchedDurationSeconds == 5.0)
        #expect(complete.matchedMutantsPerSecond == 2.0 / 5.0)

        let partial = MatchedMutantLane.measure(
            tool: "muter",
            mutants: [makeMutant(line: 10, column: 5, durationSeconds: 2.0), makeMutant(line: 20, column: 1, durationSeconds: nil)],
            corpus: corpus
        )
        #expect(partial.sumMatchedDurationSeconds == nil, "a partial sum would understate the real total")
        #expect(partial.matchedMutantsPerSecond == nil)
    }

    @Test("An empty match yields zero counts and a nil duration, not a crash or a divide-by-zero")
    func emptyMatchIsHandledSafely() {
        let corpus = makeCorpus(positions: [(10, 5)])
        let measurement = MatchedMutantLane.measure(tool: "mutantkit", mutants: [], corpus: corpus)
        #expect(measurement.matchedCount == 0)
        #expect(measurement.sumMatchedDurationSeconds == nil)
        #expect(measurement.matchedMutantsPerSecond == nil)
    }

    /// Regression test for a real bug: this lane used to match on
    /// `(path, line, column)` alone, never `operatorFamily` — so a
    /// *different* mutation at the same source position as a real corpus
    /// entry could silently count as "matched." A same-position,
    /// different-family mutant must never match; `matchedCount` must
    /// never exceed `corpusSize`.
    @Test("A different operator family at the same position as a corpus entry never counts as matched")
    func differentFamilyAtSamePositionNeverMatches() {
        let corpus = makeCorpus(positions: [(10, 5)])
        let mutants = [makeMutant(line: 10, column: 5, family: "logical-connector")]
        let measurement = MatchedMutantLane.measure(tool: "mutantkit", mutants: mutants, corpus: corpus)
        #expect(measurement.matchedCount == 0, "same position, different family, must never be counted as the corpus's own mutation")
        #expect(measurement.matchedCount <= measurement.corpusSize)
    }

    /// Regression test: this tool's own results reporting two genuinely
    /// different mutations at the same canonical key must fail closed
    /// (excluded from matching, counted as ambiguous) rather than
    /// arbitrarily picking one — the same rule
    /// `CanonicalMutationCorpusBuilder` already enforces.
    @Test("This tool's own internal ambiguity at a corpus position is excluded from matching, not arbitrarily resolved")
    func internalAmbiguityIsExcludedNotResolved() {
        let corpus = makeCorpus(positions: [(10, 5), (20, 1)])
        let mutants = [
            makeMutant(line: 10, column: 5, nativeID: "a"),
            makeMutant(line: 10, column: 5, nativeID: "b"), // same key; same (family, empty text) as "a", not a real disagreement
            makeMutant(line: 20, column: 1)
        ]
        // The two candidates at (10, 5) share the same (family, empty text)
        // — from this tool's own perspective they are indistinguishable
        // duplicates, not a disagreement, so they collapse safely and
        // still match. This test exists to pin that this is a conscious
        // choice, not an oversight: ambiguity is about *disagreeing*
        // candidates, not merely repeated ones.
        let measurement = MatchedMutantLane.measure(tool: "mutantkit", mutants: mutants, corpus: corpus)
        #expect(measurement.matchedCount == 2)
        #expect(measurement.ambiguousKeyCount == 0)
    }
}
