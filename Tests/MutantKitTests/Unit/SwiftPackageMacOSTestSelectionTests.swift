@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Pins `SwiftPackageMacOSAdapter.parseTestIdentifiers` against a real
/// `swift test list` capture — verbatim stdout from running it against
/// `swift-async-algorithms`, a real SwiftPM package with no Xcode project.
/// `swift test list` writes build progress to stderr, so its stdout is one
/// `<Target>.<Class>/<method>` identifier per line and nothing else; this
/// suite pins that exact shape so a change in SwiftPM's own output format
/// surfaces here rather than as silently-empty test selection on a real run.
@Suite("SwiftPM test identifier enumeration")
struct SwiftPackageMacOSTestIdentifierEnumerationTests {
    /// Captured verbatim from `swift test list` (stdout only) against
    /// `swift-async-algorithms`.
    private static let capturedOutput = """
    AsyncAlgorithmsTests.MultiProducerSingleConsumerAsyncChannelTests/testAsyncSequenceWrite
    AsyncAlgorithmsTests.MultiProducerSingleConsumerAsyncChannelTests/testBackpressureSync
    AsyncAlgorithmsTests.TestZip2/test_zip_when_cancelled
    AsyncAlgorithmsTests.TestZip3/test_zip_produces_one_element_and_throws_when_third_is_longer
    """

    @Test("Every line becomes a TestIdentifier split at the target/class dot")
    func findsEveryTestCase() {
        let found = SwiftPackageMacOSAdapter.parseTestIdentifiers(Self.capturedOutput)

        #expect(Set(found.map(\.target)) == ["AsyncAlgorithmsTests"])
        #expect(Set(found.map(\.qualifiedName)) == [
            "MultiProducerSingleConsumerAsyncChannelTests/testAsyncSequenceWrite",
            "MultiProducerSingleConsumerAsyncChannelTests/testBackpressureSync",
            "TestZip2/test_zip_when_cancelled",
            "TestZip3/test_zip_produces_one_element_and_throws_when_third_is_longer"
        ])
    }

    @Test("The target is everything before the first dot, the qualified name everything after")
    func splitsAtTheFirstDot() {
        let found = SwiftPackageMacOSAdapter.parseTestIdentifiers(
            "AsyncAlgorithmsTests.TestZip2/test_zip_when_cancelled"
        )

        #expect(found == [
            TestIdentifier(target: "AsyncAlgorithmsTests", qualifiedName: "TestZip2/test_zip_when_cancelled")
        ])
    }

    @Test("Blank lines are skipped")
    func blankLinesAreSkipped() {
        let found = SwiftPackageMacOSAdapter.parseTestIdentifiers("""
        AsyncAlgorithmsTests.TestZip2/test_zip_when_cancelled

        AsyncAlgorithmsTests.TestZip3/test_zip_when_cancelled
        """)

        #expect(found.count == 2)
    }

    @Test("A line with no dot (no target separator) is skipped, not crashed on")
    func lineWithNoDotIsSkipped() {
        #expect(SwiftPackageMacOSAdapter.parseTestIdentifiers("garbage-line-with-no-dot").isEmpty)
    }

    @Test("A line with a dot but no slash (no method) is skipped")
    func lineWithNoSlashIsSkipped() {
        #expect(SwiftPackageMacOSAdapter.parseTestIdentifiers("AsyncAlgorithmsTests.NoMethodHere").isEmpty)
    }

    @Test("Empty input yields no identifiers")
    func emptyInputYieldsEmpty() {
        #expect(SwiftPackageMacOSAdapter.parseTestIdentifiers("").isEmpty)
    }
}

/// `swift test list` enumerates every test in the package, across every test
/// target — unlike Xcode's baseline bundle, which only ever contains the
/// configured targets because the baseline run itself was already filtered
/// by `-only-testing:`. `SwiftPackageMacOSAdapter.scope` re-applies that same
/// restriction for SwiftPM so a package with several test targets (like
/// swift-numerics: `ComplexTests`, `IntegerUtilitiesTests`, `RealTests`)
/// does not pay the one-time per-test coverage cost for targets nobody asked
/// to run.
@Suite("SwiftPM test enumeration target scoping")
struct SwiftPackageMacOSTestEnumerationScopingTests {
    private let configuredTest = TestIdentifier(target: "IntegerUtilitiesTests", qualifiedName: "GCDTests/testGCD")
    private let otherTargetTest = TestIdentifier(target: "ComplexTests", qualifiedName: "ComplexTests/testAdd")

