import Foundation
import MutationExecution

/// Reads LLVM source-based code coverage export JSON into a `CoverageMap`.
///
/// `swift test --enable-code-coverage` (and `xcrun llvm-cov export` against a
/// `.profdata`) emits one or more JSON files in this format. The schema is
/// documented at
/// https://github.com/llvm/llvm-project/blob/main/llvm/tools/llvm-cov/CoverageExporterJson.cpp
/// and is what both SwiftPM and Xcode produce, so one reader handles both.
///
/// The reader does not run `swift test` or `llvm-cov` — text in, data out. The
/// adapter that owns the build decides when to invoke it, which keeps the
/// reader testable without a toolchain on disk.
public enum SourceCoverageReader {
    /// Parses every coverage JSON file in `directory`, normalised against
    /// `projectRoot`.
    ///
    /// Complete-or-nil against genuine malformation, never against a file
    /// that legitimately parsed to zero lines: if any file in `directory`
    /// cannot be read, does not parse as a coverage document at all, or
    /// contains a segment that fails `executedLines`, the whole result is
    /// `nil` — never a map unioned only from the files that happened to
    /// succeed. A directory containing a genuine coverage export alongside
    /// an unrelated or corrupted file has no honest partial answer — this
    /// directory is `SourceCoverageReader`'s own dedicated input (SwiftPM
    /// writes nothing else to `codecov/`), so every `*.json` found here is
    /// expected to be a real export, and one that isn't is evidence
    /// something is wrong, not evidence to quietly skip.
    ///
    /// That is a different fact from "this one file's own coverage happened
    /// to be empty" — a real export for an untested target/module, where
    /// nothing under `projectRoot` was executed, is not malformed at all
    /// (codex review: an earlier version of this method conflated the two,
    /// via `parse`'s own nil-means-either-one public contract, and one
    /// legitimately-empty export among several would silently discard every
    /// other file's real coverage too). `parseOutcome` keeps that
    /// distinction available internally; only `.malformed` fails the whole
    /// read, `.parsed` (even an empty one) always contributes.
    ///
    /// - Returns: `nil` when no coverage files were found, every file's
    ///   coverage was legitimately empty, or any one file was unreadable or
    ///   malformed. The caller treats `nil` as "no coverage information",
    ///   which is different from "the project has zero coverage": missing or
    ///   corrupted data is missing data, not a measurement.
    public static func read(directory: URL, projectRoot: URL) -> CoverageMap? {
        let files = codecovFiles(in: directory)
        guard !files.isEmpty else { return nil }

        var executed: [String: Set<Int>] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file) else { return nil }
            switch parseOutcome(data, projectRoot: projectRoot) {
            case .malformed:
                return nil
            case let .parsed(parsed):
                for (path, lines) in parsed {
                    executed[path, default: []].formUnion(lines)
                }
            }
        }

        guard !executed.isEmpty else { return nil }
        return CoverageMap(executedLines: executed, source: "swift-package-codecov")
    }

    /// Parses a single JSON document. Exposed for tests so a fixture file can
    /// drive the reader without a directory walk.
    ///
    /// A thin wrapper over `parseOutcome` that collapses `.malformed` and a
    /// legitimately-empty `.parsed([:])` into the same `nil` — the public
    /// contract this method has always had ("no coverage information",
    /// either because there was none to find or because reading it failed).
    /// `read(directory:)` needs the finer distinction `parseOutcome` keeps,
    /// specifically so a legitimately-empty file among several doesn't
    /// discard the others' real coverage; a single standalone document has
    /// no "others" to protect, so collapsing the two here is the same
    /// behavior this method has always documented.
    public static func parse(_ data: Data, projectRoot: URL) -> [String: Set<Int>]? {
        switch parseOutcome(data, projectRoot: projectRoot) {
        case .malformed:
            return nil
        case let .parsed(executed):
            return executed.isEmpty ? nil : executed
        }
    }

    /// One coverage JSON document's own parse result, distinguishing
    /// genuine malformation from a validly-parsed (possibly empty) result —
    /// see `read(directory:)`'s own doc comment for why that distinction
    /// matters to a multi-file merge, and `parse`'s for why the public API
    /// collapses it.
    enum ParseOutcome: Equatable {
        case malformed
        case parsed([String: Set<Int>])
    }

    /// Complete-or-nil (well, complete-or-`.malformed`) within one document:
    /// any structural element an LLVM detailed export always emits, but this
    /// document does not, invalidates the whole document — not just that one
    /// element's own entry. A mutation runner that silently dropped one
    /// covered file's real lines because its structure happened to be
    /// malformed would misreport those lines as uncovered
    /// (`CoverageMap.isKnownUncovered` treats "file present, line absent" as
    /// known-uncovered), which can fast-path a mutant on that line straight
    /// to `noCoverage` without ever building or testing it — the same
    /// false-negative class P12-B Finding D closed for per-test attribution.
    ///
    /// Fails closed on (all per independent review, verified against LLVM's
    /// own exporter, `llvm/tools/llvm-cov/CoverageExporterJson.cpp`):
    /// - a top-level `type` other than `"llvm.coverage.json.export"`;
    /// - a `filename` missing or wrong-typed for any file entry;
    /// - a `segments` key missing or wrong-typed for a file entry *inside*
    ///   `projectRoot` — a full/detailed export always includes this key for
    ///   every in-scope file (even as `[]`, when the file genuinely has no
    ///   regions); its absence is the shape `--summary-only` output takes,
    ///   meaning detailed coverage was never captured at all, not that this
    ///   file has zero coverage. A file entry *outside* `projectRoot` is
    ///   unaffected either way — its own `segments` shape is never inspected,
    ///   since `relativePath` already excludes it before this check runs,
    ///   the same intentional exclusion as always (unrelated to evidence
    ///   corruption).
    /// - a segment with a malformed field, including out-of-range `line`/
    ///   `column`/`count` or `(line, column)` pairs that regress backwards
    ///   across the segment list — LLVM's own exporter always emits segments
    ///   in ascending `(line, column)` order per file, and `executedLines`'s
    ///   own per-line grouping assumes that order (see `executedLines`'s
    ///   own doc comment).
    ///
    /// An empty `segments: []` array remains legitimate — a file genuinely
    /// contributing no regions, not corrupted data — and, like a file
    /// outside `projectRoot`, is skipped rather than failing the document.
    static func parseOutcome(_ data: Data, projectRoot: URL) -> ParseOutcome {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["type"] as? String == "llvm.coverage.json.export",
              let export = document["data"] as? [[String: Any]] else { return .malformed }

        let rootPath = projectRoot.standardizedFileURL.path
        var executed: [String: Set<Int>] = [:]

        for module in export {
            // A well-formed llvm-cov export always has a `files` array for
            // every module entry (even an empty one, `[]`) -- a module
            // missing this key entirely, or with the wrong type, is not "a
            // module with nothing to report," it is a malformed document
            // (codex review: `{"data":[{}]}` previously read as a valid,
            // empty export and could silently drop a sibling module's real
            // coverage for a file this malformed one also covered).
            guard let files = module["files"] as? [[String: Any]] else { return .malformed }
            for file in files {
                // A well-formed export always names every file entry --
                // missing/wrong-typed is malformed, not "nothing to
                // report for an unnamed file" (there is no honest path
                // string to even consider skipping by).
                guard let absolutePath = file["filename"] as? String else { return .malformed }
                guard let relativePath = Self.relativePath(
                    from: absolutePath, droppingPrefix: rootPath
                ) else { continue }
                // Only reached for a file *inside* projectRoot -- see this
                // method's own doc comment for why a missing/wrong-typed
                // `segments` here (unlike a merely-empty `[]`) is malformed.
                guard let segments = file["segments"] as? [[Any]] else { return .malformed }

                guard let lines = Self.executedLines(from: segments) else { return .malformed }
                guard !lines.isEmpty else { continue }
                executed[relativePath, default: []].formUnion(lines)
            }
        }

        return .parsed(executed)
    }

    /// One `[line, column, count, hasCount, isRegionEntry, isGapRegion]`
    /// segment from an LLVM source-based coverage export — see
    /// https://github.com/llvm/llvm-project/blob/main/llvm/include/llvm/ProfileData/Coverage/CoverageMapping.h,
    /// `struct CoverageSegment`. `isGapRegion` is absent in older export
    /// versions (the 5-element variant); defaults to `false`, matching LLVM's
    /// own `IsGapRegion` default. `column` is stored (not just parsed and
    /// discarded) purely so `executedLines` can validate real `(line,
    /// column)` ordering across the segment list — LLVM's own algorithm
    /// never uses it within one line's own stats computation.
    struct CoverageSegmentRecord {
        let line: Int
        let column: Int
        let count: Int
        let hasCount: Bool
        let isRegionEntry: Bool
        let isGapRegion: Bool
    }

    /// Translates coverage segments into the set of lines that were executed.
    ///
    /// A direct Swift port of LLVM's own `LineCoverageIterator`/
    /// `LineCoverageStats` (`llvm/lib/ProfileData/Coverage/CoverageMapping.cpp`)
    /// — not an independently-derived approximation. An earlier version of
    /// this reader tracked a single "currently open region" and closed it at
    /// the next segment's line, which drops any line whose own coverage comes
    /// not from a region *entry* but from an still-active region *carried
    /// forward* across a non-entry boundary segment (confirmed live: a
    /// same-line early return, and separately, the line immediately after a
    /// nested `if`-branch closes and control returns to the enclosing
    /// region's own count — both real, both silently misclassified as
    /// uncovered by the old single-open-region model). LLVM's real algorithm
    /// instead evaluates coverage per source line, carrying forward the last
    /// region-entry segment (`WrappedSegment`) across lines with no entry
    /// segment of their own, exactly reproduced below.
    ///
    /// - Returns: `nil` when a segment array element is missing a required
    ///   field, has the wrong type for one that is present, has an
    ///   out-of-range `line`/`column`/`count` (LLVM's own coordinates are
    ///   1-based; a non-negative count only), or regresses the `(line,
    ///   column)` ordering LLVM's own exporter always emits segments in —
    ///   genuinely malformed data, distinct from an empty `segments` array
    ///   (which is a legitimate "nothing here" and yields `[]`, not `nil`).
    static func executedLines(from segments: [[Any]]) -> Set<Int>? {
        var records: [CoverageSegmentRecord] = []
        records.reserveCapacity(segments.count)
        for segment in segments {
            guard let line = segment[safe: 0] as? Int,
                  let column = segment[safe: 1] as? Int,
                  let count = segment[safe: 2] as? Int,
                  let hasCount = segment[safe: 3] as? Bool,
                  let isRegionEntry = segment[safe: 4] as? Bool,
                  line >= 1, column >= 1, count >= 0 else { return nil }
            // `isGapRegion` (index 5) is the one field genuinely absent in
            // older, still-supported exports, not merely malformed when
            // missing — defaults to `false` only when the element itself is
            // absent; a present-but-wrong-typed value still fails closed.
            let isGapRegion: Bool
            if segment.indices.contains(5) {
                guard let value = segment[safe: 5] as? Bool else { return nil }
                isGapRegion = value
            } else {
                isGapRegion = false
            }
            // LLVM's exporter always emits one file's segments in ascending
            // `(line, column)` order; `LineCoverageIterator`'s own per-line
            // grouping (below) assumes it. A regression means either a
            // corrupted export or an input this reader's ordering
            // assumption does not hold for -- fail closed rather than
            // silently mis-groups segments into the wrong line.
            if let previous = records.last,
               (line, column) < (previous.line, previous.column) {
                return nil
            }
            records.append(CoverageSegmentRecord(
                line: line, column: column, count: count, hasCount: hasCount,
                isRegionEntry: isRegionEntry, isGapRegion: isGapRegion
            ))
        }
        guard let firstLine = records.first?.line, let lastLine = records.last?.line else { return [] }

        var executed = Set<Int>()
        var wrapped: CoverageSegmentRecord?
        var index = 0
        var line = firstLine
        while line <= lastLine {
            var lineSegments: [CoverageSegmentRecord] = []
            while index < records.count, records[index].line == line {
                lineSegments.append(records[index])
                index += 1
            }

            let stats = Self.lineCoverageStats(lineSegments: lineSegments, wrapped: wrapped)
            if stats.mapped, stats.executionCount > 0 {
                executed.insert(line)
            }

            if let last = lineSegments.last {
                wrapped = last
            }
            line += 1
        }

        return executed
    }

    /// `!isGapRegion && hasCount && isRegionEntry` — LLVM's own
    /// `isStartOfRegion` lambda, verbatim.
    private static func isStartOfRegion(_ segment: CoverageSegmentRecord) -> Bool {
        !segment.isGapRegion && segment.hasCount && segment.isRegionEntry
    }

    private struct LineStats {
        let mapped: Bool
        let executionCount: Int
    }

    /// A direct port of `LineCoverageStats::LineCoverageStats` — same
    /// variable names, same order, same early exits, so a future upstream
    /// change is a mechanical diff to re-apply rather than a re-derivation.
    private static func lineCoverageStats(
        lineSegments: [CoverageSegmentRecord],
        wrapped: CoverageSegmentRecord?
    ) -> LineStats {
        // Find the minimum number of regions which start on this line.
        var minRegionCount = 0
        for segment in lineSegments {
            guard minRegionCount < 2 else { break }
            if isStartOfRegion(segment) { minRegionCount += 1 }
        }

        let startOfSkippedRegion = lineSegments.first.map { !$0.hasCount && $0.isRegionEntry } ?? false

        var mapped = !startOfSkippedRegion && ((wrapped?.hasCount ?? false) || minRegionCount > 0)
        // If there is any starting segment at this line with a counter, it
        // must be mapped.
        mapped = mapped || lineSegments.contains { $0.isRegionEntry && $0.hasCount }

        guard mapped else { return LineStats(mapped: false, executionCount: 0) }

        // Pick the max count from the non-gap, region entry segments and the
        // wrapped count.
        var executionCount = wrapped?.count ?? 0
        guard minRegionCount > 0 else { return LineStats(mapped: true, executionCount: executionCount) }
        for segment in lineSegments where isStartOfRegion(segment) {
            executionCount = max(executionCount, segment.count)
        }
        return LineStats(mapped: true, executionCount: executionCount)
    }

    /// Walks `directory` for coverage JSON files.
    ///
    /// SwiftPM drops them at `.build/<arch>/<build>/codecov/*.json`. Xcode can
    /// export to a directory of the user's choosing. The reader looks for any
    /// `*.json` whose contents parse as a coverage export, so the layout does
    /// not have to match either tool exactly.
    static func codecovFiles(in directory: URL) -> [URL] {
        let resolver = directory.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: resolver,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            found.append(url)
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Strips the project-root prefix from an absolute coverage path, or
    /// returns `nil` when the path is not under the project root.
    ///
    /// Coverage data uses absolute paths because that is what the instrumented
    /// binary recorded at build time. The plan uses repository-relative paths,
    /// so the comparison only works if every absolute path is normalised back
    /// to the same shape. A path that is not under the project root is silently
    /// dropped: it points at something outside the tree the plan covers, and
    /// claiming coverage for it would be a fabrication.
    ///
    /// Both sides are resolved through `realpath` because macOS reports the
    /// system temporary directory as `/var/folders/...` while the kernel
    /// resolves the same path through `/private/var/folders/...`. Coverage
    /// files carry the latter; the runner's `projectRoot` carries the former.
    /// A literal prefix match would drop every file under the sandbox.
    static func relativePath(from absolutePath: String, droppingPrefix rootPath: String) -> String? {
        let normalizedRoot = realpath(rootPath)?.standardizingTrailingSlash
            ?? rootPath.standardizingTrailingSlash
        let normalizedAbsolute = realpath(absolutePath)?.standardizingTrailingSlash
            ?? absolutePath.standardizingTrailingSlash

        guard normalizedAbsolute.hasPrefix(normalizedRoot + "/") else { return nil }
        let relative = String(normalizedAbsolute.dropFirst(normalizedRoot.count + 1))
        return relative.isEmpty ? nil : relative
    }
}

/// Resolves a path through `realpath(3)`, returning `nil` when the path does
/// not exist on disk. The coverage data may contain paths that have already
/// been cleaned up (the sandbox is destroyed before the runner parses them),
/// so failure here is a fallback rather than an error.
private func realpath(_ path: String) -> String? {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    // `resolvingSymlinksInPath()` will return a path even if the file does not
    // exist, which is not what we want here — a stale path should fall back to
    // the original string rather than silently substitute a different one.
    guard fm.fileExists(atPath: url.path) else { return nil }
    return url.path
}

private extension String {
    /// Drops exactly one trailing slash, if present. Does not collapse runs of
    /// them, and does not touch a lone "/".
    var standardizingTrailingSlash: String {
        hasSuffix("/") && count > 1 ? String(dropLast()) : self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
