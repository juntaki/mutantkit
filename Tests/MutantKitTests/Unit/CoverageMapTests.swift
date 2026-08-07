import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// A coverage map is the only thing standing between "the tests passed" and
/// "the tests passed for a reason". The classifier's `.noCoverage` branch is
/// dead until one of these is supplied, so the rules here are the rules that
/// govern whether a mutant enters the effective-score denominator.
@Suite("Coverage map")
struct CoverageMapTests {
    @Test("A file and line in the executed set is observed as executed")
    func executedLineIsObserved() {
        let map = CoverageMap(
            executedLines: ["Sources/Foo.swift": [10, 11, 12]],
            source: "test"
        )

        let observation = map.observation(forFile: "Sources/Foo.swift", line: 10)

        #expect(observation?.mutatedLineWasExecuted == true)
        #expect(observation?.source == "test")
    }

    /// The load-bearing case. A line absent from the executed set means the
    /// suite never reached it; a mutant on that line is `.noCoverage`.
    @Test("A file present but a line absent is observed as not executed")
    func unexecutedLineIsObserved() {
        let map = CoverageMap(
            executedLines: ["Sources/Foo.swift": [10]],
            source: "test"
        )

        let observation = map.observation(forFile: "Sources/Foo.swift", line: 99)

        #expect(observation?.mutatedLineWasExecuted == false)
        #expect(observation?.source == "test")
    }

    /// Missing data is not "no coverage". A file the map has no record of
    /// might simply not have been instrumented, or might live outside the
    /// project root. Either way the only honest answer is "no claim", which
    /// the classifier turns into "fall through to the normal verdict".
    @Test("A file absent from the map yields no observation")
    func absentFileYieldsNoObservation() {
        let map = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "test")

        #expect(map.observation(forFile: "Sources/Other.swift", line: 1) == nil)
    }

    @Test("An empty map reports as empty")
    func emptyMapIsEmpty() {
        let map = CoverageMap(executedLines: [:], source: "test")
        #expect(map.isEmpty)
        #expect(map.observation(forFile: "any", line: 1) == nil)
    }

    @Test("isKnownUncovered is false when the file is absent")
    func knownUncoveredIsFalseForAbsentFile() throws {
        let point = try Self.point(line: 5)
        let map = CoverageMap(executedLines: ["Sources/Other.swift": [1]], source: "test")

        #expect(!map.isKnownUncovered(point))
    }

    @Test("isKnownUncovered is false when the line was executed")
    func knownUncoveredIsFalseForExecutedLine() throws {
        let point = try Self.point(line: 5)
        let map = CoverageMap(
            executedLines: [point.file: [point.line]],
            source: "test"
        )

        #expect(!map.isKnownUncovered(point))
    }

    @Test("isKnownUncovered is true when the file is present but the line is absent")
    func knownUncoveredIsTrueForUnexecutedLine() throws {
        let point = try Self.point(line: 5)
        let map = CoverageMap(
            executedLines: [point.file: [1, 2, 3]],
            source: "test"
        )

        #expect(map.isKnownUncovered(point))
    }

    @Test("filesCovered counts the keys")
    func filesCovered() {
        let map = CoverageMap(
            executedLines: [
                "Sources/A.swift": [1],
                "Sources/B.swift": [2]
            ],
            source: "test"
        )

        #expect(map.filesCovered == 2)
    }

    // MARK: - Helpers

    /// A real anchored point on the given line. Discovery returns line 2; the
    /// line is overridden because the cover map's lookup is per-line and the
    /// test needs control over that one field.
    private static func point(line: Int) throws -> MutationPoint {
        let source = """
        struct Q {
            var enabled = true
        }
        """
        let discovered = try discover(source, path: "Sources/Q.swift", using: Operators.boolLiteral)[0]
        return discovered.with(line: line)
    }
}

private extension MutationPoint {
    func with(line: Int) -> MutationPoint {
        MutationPoint(
            id: id,
            file: file,
            enclosingDeclaration: enclosingDeclaration,
            operatorID: operatorID,
            operatorVersion: operatorVersion,
            occurrenceIndex: occurrenceIndex,
            utf8Range: utf8Range,
            originalText: originalText,
            replacementText: replacementText,
            prefixTokenFingerprint: prefixTokenFingerprint,
            suffixTokenFingerprint: suffixTokenFingerprint,
            sourceFileHash: sourceFileHash,
            expectedSyntaxKind: expectedSyntaxKind,
            confidence: confidence,
            executionMode: executionMode,
            line: line,
            column: column
        )
    }
}
