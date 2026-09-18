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

/// The loop both adapters run across every individually-run test:
/// `PerTestCoverageAttribution.attribute`. Driven here from hand-built
/// `CoverageMap` fixtures and a stub attempt, so the inversion, the retry, and
/// the unproven-test bookkeeping — the parts with no toolchain or process
/// involved — are exercised without spawning `swift test` or `xcodebuild`.
///
/// This is the real production path, not an extracted copy of it: both
/// `SwiftPackageMacOSAdapter` and `XcodeBuildAdapter` supply only "run one
/// test and read its coverage" and get everything below from here.
@Suite("Per-test coverage attribution loop")
struct PerTestCoverageAttributionLoopTests {
    private let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
    private let subTest = TestIdentifier(target: "FooTests", qualifiedName: "SubTests/testSub")

    private func attribute(
        _ tests: [TestIdentifier],
        attempts: Int = 2,
        measuring coverage: [TestIdentifier: CoverageMap]
    ) async -> PerTestCoverageMap? {
        await PerTestCoverageAttribution.attribute(
            tests: tests, source: "swiftpm-codecov-per-test", attempts: attempts
        ) { test, _ in coverage[test] }
    }

    @Test("One test's covered lines are attributed to that test")
    func oneTestAttributesItsOwnLines() async throws {
        let map = try #require(await attribute(
            [addTest],
            measuring: [addTest: CoverageMap(executedLines: ["Sources/Foo.swift": [1, 2]], source: "codecov")]
        ))

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest])
        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 2) == [addTest])
        #expect(map.isComplete)
    }

    @Test("A second test covering the same line joins the first, rather than replacing it")
    func secondTestJoinsRatherThanReplaces() async throws {
        let line1 = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "codecov")
        let map = try #require(await attribute(
            [addTest, subTest], measuring: [addTest: line1, subTest: line1]
        ))

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest, subTest])
    }

    @Test("Lines only one test touches stay attributed to only that test")
    func disjointLinesStayDisjoint() async throws {
        let map = try #require(await attribute([addTest, subTest], measuring: [
            addTest: CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "codecov"),
            subTest: CoverageMap(executedLines: ["Sources/Foo.swift": [2]], source: "codecov")
        ]))

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest])
        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 2) == [subTest])
    }

    @Test("Multiple files from the same test's run are all attributed")
    func multipleFilesAreAllAttributed() async throws {
        let map = try #require(await attribute([addTest], measuring: [
            addTest: CoverageMap(
                executedLines: ["Sources/Foo.swift": [1], "Sources/Bar.swift": [10]], source: "codecov"
            )
        ]))

        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest])
        #expect(map.testsCovering(file: "Sources/Bar.swift", line: 10) == [addTest])
    }

    /// The whole point of the rewrite this suite came from: one unmeasurable
    /// test used to discard every other test's measurement.
    @Test("A test that cannot be measured is carried as unproven, not allowed to discard the rest")
    func unmeasurableTestDoesNotDiscardTheRest() async throws {
        let map = try #require(await attribute([addTest, subTest], measuring: [
            addTest: CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "codecov")
        ]))

        #expect(!map.isComplete)
        #expect(map.unattributedTests == [subTest])
        // Attributed and unproven together — never the attributed set alone.
        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest, subTest])
    }

    @Test("Nothing measurable at all is still 'no attribution', so every mutant runs the full suite")
    func nothingMeasurableIsNoAttribution() async {
        #expect(await attribute([addTest, subTest], measuring: [:]) == nil)
    }

    @Test("A test is retried before it is given up on, and a retry that succeeds is attributed normally")
    func aFailedFirstAttemptIsRetried() async throws {
        let flaky = CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "codecov")
        var observedAttempts: [Int] = []

        let map = try #require(await PerTestCoverageAttribution.attribute(
            tests: [addTest], source: "swiftpm-codecov-per-test"
        ) { _, attempt in
            observedAttempts.append(attempt)
            return attempt == 1 ? nil : flaky
        })

        #expect(observedAttempts == [1, 2])
        #expect(map.isComplete)
        #expect(map.testsCovering(file: "Sources/Foo.swift", line: 1) == [addTest])
    }

    @Test("A test that succeeds first time is not run a second time")
    func aSucceedingAttemptIsNotRetried() async {
        var calls = 0
        _ = await PerTestCoverageAttribution.attribute(tests: [addTest], source: "s") { _, _ in
            calls += 1
            return CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "codecov")
        }

        #expect(calls == 1)
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

    /// An XCTest report's own nonzero count must never substitute for the
    /// Swift Testing sibling's own -- `reliableExpectedTestCount` is a claim
    /// specifically about a Swift-Testing-shaped selection, and only the
    /// Swift Testing report is evidence of it.
    @Test("An unrelated XCTest report's count does not satisfy the Swift Testing shortfall check")
    func xctestReportCountDoesNotSatisfyShortfall() throws {
        let xunitOutput = try writeReport([
            "mutantkit-xunit.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="LibTests" tests="1" failures="0" skipped="0" time="0.03" />
            </testsuites>
            """,
            "mutantkit-xunit-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="0" failures="0" skipped="0" time="0.0001" />
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

/// `swiftTestBuildFlags`'s own contract, pinned independently of any real
/// `swift test` invocation: `measurePerTestCoverage`'s loop passes
/// `skipBuild: true` from its second iteration on to avoid paying for
/// SwiftPM's build-graph check on every one of what can be hundreds of
/// per-test invocations. Without a test at this level, an acceptance suite
/// passing proves only that *some* set of flags happened to work, not that
/// this optimization's own flags are the ones actually produced.
@Suite("SwiftPM test build flags")
struct SwiftPackageMacOSTestBuildFlagTests {
    @Test("Ordinary test runs preserve skip-build")
    func ordinaryRunSkipsBuild() {
        #expect(
            SwiftPackageMacOSAdapter.swiftTestBuildFlags(enableCoverage: false, skipBuild: nil) == ["--skip-build"]
        )
    }

    @Test("Coverage defaults to allowing the instrumentation build")
    func firstCoverageRunDoesNotSkipBuild() {
        #expect(
            SwiftPackageMacOSAdapter.swiftTestBuildFlags(enableCoverage: true, skipBuild: nil)
                == ["--enable-code-coverage"]
        )
    }

    @Test("Coverage can explicitly reuse the already-built artifact")
    func repeatedCoverageRunSkipsBuild() {
        #expect(
            SwiftPackageMacOSAdapter.swiftTestBuildFlags(enableCoverage: true, skipBuild: true)
                == ["--enable-code-coverage", "--skip-build"]
        )
    }

    @Test("Explicit false still permits a coverage rebuild")
    func explicitFalseDoesNotSkipBuild() {
        #expect(
            SwiftPackageMacOSAdapter.swiftTestBuildFlags(enableCoverage: true, skipBuild: false)
                == ["--enable-code-coverage"]
        )
    }
}
