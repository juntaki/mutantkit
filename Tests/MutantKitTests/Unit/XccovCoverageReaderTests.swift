@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// `xccov view --archive --json`'s schema, confirmed empirically against a
/// real `.xcresult` bundle built from a toy package: one flat array per
/// file, each entry either non-executable (blank lines, braces — no
/// `executionCount` key at all) or executable with a count. This suite pins
/// that shape so the reader does not silently start guessing what the JSON
/// means if Xcode ever changes it.
@Suite("Xccov coverage reader")
struct XccovCoverageReaderTests {
    private let projectRoot = URL(fileURLWithPath: "/Users/demo/project")

    @Test("A covered, executable line is counted; a zero-count one is not")
    func executedLinesAreCounted() throws {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": true, "executionCount": 1},
            {"line": 2, "isExecutable": true, "executionCount": 0},
            {"line": 3, "isExecutable": false}
          ]
        }
        """.utf8)

        let parsed = try #require(XccovCoverageReader.parse(json, projectRoot: projectRoot))

        #expect(parsed["Sources/Foo.swift"] == [1])
    }

    @Test("A non-executable line (no executionCount key) is never covered")
    func nonExecutableLinesAreIgnored() throws {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": false},
            {"line": 2, "isExecutable": false}
          ]
        }
        """.utf8)

        #expect(XccovCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("Files outside the project root are dropped")
    func filesOutsideProjectRootAreDropped() throws {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Inside.swift": [
            {"line": 1, "isExecutable": true, "executionCount": 1}
          ],
          "/Users/other/project/Sources/Outside.swift": [
            {"line": 1, "isExecutable": true, "executionCount": 1}
          ]
        }
        """.utf8)

        let parsed = try #require(XccovCoverageReader.parse(json, projectRoot: projectRoot))

        #expect(parsed["Sources/Inside.swift"] == [1])
        #expect(parsed["Sources/Outside.swift"] == nil)
    }

    @Test("Malformed JSON yields nil rather than throwing")
    func malformedJSONYieldsNil() {
        #expect(XccovCoverageReader.parse(Data("not json".utf8), projectRoot: projectRoot) == nil)
    }

    @Test("An empty document yields nil")
    func emptyDocumentYieldsNil() {
        #expect(XccovCoverageReader.parse(Data("{}".utf8), projectRoot: projectRoot) == nil)
    }

    @Test("read returns nil when the bundle does not exist")
    func readMissingBundleReturnsNil() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-no-such-\(UUID().uuidString).xcresult")

        let map = await XccovCoverageReader.read(archive: missing, projectRoot: projectRoot)
        #expect(map == nil)
    }

    // MARK: - All-or-nothing malformed-entry handling

    @Test("An executable line missing executionCount fails the whole document closed")
    func executableLineMissingExecutionCountFailsClosed() {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": true}
          ]
        }
        """.utf8)

        #expect(XccovCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("An executable line with a wrong-typed executionCount fails the whole document closed")
    func executableLineWrongTypedExecutionCountFailsClosed() {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": true, "executionCount": "1"}
          ]
        }
        """.utf8)

        #expect(XccovCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("A missing or wrong-typed line number fails the whole document closed")
    func missingOrWrongTypedLineFailsClosed() {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"isExecutable": true, "executionCount": 1}
          ]
        }
        """.utf8)

        #expect(XccovCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("A missing or wrong-typed isExecutable fails the whole document closed")
    func missingOrWrongTypedIsExecutableFailsClosed() {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": "true", "executionCount": 1}
          ]
        }
        """.utf8)

        #expect(XccovCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("A non-executable line with no executionCount at all is a legitimate exclusion, not malformation")
    func nonExecutableLineWithNoExecutionCountIsLegitimate() throws {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": true, "executionCount": 1},
            {"line": 2, "isExecutable": false}
          ]
        }
        """.utf8)

        let parsed = try #require(XccovCoverageReader.parse(json, projectRoot: projectRoot))
        #expect(parsed["Sources/Foo.swift"] == [1])
    }

    @Test("One valid covered line alongside one malformed executable line yields nil, not a partial map")
    func oneValidLineAlongsideOneMalformedLineYieldsNilNotPartial() {
        let json = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": true, "executionCount": 1},
            {"line": 2, "isExecutable": true}
          ]
        }
        """.utf8)

        #expect(XccovCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("read fails closed when the subprocess output was not fully captured")
    func readFailsClosedOnIncompleteOutput() async {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xccov-\(UUID().uuidString).xcresult")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let validJSON = Data("""
        {
          "/Users/demo/project/Sources/Foo.swift": [
            {"line": 1, "isExecutable": true, "executionCount": 1}
          ]
        }
        """.utf8)

        let map = await XccovCoverageReader.read(
            archive: bundle, projectRoot: projectRoot,
            processRunner: { _, _, _, _ in
                ProcessResult(
                    exitCode: 0, standardOutput: validJSON, standardError: Data(), durationSeconds: 0.1,
                    timedOut: false, terminatingSignal: nil, outputComplete: false
                )
            }
        )

        #expect(
            map == nil,
            "even a well-formed, fully-covered document must be discarded when outputComplete is false"
        )
    }
}