    @Test("An empty configured target list keeps every test, package-wide")
    func emptyConfiguredTargetsKeepsEverything() {
        let scoped = SwiftPackageMacOSAdapter.scope(
            [configuredTest, otherTargetTest],
            toConfiguredTargets: []
        )

        #expect(Set(scoped) == [configuredTest, otherTargetTest])
    }

    @Test("A configured target list drops every test outside it")
    func configuredTargetsDropsOutsideTests() {
        let scoped = SwiftPackageMacOSAdapter.scope(
            [configuredTest, otherTargetTest],
            toConfiguredTargets: ["IntegerUtilitiesTests"]
        )

        #expect(scoped == [configuredTest])
    }

    @Test("Multiple configured targets keep tests from any of them")
    func multipleConfiguredTargetsUnionKept() {
        let scoped = SwiftPackageMacOSAdapter.scope(
            [configuredTest, otherTargetTest],
            toConfiguredTargets: ["IntegerUtilitiesTests", "ComplexTests"]
        )

        #expect(Set(scoped) == [configuredTest, otherTargetTest])
    }

    @Test("A configured target with no matching tests yields an empty result, not a crash")
    func noMatchingTestsYieldsEmpty() {
        let scoped = SwiftPackageMacOSAdapter.scope(
            [configuredTest],
            toConfiguredTargets: ["RealTests"]
        )

        #expect(scoped.isEmpty)
    }
}

/// The per-line reverse index `measurePerTestCoverage` builds up across every
/// individually-run test — pulled into `SwiftPackageMacOSAdapter.invert` so
/// it can be exercised directly from hand-built `CoverageMap` fixtures, the
/// same way `PerTestCoverageMapTests` pins the map's own read side, without
/// spawning `swift test` or reading real codecov JSON.
@Suite("SwiftPM per-test coverage inversion")
struct SwiftPackageMacOSPerTestCoverageInversionTests {
    private let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
    private let subTest = TestIdentifier(target: "FooTests", qualifiedName: "SubTests/testSub")

    @Test("One test's covered lines are attributed to that test")
    func oneTestAttributesItsOwnLines() {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        let map = CoverageMap(executedLines: ["Sources/Foo.swift": [1, 2]], source: "swift-package-codecov")

        SwiftPackageMacOSAdapter.invert(map, coveredBy: addTest, into: &coveringTests)

        #expect(coveringTests["Sources/Foo.swift"]?[1] == [addTest])
        #expect(coveringTests["Sources/Foo.swift"]?[2] == [addTest])
    }

    @Test("A second test covering the same line joins the first, rather than replacing it")
    func secondTestJoinsRatherThanReplaces() {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        let addMap = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "swift-package-codecov")
        let subMap = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "swift-package-codecov")

        SwiftPackageMacOSAdapter.invert(addMap, coveredBy: addTest, into: &coveringTests)
        SwiftPackageMacOSAdapter.invert(subMap, coveredBy: subTest, into: &coveringTests)

        #expect(coveringTests["Sources/Foo.swift"]?[1] == [addTest, subTest])
    }

    @Test("Lines only one test touches stay attributed to only that test")
    func disjointLinesStayDisjoint() {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        let addMap = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "swift-package-codecov")
        let subMap = CoverageMap(executedLines: ["Sources/Foo.swift": [2]], source: "swift-package-codecov")

        SwiftPackageMacOSAdapter.invert(addMap, coveredBy: addTest, into: &coveringTests)
        SwiftPackageMacOSAdapter.invert(subMap, coveredBy: subTest, into: &coveringTests)

        #expect(coveringTests["Sources/Foo.swift"]?[1] == [addTest])
        #expect(coveringTests["Sources/Foo.swift"]?[2] == [subTest])
    }

    @Test("Multiple files from the same test's run are all attributed")
    func multipleFilesAreAllAttributed() {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        let map = CoverageMap(
            executedLines: ["Sources/Foo.swift": [1], "Sources/Bar.swift": [10]],
            source: "swift-package-codecov"
        )

        SwiftPackageMacOSAdapter.invert(map, coveredBy: addTest, into: &coveringTests)

        #expect(coveringTests["Sources/Foo.swift"]?[1] == [addTest])
        #expect(coveringTests["Sources/Bar.swift"]?[10] == [addTest])
    }

    @Test("The resulting map feeds PerTestCoverageMap.testsCovering directly")
    func feedsPerTestCoverageMapLookup() {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        let map = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "swift-package-codecov")
        SwiftPackageMacOSAdapter.invert(map, coveredBy: addTest, into: &coveringTests)

        let perTest = PerTestCoverageMap(coveringTests: coveringTests, source: "swiftpm-codecov-per-test")

        #expect(perTest.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest])
    }
}

