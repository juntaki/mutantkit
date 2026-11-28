import Foundation
import MutationModel

/// Glob matching for source include/exclude patterns.
///
/// Deliberately not `fnmatch`: matching has to behave identically for a config
/// written on a developer's Mac and replayed inside a Linux CI container, and it
/// has to be testable without a filesystem.
public enum Glob {
    /// Matches `pattern` against a repository-relative, `/`-separated path.
    ///
    /// - `**` matches zero or more whole path segments, and only when it is the
    ///   entire segment. `Sources/**` therefore matches `Sources/A.swift` and
    ///   `Sources/A/B.swift`, and `**/*.swift` matches `A.swift` at the root.
    /// - `*` matches any run of characters within one segment, never `/`.
    /// - `?` matches exactly one character within one segment, never `/`.
    ///
    /// A `**` embedded in a larger segment (`a**b`) has no special meaning and
    /// behaves as `*`.
    public static func matches(pattern: String, path: String) -> Bool {
        let patternSegments = segments(of: pattern)
        let pathSegments = segments(of: path)
        return match(patternSegments, 0, pathSegments, 0)
    }

    /// Every directory path containing `path`, outermost first.
    ///
    /// `a/b/c.swift` yields `["a", "a/b"]`.
    public static func ancestors(of path: String) -> [String] {
        let parts = segments(of: path)
        guard parts.count > 1 else { return [] }
        return (1 ..< parts.count).map { parts[0 ..< $0].joined(separator: "/") }
    }

    /// True if any pattern matches the path itself or any directory above it.
    ///
    /// The ancestor rule is what makes `exclude: ["Tests"]` and
    /// `exclude: ["Sources/Generated"]` mean what everyone who has written a
    /// `.gitignore` expects: naming a directory covers everything inside it,
    /// without forcing a trailing `/**` onto every entry.
    public static func matchesAny(patterns: [String], path: String) -> Bool {
        for pattern in patterns {
            if matches(pattern: pattern, path: path) { return true }
            for ancestor in ancestors(of: path) where matches(pattern: pattern, path: ancestor) {
                return true
            }
        }
        return false
    }

    /// Whether some path beneath `directory` could match `pattern` (or be
    /// covered by it as an ancestor). False means no file under the directory
    /// can ever be selected, so it need not be listed.
    public static func canMatchBeneath(pattern: String, directory: String) -> Bool {
        let patternSegments = segments(of: pattern)
        for (index, segment) in segments(of: directory).enumerated() {
            guard index < patternSegments.count else { return true }
            if patternSegments[index] == "**" { return true }
            if !matchSegment(pattern: patternSegments[index], text: segment) { return false }
        }
        return true
    }

    private static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func match(_ pattern: [String], _ pi: Int, _ path: [String], _ si: Int) -> Bool {
        if pi == pattern.count { return si == path.count }

        if pattern[pi] == "**" {
            for consumed in si ... path.count where match(pattern, pi + 1, path, consumed) {
                return true
            }
            return false
        }

        guard si < path.count, matchSegment(pattern: pattern[pi], text: path[si]) else { return false }
        return match(pattern, pi + 1, path, si + 1)
    }

    /// Wildcard match within one segment, backtracking on `*`.
    private static func matchSegment(pattern: String, text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var lastStar = -1
        var resumeAt = 0

        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                lastStar = pi
                resumeAt = ti
                pi += 1
            } else if lastStar >= 0 {
                resumeAt += 1
                ti = resumeAt
                pi = lastStar + 1
            } else {
                return false
            }
        }

        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
