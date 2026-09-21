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
    func aggregateIsTheUnionOfLines() throws {
        let map = PerTestCoverageMap(
            coveringTests: [
                "Sources/Foo.swift": [1: [addTest], 2: [subTest]],
                "Sources/Bar.swift": [10: [addTest]]
            ],
            source: "xcodebuild-xccov-per-test"
        )

        let aggregate = try #require(map.aggregate())

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

/// A profiling pass that could not prove every test keeps the tests it did
/// measure, and carries the ones it could not. The cases here pin the two
/// halves of why that is safe rather than merely cheaper — a partial map
/// must never narrow a selection below the truth, and must never be able to
/// claim a line is uncovered.
@Suite("Per-test coverage map — partial attribution")
struct PerTestCoverageMapPartialAttributionTests {
    private let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
    private let subTest = TestIdentifier(target: "FooTests", qualifiedName: "SubTests/testSub")
    private let unproven = TestIdentifier(target: "FooTests", qualifiedName: "FlakyTests/testFlaky")

    private func partialMap() -> PerTestCoverageMap {
        PerTestCoverageMap(
            coveringTests: ["Sources/Foo.swift": [1: [addTest], 2: [subTest]]],
            source: "test",
            unattributedTests: [unproven]
        )
    }

    @Test("A map with no unproven tests is complete")
    func completeMapIsComplete() {
        #expect(PerTestCoverageMap(coveringTests: ["Sources/Foo.swift": [1: [addTest]]], source: "test").isComplete)
        #expect(!partialMap().isComplete)
    }

    @Test("Every selection includes the unproven tests, because their coverage is unknown")
    func unprovenTestsJoinEverySelection() {
        let map = partialMap()

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest, unproven])
        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 2) == [subTest, unproven])
    }

    /// The failure this guards against is the whole reason the unproven set
    /// is carried instead of dropped: a line only the unproven test reaches
    /// has no attributed entry, and answering "nobody covers this" there
    /// would run the wrong (narrower) selection and turn a mutant that test
    /// alone would have killed into a false survivor.
    @Test("A line with no attributed test still selects the unproven tests, never an empty or nil selection")
    func unattributedLineStillSelectsTheUnprovenTests() {
        let map = partialMap()

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 99) == [unproven])
        #expect(map.testsCovering(file: "Sources/Never.swift", line: 1) == [unproven])
    }

    /// `aggregate()`'s consumer (`CoverageMap.isKnownUncovered`) asserts a
    /// negative and skips the build and the test run entirely on the
    /// strength of it. An unproven test's unknown coverage is exactly what
    /// can falsify that negative, so a partial map must not be able to
    /// supply one at all.
    @Test("A partial map refuses to answer the whole-suite coverage question")
    func partialMapHasNoAggregate() {
        #expect(partialMap().aggregate() == nil)
        #expect(PerTestCoverageMap(coveringTests: ["Sources/Foo.swift": [1: [addTest]]], source: "test").aggregate() != nil)
    }

    @Test("A partial map round-trips through the on-disk cache form with its unproven set intact")
    func partialMapRoundTripsThroughCoding() throws {
        let decoded = try JSONDecoder().decode(
            PerTestCoverageMap.self, from: try JSONEncoder().encode(partialMap())
        )

        #expect(decoded == partialMap())
        #expect(decoded.unattributedTests == [unproven])
    }

    /// A cache entry with no `unattributedTests` key came from the
    /// all-or-nothing era, where a map was only ever stored if every test had
    /// been proven — so decoding it as complete is that entry's own true
    /// value, not a permissive guess.
    @Test("An entry with no unproven set decodes as complete")
    func entryWithoutUnprovenSetDecodesAsComplete() throws {
        let stored = Data(#"{"tests":[],"coveringTests":{"Sources/Foo.swift":{"1":[]}},"source":"stored"}"#.utf8)

        let decoded = try JSONDecoder().decode(PerTestCoverageMap.self, from: stored)

        #expect(decoded.isComplete)
        #expect(decoded.aggregate() != nil)
    }

    /// The on-disk form writes each identifier once and refers to it by
    /// index everywhere else. Pinned because the obvious encoding — the
    /// identifier inline at every occurrence — produced a 106 MB cache entry
    /// on a real 647-test project, nearly all of it the same few hundred
    /// strings repeated across 976,184 occurrences.
    @Test("Identifiers are written once and referenced by index, not repeated per covered line")
    func identifiersAreInterned() throws {
        let manyLines = Dictionary(
            uniqueKeysWithValues: (1 ... 200).map { ($0, Set([addTest, subTest])) }
        )
        let map = PerTestCoverageMap(coveringTests: ["Sources/Foo.swift": manyLines], source: "test")

        let encoded = try Self.cacheEncoder().encode(map)
        let text = try #require(String(data: encoded, encoding: .utf8))

        // Two identifiers, 400 occurrences: each name may appear only in the
        // table, never once per line.
        #expect(text.components(separatedBy: "AddTests/testAdd").count - 1 == 1)
        #expect(text.components(separatedBy: "SubTests/testSub").count - 1 == 1)
        #expect(try JSONDecoder().decode(PerTestCoverageMap.self, from: encoded) == map)
    }

    /// A cache file is read and written whole, so two encodings of the same
    /// map differing only in `Set` iteration order would rewrite it for no
    /// reason and make any byte comparison meaningless.
    @Test("The same map always encodes to the same bytes")
    func encodingIsDeterministic() throws {
        let map = partialMap()

        #expect(try Self.cacheEncoder().encode(map) == (try Self.cacheEncoder().encode(map)))
    }

    /// The exact encoder `CoverageProfileCache.store` uses — the guarantees
    /// asserted above are the stored file's, not `JSONEncoder`'s defaults.
    private static func cacheEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The safe direction, pinned so nobody adds a lenient reader later: an
    /// entry in the pre-interning shape must miss, not be half-understood.
    @Test("An entry in the superseded inline shape fails to decode rather than being misread")
    func supersededShapeFailsToDecode() {
        let superseded = Data(
            #"{"coveringTests":{"Sources/Foo.swift":{"1":[{"target":"T","qualifiedName":"S/t"}]}},"source":"old"}"#.utf8
        )

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PerTestCoverageMap.self, from: superseded)
        }
    }
}
