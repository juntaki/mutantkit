import Foundation
import MutationModel

/// Produces the unified diff stored as a mutant's evidence.
///
/// Two things make this simpler than a general diff: the change is always one
/// contiguous byte splice, and we are told exactly where it is. So there is no
/// LCS and no heuristic — the hunk is computed directly from the range, which
/// means the diff is exact by construction rather than a plausible
/// reconstruction of what changed.
///
/// This diff is not decoration. It is the artifact a reviewer reads to decide
/// whether a surviving mutant is worth acting on, and the evidence that proves
/// the mutation reached the source at all.
public enum SourceDiff {
    private static let newline = UInt8(ascii: "\n")

    public static func unified(
        before: Data,
        after: Data,
        changedRange: ByteRange,
        path: String,
        contextLines: Int = 3
    ) -> String {
        let beforeBytes = [UInt8](before)
        let afterBytes = [UInt8](after)

        guard changedRange.end <= beforeBytes.count else { return "" }

        // The whole-file length delta equals this splice's delta, since it is
        // the only edit.
        let delta = afterBytes.count - beforeBytes.count

        let hunkStart = lineStart(in: beforeBytes, at: changedRange.start)
        let hunkEnd = lineEnd(in: beforeBytes, at: changedRange.end)

        let contextStart = expandBackwards(in: beforeBytes, from: hunkStart, lines: contextLines)
        let contextEnd = expandForwards(in: beforeBytes, from: hunkEnd, lines: contextLines)

        guard hunkEnd + delta <= afterBytes.count, hunkStart <= hunkEnd else { return "" }

        let leading = splitLines(beforeBytes[contextStart ..< hunkStart])
        let removed = splitLines(beforeBytes[hunkStart ..< hunkEnd])
        let added = splitLines(afterBytes[hunkStart ..< (hunkEnd + delta)])
        let trailing = splitLines(beforeBytes[hunkEnd ..< contextEnd])

        // Everything before contextStart is byte-identical in both files, so one
        // count serves for both sides.
        let startLine = countNewlines(in: beforeBytes[0 ..< contextStart]) + 1

        var output = ["--- a/\(path)", "+++ b/\(path)"]
        output.append(
            "@@ -\(startLine),\(leading.count + removed.count + trailing.count) " +
                "+\(startLine),\(leading.count + added.count + trailing.count) @@"
        )
        output.append(contentsOf: leading.map { " \($0)" })
        output.append(contentsOf: removed.map { "-\($0)" })
        output.append(contentsOf: added.map { "+\($0)" })
        output.append(contentsOf: trailing.map { " \($0)" })

        return output.joined(separator: "\n") + "\n"
    }

    // MARK: - Byte scanning

    private static func lineStart(in bytes: [UInt8], at offset: Int) -> Int {
        var index = min(offset, bytes.count)
        while index > 0, bytes[index - 1] != newline { index -= 1 }
        return index
    }

    /// End of the line containing `offset`, including its newline.
    private static func lineEnd(in bytes: [UInt8], at offset: Int) -> Int {
        var index = min(offset, bytes.count)
        while index < bytes.count, bytes[index] != newline { index += 1 }
        return index < bytes.count ? index + 1 : index
    }

    private static func expandBackwards(in bytes: [UInt8], from offset: Int, lines: Int) -> Int {
        var index = offset
        for _ in 0 ..< lines where index > 0 {
            index = lineStart(in: bytes, at: index - 1)
        }
        return index
    }

    private static func expandForwards(in bytes: [UInt8], from offset: Int, lines: Int) -> Int {
        var index = offset
        for _ in 0 ..< lines where index < bytes.count {
            index = lineEnd(in: bytes, at: index)
        }
        return index
    }

    private static func countNewlines(in slice: ArraySlice<UInt8>) -> Int {
        slice.reduce(0) { $1 == newline ? $0 + 1 : $0 }
    }

    /// Splits on newlines, dropping the empty trailing element a final newline
    /// produces — a diff line is content, not the separator after it.
    private static func splitLines(_ slice: ArraySlice<UInt8>) -> [String] {
        guard !slice.isEmpty else { return [] }
        var lines = String(decoding: slice, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
