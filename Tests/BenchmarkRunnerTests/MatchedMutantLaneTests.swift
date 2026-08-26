@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("MatchedMutantLane (Phase B2)")
struct MatchedMutantLaneTests {
    private func makeMutant(
        path: String = "A.swift", line: Int, column: Int, bucket: NormalizedMutant.Bucket = .killed, durationSeconds: Double? = nil
    ) -> NormalizedMutant {
        NormalizedMutant(
            identity: CrossToolMutationIdentity(
                relativePath: path, startUTF8Offset: 0, endUTF8Offset: 0, originalTextHash: "", replacementTextHash: "",
                normalizedOperatorFamily: "relational-operator", line: line, column: column
            ),
            bucket: bucket, provenActive: nil, durationSeconds: durationSeconds
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
}
