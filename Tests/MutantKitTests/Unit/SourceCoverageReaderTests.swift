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
                 [3, 1, 3, true, true, false] // region entry, count 3
             ])
        ])

        let parsed = try #require(SourceCoverageReader.parse(json, projectRoot: projectRoot))

        let lines = try #require(parsed["Sources/Foo.swift"])
        // Region starting line 1 (count 1) carries through line 2 up to the
        // next entry; region starting line 3 (count 3) has no closing
        // segment here, so (per LLVM's own LineCoverageStats) it carries its
        // count forward indefinitely -- this fixture only asserts lines 1-3.
        #expect(lines.isSuperset(of: [1, 2, 3]))
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

    /// A file inside `projectRoot` with no `segments` key at all is the
    /// shape `--summary-only` output takes -- detailed coverage was never
    /// captured for it, not "this file has zero coverage" (independent
    /// review, verified against LLVM's own exporter). A full/detailed
    /// export always includes `segments` for every in-scope file, even as
    /// `[]` when the file genuinely has no regions (see
    /// `emptySegmentsArrayIsSkipped` below for that legitimate case). This
    /// one document's own coverage is therefore untrustworthy as a whole,
    /// not merely missing this one file's own contribution.
    @Test("A project file missing its own segments key fails the whole parse")
    func fileWithoutSegmentsKeyFailsClosed() throws {
        let fileNoSegs = """
        {
          "filename": "/Users/demo/project/Sources/Empty.swift",
          "summary": {"lines":{"count":0,"covered":0,"percent":0}}
        }
        """
        let json = Self.makeExport(rawFiles: [fileNoSegs])

        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("read fails the whole directory when a project file is missing its segments key")
    func readFailsWholeOnFileMissingSegmentsKey() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonWithCoverage = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/A.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])
        let fileNoSegs = """
        {
          "filename": "/Users/demo/project/Sources/Empty.swift",
          "summary": {"lines":{"count":0,"covered":0,"percent":0}}
        }
        """
        let jsonMissingSegmentsKey = Self.makeExport(rawFiles: [fileNoSegs])

        try Data(jsonWithCoverage).write(to: dir.appendingPathComponent("A-coverage.json"))
        try Data(jsonMissingSegmentsKey).write(to: dir.appendingPathComponent("B-coverage.json"))

        #expect(SourceCoverageReader.read(directory: dir, projectRoot: projectRoot) == nil)
    }

    /// A file with a genuinely-empty `segments` array (structurally valid,
    /// legitimately nothing to report) is skipped — distinct from a file
    /// missing the `segments` key entirely just above, which fails the whole
    /// document instead.
    @Test("A file with an empty segments array is skipped, not a failure")
    func emptySegmentsArrayIsSkipped() throws {
        let json = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/Empty.swift", segments: []),
            (path: "/Users/demo/project/Sources/Foo.swift", segments: [[1, 1, 1, true, true, false]])
        ])

        let parsed = try #require(SourceCoverageReader.parse(json, projectRoot: projectRoot))
        #expect(parsed["Sources/Empty.swift"] == nil)
        #expect(parsed["Sources/Foo.swift"] == [1])
    }

    /// A malformed segment in one file invalidates the whole document, not
    /// just that one file's own entry -- complete-or-nil, the same principle
    /// `read(directory:)` follows across multiple files (see its own test
    /// below). Silently dropping only the malformed file's real coverage
    /// would misreport its lines as uncovered rather than unknown, which can
    /// fast-path a mutant on one of them straight to `noCoverage`.
    @Test("A malformed segment in one file fails the whole parse, not just that file")
    func malformedSegmentInOneFileFailsWholeParse() throws {
        let json = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/Good.swift", segments: [[1, 1, 1, true, true, false]]),
            (path: "/Users/demo/project/Sources/Bad.swift", segments: [[2]])
        ])

        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
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

    /// Complete-or-nil across files, not just within one: a corrupted
    /// sibling coverage file must never leave the *other* file's real
    /// coverage standing in as if it were the whole, trustworthy picture --
    /// `Sources/A.swift`'s own genuine coverage must not quietly become the
    /// entire map when `B-coverage.json` failed to parse.
    @Test("read returns nil (not a partial map) when any codecov file fails to parse")
    func readFailsWholeOnAnyCorruptedFile() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonA = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/A.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])

        try Data(jsonA).write(to: dir.appendingPathComponent("A-coverage.json"))
        try Data("not json at all".utf8).write(to: dir.appendingPathComponent("B-coverage.json"))

        #expect(SourceCoverageReader.read(directory: dir, projectRoot: projectRoot) == nil)
    }

    /// The exact gap an independent (codex) review caught: a genuinely
    /// malformed file must not discard the whole directory's coverage, but
    /// neither may a *validly-parsed, legitimately-empty* one -- a real
    /// export for an untested module has nothing to say, which is not the
    /// same fact as "this file could not be trusted." An earlier version of
    /// this fix conflated the two through `parse`'s own public
    /// nil-means-either contract, so a package where even one coverage file
    /// happened to cover nothing would silently lose every other file's real
    /// coverage too.
    @Test("read still returns the real coverage when one codecov file legitimately covers nothing")
    func readSurvivesALegitimatelyEmptyFile() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonWithCoverage = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/A.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])
        // A real, validly-shaped export whose only segment has count 0 --
        // e.g. an untested module -- parses fine and legitimately
        // contributes nothing.
        let jsonLegitimatelyEmpty = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/Untested.swift",
             segments: [[1, 1, 0, true, true, false]])
        ])

        try Data(jsonWithCoverage).write(to: dir.appendingPathComponent("A-coverage.json"))
        try Data(jsonLegitimatelyEmpty).write(to: dir.appendingPathComponent("B-coverage.json"))

        let map = try #require(SourceCoverageReader.read(directory: dir, projectRoot: projectRoot))
        #expect(map.executedLines["Sources/A.swift"] == [1])
    }

    /// A second gap the same codex review found: a module entry missing its
    /// own `files` key entirely (`{"data":[{}]}`) previously read as "a
    /// module with nothing to report" via the same `continue` every
    /// legitimate omission uses, silently downgrading real malformation to
    /// an empty-but-valid result -- which `read(directory:)` would then
    /// treat as `.parsed([:])` and keep merging a *sibling* file's real
    /// coverage into, exactly the partial-map risk this whole fix exists to
    /// close.
    @Test("A module missing its own files array fails the whole parse")
    func moduleWithoutFilesArrayFailsClosed() {
        let json = Data("""
        {"version":"2.0.1","type":"llvm.coverage.json.export","data":[{}]}
        """.utf8)

        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
    }

    @Test("read fails the whole directory when one file has a module missing its files array")
    func readFailsWholeOnModuleMissingFilesArray() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonWithCoverage = Self.makeExport(files: [
            (path: "/Users/demo/project/Sources/A.swift",
             segments: [[1, 1, 1, true, true, false]])
        ])
        let jsonMalformedModule = Data("""
        {"version":"2.0.1","type":"llvm.coverage.json.export","data":[{}]}
        """.utf8)

        try Data(jsonWithCoverage).write(to: dir.appendingPathComponent("A-coverage.json"))
        try jsonMalformedModule.write(to: dir.appendingPathComponent("B-coverage.json"))

        #expect(SourceCoverageReader.read(directory: dir, projectRoot: projectRoot) == nil)
    }

    /// A well-formed export always names every file entry -- unlike a file
    /// legitimately outside `projectRoot` (which has a real, honest
    /// filename this reader simply isn't interested in), a file with no
    /// `filename` at all offers no honest path to even consider skipping
    /// by, and is malformed rather than "nothing to report."
    @Test("A file entry missing its own filename fails the whole parse")
    func fileWithoutFilenameFailsClosed() throws {
        let fileNoFilename = """
        {
          "summary": {"lines":{"count":0,"covered":0,"percent":0}},
          "segments": [[1, 1, 1, true, true, false]]
        }
        """
        let json = Self.makeExport(rawFiles: [fileNoFilename])

        #expect(SourceCoverageReader.parse(json, projectRoot: projectRoot) == nil)
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

/// `executedLines` on its own, at the segment level -- split from
/// `SourceCoverageReaderTests` above (which covers `parse`/`read`/
/// `relativePath`) purely to keep each suite's own type body under this
/// codebase's own `type_body_length` lint threshold; no behavioral
/// distinction between the two files.
///
/// A direct Swift port of LLVM's own `LineCoverageStats`
/// (`llvm/lib/ProfileData/Coverage/CoverageMapping.cpp`), verified against
/// that source, not independently re-derived — see
/// `SourceCoverageReader.executedLines`'s own doc comment for why an
/// earlier, single-open-region model of this reader silently dropped real
/// coverage in two distinct shapes.
@Suite("Source coverage reader: executedLines")
struct SourceCoverageReaderExecutedLinesTests {
    /// A function body that spans multiple lines between its entry and exit
    /// segments must have every interior line counted as executed, not just
    /// the entry line. This is the specific bug the acceptance test caught:
    /// `qualifiesForSeniorRate` at line 15 with body on line 16 was being
    /// misclassified as noCoverage. Line 15 (the closing boundary itself) is
    /// also covered: LLVM's own `LineCoverageStats` carries the enclosing
    /// region's count forward across a non-entry boundary segment, so
    /// control genuinely passing through the closing line (e.g. a `}`) is
    /// reported as executed too, not excluded the way an earlier,
    /// hand-rolled version of this reader excluded it.
    @Test("A region covers every line from its start through its closing boundary")
    func regionSpansMultipleLines() throws {
        let segments: [[Any]] = [
            [10, 5, 5, true, true, false], // region entry, count 5, open brace
            [15, 1, 0, false, false, false] // region end, closing brace
        ]
        let lines = try #require(SourceCoverageReader.executedLines(from: segments))
        #expect(lines == Set(10 ... 15))
    }

    /// A direct LLVM `LineCoverageStats` port, not an independently-derived
    /// exclusion rule: LLVM's own "mapped" test does not gate on
    /// `!isGapRegion` the way `isStartOfRegion`'s region-count/max-count
    /// logic does, so a gap region's own start line can still be reported
    /// mapped (carrying the *preceding* region's count forward), while the
    /// lines strictly between the gap's start and the next real region stay
    /// unmapped. Confirmed against LLVM's real algorithm, not assumed.
    @Test("A gap region carries the preceding count on its own start line, but not past it")
    func gapRegionIsExcluded() throws {
        let segments: [[Any]] = [
            [10, 5, 1, true, true, false], // code region, count 1
            [12, 1, 0, true, true, true], // gap region (e.g. between functions)
            [15, 5, 2, true, true, false] // next code region
        ]
        let lines = try #require(SourceCoverageReader.executedLines(from: segments))
        #expect(lines == [10, 11, 12, 15])
        #expect(!lines.contains(13))
        #expect(!lines.contains(14))
    }

    @Test("The last region extends to its own line only")
    func lastRegionIsSingleLine() throws {
        let segments: [[Any]] = [
            [10, 5, 3, true, true, false]
        ]
        let lines = try #require(SourceCoverageReader.executedLines(from: segments))
        #expect(lines == [10])
    }

    /// A region that opens *and closes* on the same line — a single-line
    /// early return or a one-statement branch body is exactly this shape —
    /// must still count that line as executed. The half-open
    /// `start.line ..< line` range used to close a region collapses to
    /// empty when the closing segment sits on the identical line (a later
    /// column, not tracked here), so the region's own only line was
    /// silently dropped.
    ///
    /// Traced (not just theorized) to a real correctness gap, not merely a
    /// cosmetic line-attribution quirk: `MutationRunner`'s
    /// `coverage.isKnownUncovered(point)` fast path skips building and
    /// testing a mutant entirely — reporting it `noCoverage` — whenever its
    /// line is absent from this map, with no fallback that would catch a
    /// wrongly-dropped-but-genuinely-executed line. A mutation planted on a
    /// single-statement branch body shaped like this would be silently
    /// skipped even though the suite really did execute it, exactly the
    /// "mutation is never run" failure mode P12's own trust invariants
    /// treat as unacceptable.
    ///
    /// First observed (and deliberately worked around, not fixed) during
    /// P12-B: `SwiftPackageMacOSSwiftTestingSelectionAcceptanceTests` chose
    /// line 24 over the fixture's own line 26 (`bulkDiscountRate`'s
    /// single-statement `return 0.0` branch) specifically because line 26
    /// exhibits this.
    @Test("A region that opens and closes on the same line still counts that line")
    func sameLineRegionIsNotDropped() throws {
        let segments: [[Any]] = [
            [10, 5, 5, true, true, false], // enclosing region entry, count 5
            [26, 9, 3, true, true, false], // single-line region entry (e.g. `return 0.0`), count 3
            [26, 20, 5, false, false, false], // closing boundary, SAME line, not a region entry
            [30, 1, 0, false, false, false] // next boundary, further down
        ]
        let lines = try #require(SourceCoverageReader.executedLines(from: segments))
        #expect(lines.contains(26), "line 26's region opened and closed on the same line, but was dropped")
        // The enclosing and following regions are unaffected by the fix.
        #expect(lines.isSuperset(of: 10 ..< 26))
        #expect(!lines.contains(30))
    }

    /// The exact raw segment sequence captured live from a real
    /// `swift test --enable-code-coverage --filter bulkDiscountRoughly`
    /// run against `Fixtures/SwiftPackageMacOS`'s `Pricing.swift`
    /// (`.build/.../codecov/Pricing.json`) — not a hand-simplified
    /// approximation. Line 26 (`bulkDiscountRate`'s `return 0.0`, reachable
    /// only when `itemCount <= 10`) is a *second*, structurally different
    /// dropped-line shape from `sameLineRegionIsNotDropped` above: the
    /// enclosing `if`-branch's own count=1 region (opened at line 23,col27)
    /// closes at line 25 via a *new* region entry (not a same-line
    /// collapse), and line 26's own segment (`[26,19,2,...]`) is not a
    /// region entry at all — it only carries the count already active from
    /// line 25's own region forward. The single-open-region model this
    /// reader used before this fix had no way to represent "control
    /// re-enters an enclosing count after a nested region closes without a
    /// fresh entry", and dropped line 26 entirely (not merely misattributed
    /// it) — confirmed by reverting this fix and rerunning this exact test.
    @Test("Pricing.swift's real raw segments mark bulkDiscountRate's line 26 executed")
    func realBulkDiscountRateSegmentsCoverLine26() throws {
        let segments: [[Any]] = [
            [22, 67, 2, true, true, false],
            [23, 12, 2, true, true, false],
            [23, 26, 2, true, false, false],
            [23, 27, 1, true, true, false],
            [25, 10, 1, true, true, false],
            [26, 19, 2, true, false, false],
            [27, 6, 0, false, false, false]
        ]
        let lines = try #require(SourceCoverageReader.executedLines(from: segments))
        #expect(lines.contains(26), "line 26 was dropped from real, live-captured coverage segments")
        #expect(lines.contains(24), "line 24 (the itemCount>10 branch) should still be covered")
    }

    @Test("Empty segments produce empty output")
    func emptySegments() throws {
        let lines = try #require(SourceCoverageReader.executedLines(from: []))
        #expect(lines.isEmpty)
    }

    @Test("A segment missing a required field fails closed, not silently skipped")
    func malformedSegmentFailsClosed() {
        let segments: [[Any]] = [
            [10, 5, 5, true, true, false],
            [12] // missing count/hasCount/isRegionEntry entirely
        ]
        #expect(SourceCoverageReader.executedLines(from: segments) == nil)
    }

    @Test("A segment with a wrong-typed required field fails closed")
    func wrongTypedFieldFailsClosed() {
        let segments: [[Any]] = [
            [10, 5, "not-a-count", true, true, false]
        ]
        #expect(SourceCoverageReader.executedLines(from: segments) == nil)
    }

    @Test("A missing isGapRegion (5-element, older export) still defaults to false")
    func missingIsGapRegionDefaultsFalse() throws {
        let segments: [[Any]] = [
            [10, 5, 3, true, true]
        ]
        let lines = try #require(SourceCoverageReader.executedLines(from: segments))
        #expect(lines == [10])
    }

    @Test("A present but wrong-typed isGapRegion fails closed, not defaulted")
    func wrongTypedGapRegionFailsClosed() {
        let segments: [[Any]] = [
            [10, 5, 3, true, true, "not-a-bool"]
        ]
        #expect(SourceCoverageReader.executedLines(from: segments) == nil)
    }

    /// `column` (segment index 1) is a required field this reader stores
    /// purely to validate real `(line, column)` ordering -- a wrong-typed
    /// value fails closed the same as any other malformed required field.
    @Test("A segment with a wrong-typed column fails closed")
    func wrongTypedColumnFailsClosed() {
        let segments: [[Any]] = [
            [10, "not-a-column", 3, true, true, false]
        ]
        #expect(SourceCoverageReader.executedLines(from: segments) == nil)
    }

    /// LLVM's own exporter always emits one file's segments in ascending
    /// `(line, column)` order; a regression -- here, a second segment whose
    /// line is *before* the first segment's -- means either a corrupted
    /// export or an input this reader's own per-line grouping cannot trust,
    /// and fails closed rather than silently mis-grouping segments into the
    /// wrong line.
    @Test("Segments out of (line, column) order fail closed")
    func outOfOrderSegmentsFailClosed() {
        let segments: [[Any]] = [
            [15, 1, 2, true, true, false],
            [10, 1, 1, true, true, false] // regresses backwards from line 15
        ]
        #expect(SourceCoverageReader.executedLines(from: segments) == nil)
    }
}