/// `SwiftPackageMacOSAdapter.classify`'s narrowed-selection shortfall check
/// (P12-B Phase B3), pinned at the unit level with hand-built `ProcessResult`s
/// so it does not need a real `swift test` invocation. Two gaps a codex
/// review caught in the first version of this check:
///
/// - A disabled/conditionally-skipped test reports `tests="1" skipped="1"`,
///   which must not count as "executed" (see
///   `XUnitRawExecutedCountTests.skippedTestsDoNotCountAsExecuted` for the
///   parser-level half of this).
/// - No xunit report at all (a missing or unreadable file) must fail closed,
///   not fall through to `.passed` for lack of contrary evidence.
@Suite("SwiftPM narrowed-selection shortfall classification")
struct SwiftPackageMacOSShortfallClassificationTests {
    private func exitZero() -> ProcessResult {
        ProcessResult(
            exitCode: 0, standardOutput: Data(), standardError: Data(),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
    }

    private func command() -> CommandRecord {
        CommandRecording.record(
            executable: "/usr/bin/xcrun", arguments: ["swift", "test"],
            workingDirectory: URL(fileURLWithPath: "/tmp"), result: nil
        )
    }

    private func writeReport(_ contents: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-shortfall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, xml) in contents {
            try Data(xml.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent("mutantkit-xunit.xml")
    }

    @Test("A narrowed selection with no xunit report at all fails closed, not passed")
    func missingReportFailsClosed() {
        let result = SwiftPackageMacOSAdapter.classify(
            result: exitZero(), command: command(),
            xunitOutput: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)/mutantkit-xunit.xml"),
            reliableExpectedTestCount: 1
        )
        #expect(result.status == .infrastructureFailure)
    }

    @Test("A narrowed selection with no xunitOutput path at all fails closed")
    func nilXunitOutputFailsClosed() {
        let result = SwiftPackageMacOSAdapter.classify(
            result: exitZero(), command: command(), xunitOutput: nil, reliableExpectedTestCount: 1
        )
        #expect(result.status == .infrastructureFailure)
    }

    @Test("A skipped test does not count as executed against the narrowed count")
    func skippedTestDoesNotCountAsExecuted() throws {
        let xunitOutput = try writeReport([
            "mutantkit-xunit-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="1" failures="0" skipped="1" time="0.001" />
            </testsuites>
            """
        ])

        let result = SwiftPackageMacOSAdapter.classify(
            result: exitZero(), command: command(), xunitOutput: xunitOutput, reliableExpectedTestCount: 1
        )
        #expect(result.status == .infrastructureFailure)
    }

    @Test("A genuinely-executed narrowed selection is still reported as passed")
    func genuineExecutionIsStillPassed() throws {
        let xunitOutput = try writeReport([
            "mutantkit-xunit-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="1" failures="0" skipped="0" time="0.001" />
            </testsuites>
            """
        ])

        let result = SwiftPackageMacOSAdapter.classify(
            result: exitZero(), command: command(), xunitOutput: xunitOutput, reliableExpectedTestCount: 1
        )
        #expect(result.status == .passed)
    }

    @Test("An unnarrowed run with no xunit report is unaffected -- still passed")
    func unnarrowedRunWithNoReportIsUnaffected() {
        let result = SwiftPackageMacOSAdapter.classify(
            result: exitZero(), command: command(),
            xunitOutput: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)/mutantkit-xunit.xml"),
            reliableExpectedTestCount: nil
        )
        #expect(result.status == .passed)
    }
}
