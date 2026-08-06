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
    /// - Returns: `nil` when no coverage files were found or every file failed
    ///   to parse. The caller treats `nil` as "no coverage information", which
    ///   is different from "the project has zero coverage": a missing file is
    ///   missing data, not a measurement.
    public static func read(directory: URL, projectRoot: URL) -> CoverageMap? {
        let files = codecovFiles(in: directory)
        guard !files.isEmpty else { return nil }

        var executed: [String: Set<Int>] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let parsed = parse(data, projectRoot: projectRoot) else { continue }
            for (path, lines) in parsed {
                executed[path, default: []].formUnion(lines)
            }
        }

        guard !executed.isEmpty else { return nil }
        return CoverageMap(executedLines: executed, source: "swift-package-codecov")
    }

    /// Parses a single JSON document. Exposed for tests so a fixture file can
    /// drive the reader without a directory walk.
    public static func parse(_ data: Data, projectRoot: URL) -> [String: Set<Int>]? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let export = document["data"] as? [[String: Any]] else { return nil }

        let rootPath = projectRoot.standardizedFileURL.path
        var executed: [String: Set<Int>] = [:]

        for module in export {
            guard let files = module["files"] as? [[String: Any]] else { continue }
            for file in files {
                guard let absolutePath = file["filename"] as? String else { continue }
                guard let relativePath = Self.relativePath(
                    from: absolutePath, droppingPrefix: rootPath
                ) else { continue }
                guard let segments = file["segments"] as? [[Any]] else { continue }

                let lines = Self.executedLines(from: segments)
                guard !lines.isEmpty else { continue }
                executed[relativePath, default: []].formUnion(lines)
            }
        }

        return executed.isEmpty ? nil : executed
    }

    /// Translates coverage segments into the set of lines that were executed.
    ///
    /// A segment is `[line, column, count, hasCount, isRegionEntry, isGap]` in
    /// the LLVM Source-based Code Coverage export. A *region* begins at a
    /// segment with `isRegionEntry == true` and `isGap == false`, and extends
    /// to the position of the next segment (or end-of-file for the last one).
    /// A region whose `count > 0` was executed, so every line within its span
    /// is marked covered.
    ///
    /// The 5-element variant (without `isGap`) is also handled: the sixth
    /// element is absent in older export versions.
    static func executedLines(from segments: [[Any]]) -> Set<Int> {
        // Walk segments in order. When a region entry with count > 0 appears,
        // all lines from its line to the next segment's line are covered. The
        // next segment can be anything — another entry, a gap, or a plain
        // boundary marker with `isRegionEntry == false`.
        var lines = Set<Int>()
        var open: (line: Int, count: Int)?

        for segment in segments {
            guard let line = segment[safe: 0] as? Int else { continue }
            let count = segment[safe: 2] as? Int ?? 0
            let isRegionEntry = segment[safe: 4] as? Bool ?? false

            // Close the currently-open region at this segment's line.
            if let start = open {
                if start.count > 0 {
                    for l in start.line ..< line { lines.insert(l) }
                }
                open = nil
            }

            // Open a new region only when this segment marks the entry.
            // Gap regions (isGap == true) are never opened — they have no
            // code to cover.
            if isRegionEntry {
                let isGap = segment[safe: 5] as? Bool ?? false
                if !isGap {
                    open = (line, count)
                }
            }
        }

        // The last open region extends to its own line only — there is no
        // next segment to define its end.
        if let start = open, start.count > 0 {
            lines.insert(start.line)
        }

        return lines
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
