@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

@Suite("SourceCoverageReader: files whose code never ran")
struct SourceCoverageNeverRunFileTests {
    private let projectRoot = URL(fileURLWithPath: "/Users/demo/project")

    /// A file whose regions exist but never ran is a claim: `isKnownUncovered` must say so, not
    /// leave the mutants in it to run the whole suite.
    @Test("A file with mapped regions that never ran is recorded as empty, and its lines are known uncovered")
    func neverExecutedFileIsRecordedEmpty() throws {
        let json = SourceCoverageReaderTests.makeExport(files: [
            (path: "/Users/demo/project/Sources/Dead.swift", segments: [[1, 1, 0, true, true, false], [3, 1, 0, false, false, false]]),
            (path: "/Users/demo/project/Sources/Foo.swift", segments: [[1, 1, 1, true, true, false]])
        ])

        let parsed = try #require(SourceCoverageReader.parse(json, projectRoot: projectRoot))
        #expect(parsed["Sources/Dead.swift"] == [])
        let map = CoverageMap(executedLines: parsed, source: "test")
        #expect(map.observation(forFile: "Sources/Dead.swift", line: 2)?.mutatedLineWasExecuted == false)
    }

    @Test("A document in which nothing ran at all is still no coverage information")
    func nothingRanIsNil() throws {
        let json = SourceCoverageReaderTests.makeExport(files: [
            (path: "/Users/demo/project/Sources/Dead.swift", segments: [[1, 1, 0, true, true, false]])
        ])
        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }
}
