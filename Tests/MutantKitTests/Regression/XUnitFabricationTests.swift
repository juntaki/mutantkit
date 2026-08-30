@testable import AppleBuildAdapters
import Foundation
import Testing

/// An empty report is missing data, not a measurement of zero.
///
/// SwiftPM writes the XCTest half of `--xunit-output` only when tests run in
/// parallel. A serial run of an XCTest package therefore leaves behind *only* a
/// Swift Testing report claiming `tests="0" failures="0"` — while XCTest really
/// did run, and really may have caught the mutant.
///
/// Returning that verbatim would report "0 tests, 0 passed, 0 failed" for a
/// suite that ran and failed. The count is not merely wrong: it is fabricated,
/// and it looks exactly like a measured one to everything downstream. `nil` says
/// "no data", which is the truth.
@Suite("Regression: xunit counts are never fabricated")
struct XUnitFabricationTests {
    private func write(_ contents: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, xml) in contents {
            try Data(xml.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent("report.xml")
    }

    /// Exactly what SwiftPM leaves behind for a serial XCTest run.
    @Test("An all-zero report reads as no data, not as zero tests")
    func allZeroReportIsNotAMeasurement() throws {
        let requested = try write([
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" errors="0" tests="0" failures="0" skipped="0" time="0.0001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.summary(forRequestedOutput: requested) == nil)
    }

    @Test("A missing report reads as no data")
    func missingReportIsNotAMeasurement() throws {
        let requested = try write([:])
        #expect(XUnitParser.summary(forRequestedOutput: requested) == nil)
    }

    /// Both frameworks in one package: the counts must come from both files.
    @Test("XCTest and Swift Testing reports are merged")
    func bothFrameworksAreCounted() throws {
        let requested = try write([
            "report.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="LibTests" tests="2" failures="1" skipped="0" time="0.06">
                <testcase classname="LibTests" name="testA" time="0.03" />
                <testcase classname="LibTests" name="testB" time="0.03">
                  <failure message="XCTAssertTrue failed" />
                </testcase>
              </testsuite>
            </testsuites>
            """,
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="2" failures="1" skipped="0" time="0.001">
                <testcase classname="Suite" name="passing()" time="0.0005" />
                <testcase classname="Suite" name="failing()" time="0.0005">
                  <failure message="Expectation failed" />
                </testcase>
              </testsuite>
            </testsuites>
            """
        ])

        let summary = try #require(XUnitParser.summary(forRequestedOutput: requested))
        #expect(summary.total == 4)
        #expect(summary.failed == 2)
        #expect(summary.passed == 2)
        #expect(summary.failingTests == ["LibTests/testB", "Suite/failing()"])
    }

    /// Swift Testing writes one `<failure>` per failed expectation, so counting
    /// elements would turn one test with three bad `#expect`s into three failed
    /// tests — inflating `failed`, driving `passed` negative, and naming the same
    /// test three times as having caught the mutant.
    @Test("Several failed expectations in one test count as one failed test")
    func multipleFailuresInOneTestCountOnce() throws {
        let requested = try write([
            "report.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="S" tests="2" failures="3" skipped="0" time="0.01">
                <testcase classname="S" name="ok" time="0.001" />
                <testcase classname="S" name="bad" time="0.001">
                  <failure message="one" />
                  <failure message="two" />
                  <failure message="three" />
                </testcase>
              </testsuite>
            </testsuites>
            """
        ])

        let summary = try #require(XUnitParser.summary(forRequestedOutput: requested))
        #expect(summary.total == 2)
        #expect(summary.failed == 1)
        #expect(summary.passed == 1)
        #expect(summary.failingTests == ["S/bad"])
    }
}

/// `rawExecutedCount` is the opposite fact `summary` protects against
/// fabricating: proof that a real zero was recorded (P12-B Finding C), not
/// proof that a nonzero measurement exists. It must never collapse a real,
/// structured zero the way `summary` deliberately does.
@Suite("Regression: raw executed counts are never collapsed")
struct XUnitRawExecutedCountTests {
    private func write(_ contents: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunit-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, xml) in contents {
            try Data(xml.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent("report.xml")
    }

    /// The exact shape a zero-match Swift Testing selection leaves behind
    /// (confirmed live in B0): a real report file exists, and it really
    /// says zero.
    @Test("An all-zero report reads as a real zero, not as no data")
    func allZeroReportReadsAsZero() throws {
        let requested = try write([
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" errors="0" tests="0" failures="0" skipped="0" time="0.0001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.rawExecutedCount(forRequestedOutput: requested) == 0)
    }

    /// No report of any kind was written at all -- genuinely unknown, unlike
    /// a report that exists and says zero.
    @Test("A missing report stays unknown")
    func missingReportStaysUnknown() throws {
        let requested = try write([:])
        #expect(XUnitParser.rawExecutedCount(forRequestedOutput: requested) == nil)
    }

    @Test("Counts from both frameworks are summed")
    func bothFrameworksAreSummed() throws {
        let requested = try write([
            "report.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="LibTests" tests="2" failures="0" skipped="0" time="0.06" />
            </testsuites>
            """,
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="1" failures="0" skipped="0" time="0.001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.rawExecutedCount(forRequestedOutput: requested) == 3)
    }

    /// A disabled/conditionally-skipped test still reports `tests="1"
    /// skipped="1"` -- codex review, P12-B Phase B3: counting it as executed
    /// would let a selected test that never actually ran satisfy a
    /// selected-test shortfall check.
    @Test("Skipped tests do not count as executed")
    func skippedTestsDoNotCountAsExecuted() throws {
        let requested = try write([
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="1" failures="0" skipped="1" time="0.001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.rawExecutedCount(forRequestedOutput: requested) == 0)
    }
}

/// `swiftTestingExecutedCount` is the evidence a narrowed, all-Swift-Testing
/// selection's own shortfall check needs -- proof the *Swift Testing*
/// report specifically recorded an execution, never a substitute drawn from
/// the unrelated XCTest report at the requested path.
@Suite("Regression: Swift Testing executed count never borrows from XCTest's report")
struct XUnitSwiftTestingExecutedCountTests {
    private func write(_ contents: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunit-swift-testing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, xml) in contents {
            try Data(xml.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent("report.xml")
    }

    /// The exact scenario a mixed-framework merge would get wrong: the
    /// requested (XCTest) path claims a real execution, but the Swift
    /// Testing sibling -- the only report a Swift-Testing-shaped
    /// selection's own claim is actually about -- says zero.
    @Test("An XCTest report's nonzero count is never substituted for the Swift Testing sibling's own")
    func xctestCountIsNeverBorrowed() throws {
        let requested = try write([
            "report.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="LibTests" tests="1" failures="0" skipped="0" time="0.03" />
            </testsuites>
            """,
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="0" failures="0" skipped="0" time="0.0001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.swiftTestingExecutedCount(forRequestedOutput: requested) == 0)
        // rawExecutedCount, by contrast, legitimately sums both -- this
        // pins the two functions' different contracts against each other,
        // not just against a fixture.
        #expect(XUnitParser.rawExecutedCount(forRequestedOutput: requested) == 1)
    }

    @Test("A genuine Swift Testing execution is read from its own report")
    func genuineSwiftTestingExecutionIsCounted() throws {
        let requested = try write([
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="1" failures="0" skipped="0" time="0.001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.swiftTestingExecutedCount(forRequestedOutput: requested) == 1)
    }

    @Test("A skipped Swift Testing test does not count as executed")
    func skippedSwiftTestingTestDoesNotCount() throws {
        let requested = try write([
            "report-swift-testing.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="TestResults" tests="1" failures="0" skipped="1" time="0.001" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.swiftTestingExecutedCount(forRequestedOutput: requested) == 0)
    }

    @Test("A missing Swift Testing sibling stays unknown, even if the requested path has a report")
    func missingSwiftTestingSiblingStaysUnknown() throws {
        let requested = try write([
            "report.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="LibTests" tests="1" failures="0" skipped="0" time="0.03" />
            </testsuites>
            """
        ])

        #expect(XUnitParser.swiftTestingExecutedCount(forRequestedOutput: requested) == nil)
    }
}
