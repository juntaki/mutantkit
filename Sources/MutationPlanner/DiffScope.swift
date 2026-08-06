import Foundation
import MutationModel

/// The lines a diff touched, and the rule for deciding whether a mutation is in
/// scope for a pull-request run.
///
/// This type never runs `git`. The caller resolves a base ref into changed lines
/// and injects the result, which keeps the planner free of subprocesses, keeps
/// scope decisions testable without a repository on disk, and lets a CI system
/// that already knows the diff hand it over instead of paying for it twice.
public struct DiffScope: Sendable, Hashable {
    /// Changed line ranges per repository-relative path, 1-based, half-open.
    /// Normalized on construction: sorted and overlap-merged.
    public let changedLines: [String: [Range<Int>]]

    public init(changedLines: [String: [Range<Int>]]) {
        self.changedLines = changedLines.compactMapValues { ranges in
            let merged = Self.normalize(ranges)
            return merged.isEmpty ? nil : merged
        }
    }

    public var isEmpty: Bool { changedLines.isEmpty }

    public var changedFiles: [String] { changedLines.keys.sorted() }

    /// Whether a 1-based line of a file was touched.
    public func contains(file: String, line: Int) -> Bool {
        guard let ranges = changedLines[file] else { return false }
        return ranges.contains { $0.contains(line) }
    }

    /// Splits points into those the diff touched and those it did not.
    ///
    /// A mutation is in scope when its line falls inside a changed range of its
    /// own file. `line` is display-only everywhere else in the tool — it is not
    /// an anchor and it shifts — but scoping is itself a display-level judgement
    /// about which code a reviewer is looking at, so a shifted line costs
    /// nothing worse than a mutant included or excluded at the edge of a hunk.
    public func split(_ points: [MutationPoint]) -> (inScope: [MutationPoint], outOfScope: [MutationPoint]) {
        var inScope: [MutationPoint] = []
        var outOfScope: [MutationPoint] = []
        for point in points {
            if contains(file: point.file, line: point.line) {
                inScope.append(point)
            } else {
                outOfScope.append(point)
            }
        }
        return (inScope, outOfScope)
    }

    private static func normalize(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

// MARK: - Unified diff

public extension DiffScope {
    /// Parses `git diff --unified=0` output into a scope.
    ///
    /// Text in, data out — no subprocess. The caller decides how the diff was
    /// produced; this only reads the post-image side, because a mutation can
    /// only be planned against lines that still exist.
    static func parse(unifiedDiff text: String) -> DiffScope {
        var changed: [String: [Range<Int>]] = [:]
        var currentFile: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                // `/dev/null` on the post-image side means the file was deleted;
                // there is nothing left to mutate.
                currentFile = path == "/dev/null" ? nil : strippedPrefix(of: path)
                continue
            }

            guard line.hasPrefix("@@"), let file = currentFile else { continue }
            guard let hunk = postImageRange(ofHunkHeader: String(line)) else { continue }
            changed[file, default: []].append(hunk)
        }

        return DiffScope(changedLines: changed)
    }

    /// Strips git's `a/` or `b/` path prefix, and quoting if present.
    private static func strippedPrefix(of path: String) -> String {
        var value = path
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        // A tab separates the path from a timestamp in some diff dialects.
        if let tab = value.firstIndex(of: "\t") { value = String(value[value.startIndex ..< tab]) }
        for prefix in ["a/", "b/", "i/", "w/", "c/", "o/"] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    /// Reads `@@ -12,3 +14,5 @@` and returns `14..<19`.
    private static func postImageRange(ofHunkHeader header: String) -> Range<Int>? {
        let fields = header.split(separator: " ")
        guard let post = fields.first(where: { $0.hasPrefix("+") }) else { return nil }

        let numbers = post.dropFirst().split(separator: ",")
        guard let start = Int(numbers[0]) else { return nil }
        // An omitted count means one line; a count of zero means the hunk only
        // deleted lines, so no post-image line was touched.
        let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
        guard count > 0 else { return nil }
        return start ..< (start + count)
    }
}
