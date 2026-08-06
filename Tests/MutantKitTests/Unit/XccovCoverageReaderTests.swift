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
}
