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

/// Finds the `.swift` files a plan should consider.
///
/// Returns repository-relative, `/`-separated paths, sorted — the same tree
/// always produces the same list in the same order, which is the first link in
/// the chain that makes a plan reproducible.
public struct SourceFileWalker: Sendable {
    /// Directories never descended into, whatever the config says.
    ///
    /// These hold build products and vendored code. Mutating them is meaningless
    /// at best; walking them is minutes of I/O on a large checkout. Both are
    /// good enough reasons to make this decision unconfigurable.
    public static let prunedDirectoryNames: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage"
    ]

    private let root: URL
    private let settings: SourceSettings

    public init(root: URL, settings: SourceSettings) {
        self.root = root.standardizedFileURL
        self.settings = settings
    }

    /// Walks the tree. Sorted, relative, deterministic.
    public func walk() throws -> [String] {
        var found: [String] = []
        var pending: [(url: URL, relativePath: String)] = [(root, "")]

        while let directory = pending.popLast() {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
            } catch {
                // The root not existing is the user's problem to hear about; a
                // directory that vanished mid-walk is not worth failing a run.
                if directory.relativePath.isEmpty {
                    throw PlannerError.unreadableDirectory(
                        path: directory.url.path,
                        detail: error.localizedDescription
                    )
                }
                continue
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

                // Symlinks are skipped rather than resolved: a link pointing at
                // an ancestor turns the walk into an infinite loop, and a link
                // pointing outside the repo produces a path that no relative
                // anchor can describe.
                if values?.isSymbolicLink == true { continue }

                let name = entry.lastPathComponent
                let relativePath = directory.relativePath.isEmpty ? name : directory.relativePath + "/" + name

                if values?.isDirectory == true {
                    guard !Self.prunedDirectoryNames.contains(name) else { continue }
                    // Pruning an excluded directory is safe because exclusion
                    // covers everything beneath it, so nothing here could have
                    // survived the per-file check anyway.
                    guard !isExcluded(relativePath) else { continue }
                    pending.append((entry, relativePath))
                    continue
                }

                guard name.hasSuffix(".swift") else { continue }
                guard isIncluded(relativePath), !isExcluded(relativePath) else { continue }
                found.append(relativePath)
            }
        }

        return found.sorted()
    }

    /// Whether a relative path would be planned, without touching the disk.
    public func admits(relativePath: String) -> Bool {
        isIncluded(relativePath) && !isExcluded(relativePath)
    }

    private func isIncluded(_ path: String) -> Bool {
        Glob.matchesAny(patterns: settings.include, path: path)
    }

    private func isExcluded(_ path: String) -> Bool {
        Glob.matchesAny(patterns: settings.exclude, path: path)
    }
}
