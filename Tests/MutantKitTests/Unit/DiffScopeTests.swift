import Foundation
import MutationModel
import MutationPlanner
import Testing

/// `DiffScope` is the rule for "only mutate what the pull request touched". A
/// mutant outside the scope is still discovered, still counted in `discovered`,
/// and recorded as `outsideDiff` rather than silently dropped — that accounting
/// is the only thing keeping a PR-scoped score honest.
@Suite("Diff scope")
struct DiffScopeTests {
    // MARK: - Construction

    @Test("Changed lines are exposed per file")
    func changedLinesArePerFile() {
        let scope = DiffScope(changedLines: [
            "Sources/Foo.swift": [3 ..< 5, 10 ..< 11],
            "Sources/Bar.swift": [1 ..< 2]
        ])

        #expect(scope.changedFiles == ["Sources/Bar.swift", "Sources/Foo.swift"])
        #expect(!scope.isEmpty)
    }

    @Test("An empty map reports as empty")
    func emptyScopeIsEmpty() {
        #expect(DiffScope(changedLines: [:]).isEmpty)
    }

    /// A file whose only range collapses to zero (a deletion-only hunk) is
    /// dropped: there is nothing on the post-image side to mutate.
    @Test("Empty ranges are normalized away")
    func emptyRangesAreDropped() {
        let scope = DiffScope(changedLines: [
            "Sources/Foo.swift": [5 ..< 5, 1 ..< 2]
        ])

        #expect(scope.changedLines["Sources/Foo.swift"] == [1 ..< 2])
    }

    /// Overlapping and adjacent hunks merge into one, so a mutation just inside
    /// the seam does not depend on how the diff tool happened to carve it up.
    @Test("Overlapping and adjacent ranges are merged")
    func overlappingRangesAreMerged() {
        let scope = DiffScope(changedLines: [
            "Sources/Foo.swift": [1 ..< 4, 3 ..< 6, 10 ..< 12, 12 ..< 14]
        ])

        #expect(scope.changedLines["Sources/Foo.swift"] == [1 ..< 6, 10 ..< 14])
    }

    @Test("contains answers for the file and line it was given")
    func containsIsByFileAndLine() {
        let scope = DiffScope(changedLines: ["Sources/Foo.swift": [10 ..< 12]])

        #expect(scope.contains(file: "Sources/Foo.swift", line: 10))
        #expect(scope.contains(file: "Sources/Foo.swift", line: 11))
        #expect(!scope.contains(file: "Sources/Foo.swift", line: 12))
        #expect(!scope.contains(file: "Sources/Foo.swift", line: 9))
        #expect(!scope.contains(file: "Sources/Other.swift", line: 10))
    }

    // MARK: - split (the rule that feeds `.outsideDiff`)

    /// The split is what the planner turns into `SkippedMutation.reason ==
    /// .outsideDiff`. A point on a touched line stays in scope; a point one
    /// line above the hunk drops out — and never silently.
    @Test("split partitions points by whether their line is in the diff")
    func splitPartitionsByLine() {
        let inScope = Self.point(id: "in", file: "Sources/Foo.swift", line: 10)
        let belowHunk = Self.point(id: "below", file: "Sources/Foo.swift", line: 99)
        let otherFile = Self.point(id: "other", file: "Sources/Bar.swift", line: 1)

        let scope = DiffScope(changedLines: ["Sources/Foo.swift": [10 ..< 12]])
        let (inScopePoints, outOfScope) = scope.split([inScope, belowHunk, otherFile])

        #expect(inScopePoints.map(\.id.rawValue) == ["in"])
        #expect(outOfScope.map(\.id.rawValue) == ["below", "other"])
    }

    /// An empty-but-present scope means "nothing is in scope". The planner's
    /// nil-vs-present distinction is what separates "no diff requested" from
    /// "the diff is empty": the present-but-empty case has to drop everything
    /// rather than silently widening to the whole project.
    @Test("A present-but-empty scope drops every point")
    func emptyButPresentDropsEverything() {
        let a = Self.point(id: "a", file: "Sources/Foo.swift", line: 1)
        let b = Self.point(id: "b", file: "Sources/Bar.swift", line: 2)

        let (kept, dropped) = DiffScope(changedLines: [:]).split([a, b])

        #expect(kept.isEmpty)
        #expect(dropped.count == 2)
    }

