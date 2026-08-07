@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// The reader is the only place a coverage claim enters the system, so it is
/// the only place a fabricated claim can be laundered into a `noCoverage`
/// verdict. The cases here are the shapes the parser has to survive: a typical
/// export, an export with segments unhelpfully sorted, an export with paths
/// that are not under the project root, and a directory that contains nothing
/// useful at all.
@Suite("Source coverage reader")
struct SourceCoverageReaderTests {
    private let projectRoot = URL(fileURLWithPath: "/Users/demo/project")

    // MARK: - parse

    @Test("Parses executed segments into a coverage map keyed by relative path")
    func parsesExecutedSegments() throws {
        let json = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/Foo.swift",
             segments: [
                 [1, 1, 1, true, true, false], // region entry, count 1
                 [3, 1, 3, true, true, false], // region entry, count 3
                 [5, 1, 0, true, true, false] // region entry, count 0
             ])
        ])

        let parsed = try #require(SourceCoverageReader.parse(json, projectRoot: projectRoot))

        let lines = try #require(parsed["Sources/Foo.swift"])
        // Region [1,3): lines 1,2 covered (count 1). Region [3,5): lines 3,4
        // covered (count 3). Region [5,...) uncovered (count 0).
        #expect(lines == [1, 2, 3, 4])
        #expect(!lines.contains(5))
    }

    /// Files outside the project root are silently dropped. The plan only
    /// describes repository-relative paths, so an absolute path the project
    /// root cannot relativise has no honest answer the map could give.
    @Test("Files outside the project root are dropped")
    func filesOutsideProjectRootAreDropped() throws {
        let json = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/Inside.swift",
             segments: [[1, 1, 1, true, true, false]]),
            (path: "/Users/other/project/Sources/Outside.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])

        let parsed = try #require(SourceCoverageReader.parse(json, projectRoot: projectRoot))

        #expect(parsed["Sources/Inside.swift"] == [1])
        #expect(parsed["Sources/Outside.swift"] == nil)
    }

    /// Multiple modules' coverage for the same file (e.g. when tests in two
    /// targets both reach it) merge into one entry.
    @Test("Coverage for the same file from multiple modules merges")
    func multipleModulesMerge() throws {
        let file = Self.makeFile(
            path: "/Users/demo/project/Sources/Foo.swift",
            segments: [[1, 1, 1, true, true, false]]
        )
        let otherFile = Self.makeFile(
            path: "/Users/demo/project/Sources/Foo.swift",
            segments: [[5, 1, 2, true, true, false]]
        )

        let document = """
        {
          "version": "2.0.1",
          "type": "llvm.coverage.json.export",
          "data": [
            \(Self.modulePayload(files: [file])),
            \(Self.modulePayload(files: [otherFile]))
          ]
        }
        """

        let parsed = try #require(SourceCoverageReader.parse(
            Data(document.utf8), projectRoot: projectRoot
        ))

        // Each module has one file with one segment. No inter-segment
        // expansion occurs because within each module there is only one
        // segment — so its own line is the only covered one. The merge
        // unions the two.
        #expect(parsed["Sources/Foo.swift"] == [1, 5])
    }

    @Test("Segments with zero count do not mark their line executed")
    func zeroCountSegmentsAreNotExecuted() throws {
        let json = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/Foo.swift",
             segments: [
                 [1, 1, 0, true, true, false],
                 [3, 1, 0, true, true, false]
             ])
        ])

        // All segments have count 0, so no lines are executed.
        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("An empty data array yields nil")
    func emptyDataYieldsNil() {
        let json = Data("""
        {"version":"2.0.1","type":"llvm.coverage.json.export","data":[]}
        """.utf8)

        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("Malformed JSON yields nil rather than throwing")
    func malformedJSONYieldsNil() {
        let json = Data("not json".utf8)
        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("A file with no segments is omitted")
    func fileWithoutSegmentsIsOmitted() throws {
        let fileNoSegs = """
        {
          "filename": "/Users/demo/project/Sources/Empty.swift",
          "summary": {"lines":{"count":0,"covered":0,"percent":0}}
        }
        """
        let json = Self.makeExport(rawFiles: [fileNoSegs])

        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    /// A function body that spans multiple lines between its entry and exit
    /// segments must have every interior line counted as executed, not just
    /// the entry line. This is the specific bug the acceptance test caught:
    /// `qualifiesForSeniorRate` at line 15 with body on line 16 was being
    /// misclassified as noCoverage.
    @Test("A region covers every line from its start to the next region")
    func regionSpansMultipleLines() throws {
        let segments: [[Any]] = [
            [10, 5, 5, true, true, false], // region entry, count 5, open brace
            [15, 1, 0, false, false, false] // region end, closing brace
        ]
        let lines = SourceCoverageReader.executedLines(from: segments)
        #expect(lines == Set(10 ..< 15))
    }

    @Test("A gap region is excluded even if the next segment is an entry")
    func gapRegionIsExcluded() throws {
        let segments: [[Any]] = [
            [10, 5, 1, true, true, false], // code region, count 1
            [12, 1, 0, true, true, true], // gap region (e.g. between functions)
            [15, 5, 2, true, true, false] // next code region
        ]
        let lines = SourceCoverageReader.executedLines(from: segments)
        // Region [10,12): lines 10,11. Gap at 12-14 excluded. Region [15,...): line 15.
        #expect(lines == [10, 11, 15])
    }

    @Test("The last region extends to its own line only")
    func lastRegionIsSingleLine() throws {
        let segments: [[Any]] = [
            [10, 5, 3, true, true, false]
        ]
        let lines = SourceCoverageReader.executedLines(from: segments)
        #expect(lines == [10])
    }

    @Test("Empty segments produce empty output")
    func emptySegments() {
        #expect(SourceCoverageReader.executedLines(from: []).isEmpty)
    }

    // MARK: - relativePath

    @Test("relativePath strips the project root")
    func relativePathStripsRoot() {
        let relative = SourceCoverageReader.relativePath(
            from: "/Users/demo/project/Sources/Foo.swift",
            droppingPrefix: "/Users/demo/project"
        )
        #expect(relative == "Sources/Foo.swift")
    }

    @Test("relativePath handles a trailing slash on the root")
    func relativePathHandlesTrailingSlash() {
        let relative = SourceCoverageReader.relativePath(
            from: "/Users/demo/project/Sources/Foo.swift",
            droppingPrefix: "/Users/demo/project/"
        )
        #expect(relative == "Sources/Foo.swift")
    }

    @Test("relativePath returns nil for a path outside the root")
    func relativePathRejectsOutsidePath() {
        #expect(SourceCoverageReader.relativePath(
            from: "/Users/other/project/Sources/Foo.swift",
            droppingPrefix: "/Users/demo/project"
        ) == nil)
    }

    @Test("relativePath returns nil for the root itself")
    func relativePathRejectsRootItself() {
        #expect(SourceCoverageReader.relativePath(
            from: "/Users/demo/project",
            droppingPrefix: "/Users/demo/project"
        ) == nil)
    }

    // MARK: - read(directory:)

    @Test("read returns nil when the directory has no JSON")
    func readWithoutJSON() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{}".utf8).write(to: dir.appendingPathComponent("not-coverage.json"))

        // A JSON file that does not parse as a coverage export is ignored
        // rather than turning into an empty map.
        #expect(SourceCoverageReader.read(directory: dir, projectRoot: projectRoot) == nil)
    }

    @Test("read returns nil when the directory does not exist")
    func readMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-no-such-\(UUID().uuidString)")

        #expect(SourceCoverageReader.read(directory: missing, projectRoot: projectRoot) == nil)
    }

    @Test("read parses every codecov file in the tree")
    func readParsesMultipleFiles() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonA = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/A.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])
        let jsonB = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/B.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])

        try Data(jsonA).write(to: dir.appendingPathComponent("A-coverage.json"))
        try Data(jsonB).write(to: dir.appendingPathComponent("B-coverage.json"))

        let map = try #require(SourceCoverageReader.read(directory: dir, projectRoot: projectRoot))

        #expect(map.executedLines.keys.sorted() == ["Sources/A.swift", "Sources/B.swift"])
        #expect(map.source == "swift-package-codecov")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-coverage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeExport(files: [(path: String, segments: [[Any]])]) -> Data {
        let rawFiles = files.map { makeFile(path: $0.path, segments: $0.segments) }
        return makeExport(rawFiles: rawFiles)
    }

    private static func makeExport(rawFiles: [String]) -> Data {
        let document = """
        {
          "version": "2.0.1",
          "type": "llvm.coverage.json.export",
          "data": [\(modulePayload(files: rawFiles))]
        }
        """
        return Data(document.utf8)
    }

    private static func modulePayload(files: [String]) -> String {
        """
        {"files":[\(files.joined(separator: ",\n"))]}
        """
    }

    @discardableResult
    private static func makeFile(path: String, segments: [[Any]]) -> String {
        let segJSON = segments.map { segment in
            "[" + segment.map { jsonLiteral(for: $0) }.joined(separator: ",") + "]"
        }.joined(separator: ",")
        return """
        {
          "filename": "\(path)",
          "summary": {"lines":{"count":0,"covered":0,"percent":0}},
          "segments": [\(segJSON)]
        }
        """
    }

    private static func jsonLiteral(for value: Any) -> String {
        if let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? Int { return String(n) }
        return "0"
    }
}
