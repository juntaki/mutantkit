@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// A line the coverage export has no region for was never measured. That is not the same as a line
/// no test reaches, and treating it so scored a mutant a test kills as `.noCoverage` or `.survived`
/// (a literal default argument, `isBuiltInDefault: Bool = false`, is the real instance).
@Suite("Lines the coverage export does not measure")
struct UnmeasuredLinesTests {
    private let test = TestIdentifier(target: "T", qualifiedName: "S/t")
    private let other = TestIdentifier(target: "T", qualifiedName: "S/other")

    // MARK: Reader

    /// Segments shaped like the real export for `DestinationResolver.swift`: regions start on lines
    /// 173 and 174 and none touches 172, the default-argument line.
    @Test("The reader reports a line with no region as unmeasured, and a region that never ran as measured")
    func readerSeparatesUnmeasuredFromUnexecuted() throws {
        let segments: [[Any]] = [
            [173, 37, 0, true, true, false],
            [174, 54, 0, true, true, false],
            [175, 10, 4, true, true, false],
            [176, 2, 0, false, false, false]
        ]

        let lines = try #require(SourceCoverageReader.coverageLines(from: segments))

        #expect(!lines.mapped.contains(172))
        #expect(lines.mapped.isSuperset(of: [173, 174, 175]))
        #expect(lines.executed.contains(175))
        #expect(!lines.executed.contains(173) && !lines.executed.contains(174))
        #expect(try #require(SourceCoverageReader.executedLines(from: segments)) == lines.executed)
    }

    // MARK: CoverageMap

    private static let file = "Sources/Q.swift"

    /// A real anchored point, with the line overridden: the coverage lookup is per line.
    private func point(line: Int) throws -> MutationPoint {
        let discovered = try discover(
            "struct Q {\n    var enabled = true\n}", path: Self.file, using: Operators.boolLiteral
        )[0]
        return MutationPoint(
            id: discovered.id, file: discovered.file, enclosingDeclaration: discovered.enclosingDeclaration,
            operatorID: discovered.operatorID, operatorVersion: discovered.operatorVersion,
            occurrenceIndex: discovered.occurrenceIndex, utf8Range: discovered.utf8Range,
            originalText: discovered.originalText, replacementText: discovered.replacementText,
            prefixTokenFingerprint: discovered.prefixTokenFingerprint,
            suffixTokenFingerprint: discovered.suffixTokenFingerprint, sourceFileHash: discovered.sourceFileHash,
            expectedSyntaxKind: discovered.expectedSyntaxKind, confidence: discovered.confidence,
            executionMode: discovered.executionMode, line: line, column: discovered.column
        )
    }

    @Test("A mapped line that never ran is known uncovered; an unmapped one is not")
    func isKnownUncoveredNeedsAMeasuredLine() throws {
        let map = CoverageMap(
            executedLines: [Self.file: [10]], source: "t", mappedLines: [Self.file: [10, 11]]
        )

        #expect(map.isKnownUncovered(try point(line: 11)))
        #expect(try !map.isKnownUncovered(point(line: 12)))
        #expect(map.observation(forFile: Self.file, line: 12) == nil)
        #expect(map.observation(forFile: Self.file, line: 11)?.mutatedLineWasExecuted == false)
    }

    @Test("A map that provides no mapped lines is judged as it always was")
    func legacyMapIsUnchanged() throws {
        let map = CoverageMap(executedLines: [Self.file: [10]], source: "t")

        #expect(map.isKnownUncovered(try point(line: 12)))
        #expect(map.observation(forFile: Self.file, line: 12)?.mutatedLineWasExecuted == false)
    }

    // MARK: PerTestCoverageMap

    @Test("No tests are named for a line nothing measured, so the caller runs everything")
    func unmeasuredLineNamesNoTests() {
        let map = PerTestCoverageMap(
            coveringTests: [Self.file: [10: [test]]], source: "t", mappedLines: [Self.file: [10, 11]]
        )

        #expect(map.testsCovering(file: Self.file, line: 10) == [test])
        #expect(map.testsCovering(file: Self.file, line: 12) == nil)
    }

    @Test("A partial map does not narrow an unmeasured line to its unattributed tests either")
    func partialMapDoesNotNarrowAnUnmeasuredLine() {
        let map = PerTestCoverageMap(
            coveringTests: [Self.file: [10: [test]]], source: "t", unattributedTests: [other],
            mappedLines: [Self.file: [10]]
        )

        #expect(map.testsCovering(file: Self.file, line: 12) == nil)
        #expect(map.testsCovering(file: Self.file, line: 10) == [test, other])
    }

    @Test("A measured line nobody ran still gets the unattributed tests, as before")
    func measuredUnexecutedLineKeepsTheUnattributedSelection() {
        let map = PerTestCoverageMap(
            coveringTests: [Self.file: [10: [test]]], source: "t", unattributedTests: [other],
            mappedLines: [Self.file: [10, 11]]
        )

        #expect(map.testsCovering(file: Self.file, line: 11) == [other])
    }

    @Test("The aggregate keeps the mapped lines, so the noCoverage fast path sees them")
    func aggregateCarriesMappedLines() throws {
        let map = PerTestCoverageMap(
            coveringTests: [Self.file: [10: [test]]], source: "t", mappedLines: [Self.file: [10, 11]]
        )

        let aggregate = try #require(map.aggregate())

        #expect(aggregate.mappedLines == [Self.file: [10, 11]])
        #expect(!aggregate.isKnownUncovered(try point(line: 12)))
        #expect(aggregate.isKnownUncovered(try point(line: 11)))
    }

    @Test("The mapped lines survive the cache round trip, and an entry without them still decodes")
    func codableRoundTripAndLegacyEntry() throws {
        let map = PerTestCoverageMap(
            coveringTests: [Self.file: [10: [test]]], source: "t", mappedLines: [Self.file: [10, 11]]
        )
        let decoded = try JSONDecoder().decode(PerTestCoverageMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)

        let legacy = Data(
            #"{"tests":[{"target":"T","qualifiedName":"S/t"}],"source":"t","coveringTests":{"Sources/Q.swift":{"10":[0]}}}"#.utf8
        )
        #expect(try JSONDecoder().decode(PerTestCoverageMap.self, from: legacy).mappedLines.isEmpty)
    }

    @Test("Attribution unions the mapped lines of every measurement into the map")
    func attributionCarriesMappedLines() async throws {
        let map = try #require(await PerTestCoverageAttribution.attribute(tests: [test, other], source: "t") { measured, _ in
            if measured == test {
                CoverageMap(executedLines: [Self.file: [10]], source: "t", mappedLines: [Self.file: [10, 11]])
            } else {
                CoverageMap(executedLines: [Self.file: [12]], source: "t", mappedLines: [Self.file: [12]])
            }
        })

        #expect(map.mappedLines == [Self.file: [10, 11, 12]])
    }
}
