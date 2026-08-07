import Foundation
import MutationPlanner
import Testing

/// Glob matching is what makes a config file written on a Mac replay identically
/// inside a Linux CI container. It is also what keeps `.build` and `DerivedData`
/// out of a run no matter where they appear in the tree.
///
/// The implementation deliberately avoids `fnmatch` so that the semantics are
/// the same on every platform — and so they can be tested without touching the
/// filesystem.
@Suite("Glob matching")
struct GlobTests {
    // MARK: - `**`

    @Test("`**` matches one nested segment")
    func doubleStarMatchesOneSegment() {
        #expect(Glob.matches(pattern: "Sources/**", path: "Sources/A.swift"))
        #expect(Glob.matches(pattern: "Sources/**", path: "Sources/Foo/A.swift"))
        #expect(Glob.matches(pattern: "Sources/**", path: "Sources/Foo/Bar/A.swift"))
    }

    /// `Sources/**` must not match files in a sibling directory that merely
    /// starts with `Sources`. A loose match here is how unrelated test code
    /// ends up in a run.
    @Test("`**` does not cross into a sibling directory")
    func doubleStarStaysInSubtree() {
        #expect(!Glob.matches(pattern: "Sources/**", path: "SourcesTests/A.swift"))
        #expect(!Glob.matches(pattern: "Sources/**", path: "Other/Sources/A.swift"))
    }

    /// `**` at the start matches every segment — `**/*.swift` is the universal
    /// Swift include. The root has no segment to absorb `**`, and the rule has
    /// to allow that rather than silently dropping top-level files.
    @Test("`**/*.swift` matches a file at the root")
    func doubleStarAtStartMatchesRoot() {
        #expect(Glob.matches(pattern: "**/*.swift", path: "A.swift"))
        #expect(Glob.matches(pattern: "**/*.swift", path: "Sources/A.swift"))
        #expect(Glob.matches(pattern: "**/*.swift", path: "Sources/Nested/A.swift"))
    }

    /// A `**` that is not the whole segment has no special meaning. Treating
    /// `a**b` as `a*.*b` or similar would be a different rule from every editor
    /// and `.gitignore` people already know.
    @Test("An embedded `**` behaves as a single `*`")
    func embeddedDoubleStarIsSingleStar() {
        #expect(Glob.matches(pattern: "a**b", path: "aXXb"))
        // `*` never crosses `/`, so neither does an embedded `**`.
        #expect(!Glob.matches(pattern: "a**b", path: "a/X/b"))
    }

    // MARK: - `*` and `?`

    @Test("`*` matches within a segment but never crosses `/`")
    func starStaysWithinSegment() {
        #expect(Glob.matches(pattern: "*.swift", path: "A.swift"))
        #expect(Glob.matches(pattern: "*.swift", path: "Foo.swift"))
        #expect(!Glob.matches(pattern: "*.swift", path: "Nested/A.swift"))
    }

    @Test("`?` matches exactly one character")
    func questionMarkMatchesOneCharacter() {
        #expect(Glob.matches(pattern: "A?B.swift", path: "AXB.swift"))
        #expect(!Glob.matches(pattern: "A?B.swift", path: "AB.swift"))
        #expect(!Glob.matches(pattern: "A?B.swift", path: "AXXB.swift"))
        #expect(!Glob.matches(pattern: "A?B.swift", path: "A/B.swift"))
    }

    @Test("Trailing `*` matches any suffix in the same segment")
    func trailingStarMatchesSuffix() {
        #expect(Glob.matches(pattern: "Foo*", path: "FooBar"))
        #expect(Glob.matches(pattern: "Foo*", path: "Foo"))
        #expect(!Glob.matches(pattern: "Foo*", path: "Bar/Foo"))
    }

    @Test("A literal pattern matches only itself")
    func literalMatchIsExact() {
        #expect(Glob.matches(pattern: "Sources/Foo.swift", path: "Sources/Foo.swift"))
        #expect(!Glob.matches(pattern: "Sources/Foo.swift", path: "Sources/Bar.swift"))
    }

    // MARK: - matchesAny / ancestors

    /// Naming a directory in `exclude` covers everything beneath it. Forcing a
    /// trailing `/**` onto every entry would be the difference between a config
    /// file a user can write and one they cannot.
    @Test("matchesAny treats a directory pattern as covering its descendants")
    func matchesAnyCoversAncestors() {
        // The path is buried under `Tests`, and `exclude: ["Tests"]` should drop
        // it without needing `Tests/**`.
        #expect(Glob.matchesAny(patterns: ["Tests"], path: "Tests/Fixtures/Foo.swift"))
        #expect(Glob.matchesAny(patterns: ["Sources/Generated"], path: "Sources/Generated/Foo.swift"))
        #expect(Glob.matchesAny(patterns: ["Sources/Generated"], path: "Sources/Generated/Deep/Foo.swift"))
    }

    @Test("matchesAny returns false when no pattern matches the path or any ancestor")
    func matchesAnyRejectsUnrelatedPath() {
        #expect(!Glob.matchesAny(patterns: ["Tests"], path: "Sources/Foo.swift"))
        #expect(!Glob.matchesAny(patterns: [], path: "Sources/Foo.swift"))
    }

    @Test("ancestors lists every containing directory, outermost first")
    func ancestorsAreOutermostFirst() {
        #expect(Glob.ancestors(of: "a/b/c.swift") == ["a", "a/b"])
        #expect(Glob.ancestors(of: "a.swift").isEmpty)
        #expect(Glob.ancestors(of: "a/b.swift") == ["a"])
    }

    // MARK: - Cases that distinguish this matcher from fnmatch

    /// A literal `**` followed by a `.swift` is the universal Swift pattern.
    /// Written as `**` it crosses any depth; written as `*` it would not, and a
    /// single-character typo in a config file would silently scope the whole run
    /// to the repository root only.
    @Test("`**` and `*` produce different matches on the same input")
    func doubleAndSingleStarDiffer() {
        let path = "Sources/Foo/Bar.swift"
        #expect(Glob.matches(pattern: "**/*.swift", path: path))
        #expect(!Glob.matches(pattern: "*", path: path))
    }
}
