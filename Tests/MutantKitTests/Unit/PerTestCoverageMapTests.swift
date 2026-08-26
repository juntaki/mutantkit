import Foundation
import MutationExecution
import Testing

/// `PerTestCoverageMap` only ever narrows a mutant's test invocation, never
/// widens or substitutes it — the cases here pin the two ways a caller must
/// be able to tell "no attribution" apart from "these tests, and only
/// these", since conflating them would either run nothing (a false pass) or
/// fall back to the full suite more often than necessary (safe, but not the
/// speedup this type exists for).
@Suite("Per-test coverage map")
struct PerTestCoverageMapTests {
    private let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
    private let subTest = TestIdentifier(target: "FooTests", qualifiedName: "SubTests/testSub")

    @Test("A known site returns exactly the tests that covered it")
    func knownSiteReturnsCoveringTests() {
        let map = PerTestCoverageMap(
            coveringTests: ["Sources/Foo.swift": [1: [addTest]]],
            source: "test"
        )

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest])
    }

    @Test("A line no test reached is present but empty, not confused with an unknown file")
    func uncoveredLineIsDistinctFromUnknownFile() {
        let map = PerTestCoverageMap(
            coveringTests: ["Sources/Foo.swift": [1: [addTest]]],
            source: "test"
        )

        #expect(map.testsCovering(file: "Sources/Other.swift", line: 1) == nil)
    }

    @Test("Two tests covering the same line are both returned")
    func multipleTestsCoveringSameLine() {
        let map = PerTestCoverageMap(
            coveringTests: ["Sources/Foo.swift": [1: [addTest, subTest]]],
            source: "test"
        )

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest, subTest])
    }

    @Test("aggregate() is the union of every covered line, independent of which test covered it")
    func aggregateIsTheUnionOfLines() {
        let map = PerTestCoverageMap(
            coveringTests: [
                "Sources/Foo.swift": [1: [addTest], 2: [subTest]],
                "Sources/Bar.swift": [10: [addTest]]
            ],
            source: "xcodebuild-xccov-per-test"
        )

        let aggregate = map.aggregate()

        #expect(aggregate.executedLines["Sources/Foo.swift"] == [1, 2])
        #expect(aggregate.executedLines["Sources/Bar.swift"] == [10])
        #expect(aggregate.source == "xcodebuild-xccov-per-test")
    }

    @Test("onlyTestingArgument joins target and qualified name with a slash, and appends the trailing ()")
    func onlyTestingArgumentShape() {
        // Phase C13: the trailing `()` is required for `xcodebuild` to
        // match a Swift Testing `@Test` function via `-only-testing:` at
        // all (confirmed by direct reproduction: omitting it silently
        // matches zero tests) -- XCTest tolerates it either way, so it is
        // always appended rather than only for one framework's shape.
        #expect(addTest.onlyTestingArgument == "FooTests/AddTests/testAdd()")
    }

    @Test("An empty map is empty")
    func emptyMapIsEmpty() {
        #expect(PerTestCoverageMap(coveringTests: [:], source: "test").isEmpty)
    }
}