    // MARK: - Unified diff parsing

    @Test("Parses git diff --unified=0 into a scope")
    func parsesUnifiedDiff() {
        let diff = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        index 0000000..1111111 100644
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -10,3 +10,5 @@ struct Foo {
         context line
        +added line one
        +added line two
         context line
        @@ -40,1 +42,1 @@ struct Foo {
        -old line
        +new line
        """

        let scope = DiffScope.parse(unifiedDiff: diff)

        #expect(scope.changedFiles == ["Sources/Foo.swift"])
        // First hunk: 5 post-image lines (10..15).
        // Second hunk: 1 post-image line (42..43).
        #expect(scope.changedLines["Sources/Foo.swift"] == [10 ..< 15, 42 ..< 43])
        #expect(scope.contains(file: "Sources/Foo.swift", line: 10))
        #expect(scope.contains(file: "Sources/Foo.swift", line: 14))
        #expect(!scope.contains(file: "Sources/Foo.swift", line: 15))
        #expect(scope.contains(file: "Sources/Foo.swift", line: 42))
    }

    /// `@@ -10,3 +12 @@` with no count means one line. Diff tools do emit this
    /// abbreviation, and reading it as zero would silently drop the line.
    @Test("A hunk header with no count means one line")
    func omittedCountMeansOne() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,2 +5 @@ struct Foo
         context
        +added
        """

        let scope = DiffScope.parse(unifiedDiff: diff)
        #expect(scope.changedLines["Sources/Foo.swift"] == [5 ..< 6])
    }

    /// A count of zero means the hunk only deleted lines; nothing on the
    /// post-image was touched, so there is nothing to mutate.
    @Test("A zero-count hunk contributes nothing")
    func zeroCountHunkContributesNothing() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,1 +5,0 @@ struct Foo
        -removed
        """

        let scope = DiffScope.parse(unifiedDiff: diff)
        #expect(scope.isEmpty)
    }

    @Test("A deleted file contributes nothing")
    func deletedFileContributesNothing() {
        let diff = """
        --- a/Sources/Deleted.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@ struct Deleted
        -line
        -line
        -line
        """

        #expect(DiffScope.parse(unifiedDiff: diff).isEmpty)
    }

    /// The `a/`/`b/` prefixes are stripped. A diff with quoted paths and the
    /// other prefixes git sometimes emits (`c/`, `i/`, `w/`, `o/`) has to be
    /// normalised back to a repository-relative path the plan can use.
    @Test("Path prefixes are stripped, including quoted paths")
    func pathPrefixesAreStripped() {
        let diff = """
        --- "a/Sources/Quote Path.swift"
        +++ "b/Sources/Quote Path.swift"
        @@ -1,1 +1,2 @@ struct Q
         context
        +added
        """

        let scope = DiffScope.parse(unifiedDiff: diff)
        #expect(scope.changedFiles == ["Sources/Quote Path.swift"])
    }

    @Test("A diff with no hunks produces an empty scope")
    func noHunksIsEmpty() {
        #expect(DiffScope.parse(unifiedDiff: "no diff content here\n").isEmpty)
        #expect(DiffScope.parse(unifiedDiff: "").isEmpty)
    }

    // MARK: - Fixtures

    private static func point(id: String, file: String, line: Int) -> MutationPoint {
        let declaration = DeclarationIdentity(path: ["Q", "f()"])
        let mutationID = MutationID(rawValue: id)
        return MutationPoint(
            id: mutationID,
            file: file,
            enclosingDeclaration: declaration,
            operatorID: "swift.core.bool-literal-inversion",
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(start: 0, end: 4),
            originalText: "true",
            replacementText: "false",
            prefixTokenFingerprint: "prefix",
            suffixTokenFingerprint: "suffix",
            sourceFileHash: ContentHash.of(file),
            expectedSyntaxKind: "booleanLiteralExpr",
            confidence: .high,
            executionMode: .isolated,
            line: line,
            column: 1
        )
    }
}
