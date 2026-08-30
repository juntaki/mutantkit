import Foundation
import MutationModel

/// Reads the JUnit XML that `swift test --xunit-output` produces.
///
/// A Swift package has no `.xcresult`, so this is its structured source of
/// truth. The alternative — scraping `swift test` stdout — is what makes a tool
/// misread a framework's output change as a crash, and it is not done here.
///
/// SwiftPM splits its output by framework: asking for `xunit.xml` yields
/// `xunit.xml` for XCTest and `xunit-swift-testing.xml` for Swift Testing. A
/// package may use either or both, so both are read and merged; reading only the
/// requested path silently reports zero tests for a Swift Testing suite.
enum XUnitParser {
    /// The paths SwiftPM may write, given the `--xunit-output` value it was passed.
    static func candidatePaths(for requested: URL) -> [URL] {
        let directory = requested.deletingLastPathComponent()
        let stem = requested.deletingPathExtension().lastPathComponent
        let ext = requested.pathExtension.isEmpty ? "xml" : requested.pathExtension

        return [
            requested,
            directory.appendingPathComponent("\(stem)-swift-testing").appendingPathExtension(ext)
        ]
    }

    /// Merges every report SwiftPM actually wrote.
    ///
    /// Returns `nil` when no report exists at all, which the caller must treat as
    /// "no verdict" rather than as a suite of zero passing tests.
    static func summary(forRequestedOutput requested: URL) -> TestOutcomeSummary? {
        let suites = candidatePaths(for: requested).compactMap { parse(contentsOf: $0) }
        guard !suites.isEmpty else { return nil }

        let merged = suites.reduce(into: Report()) { accumulated, report in
            accumulated.total += report.total
            accumulated.failed += report.failed
            accumulated.skipped += report.skipped
            accumulated.duration += report.duration
            accumulated.failingTests.append(contentsOf: report.failingTests)
        }

        // A report naming no tests is the absence of a measurement, not a
        // measurement of zero. SwiftPM emits exactly that: it only writes the
        // XCTest report when `--parallel` is passed, so a serial run of an
        // XCTest suite leaves behind an empty Swift Testing report claiming
        // `tests="0"` — while XCTest really did run and really did fail.
        // Returning that verbatim would report "0 tests, 0 failed" for a suite
        // that caught the mutant.
        guard merged.total > 0 else { return nil }

        return TestOutcomeSummary(
            total: merged.total,
            // Skipped tests neither passed nor failed. Counting them as passing
            // would let a mutant that disables a test look like a mutant the
            // suite tolerated.
            passed: max(0, merged.total - merged.failed - merged.skipped),
            failed: merged.failed,
            failingTests: merged.failingTests.sorted(),
            durationSeconds: merged.duration
        )
    }

    /// The merged executed-test count, without `summary`'s "an all-zero
    /// merge means no measurement" collapse — the opposite fact a
    /// selected-test shortfall check needs: proof that a real zero was
    /// recorded, not proof that a nonzero one was. `nil` only when *neither*
    /// candidate path parsed at all (no report of any kind was written),
    /// which stays genuinely unknown; a parsed report claiming zero is a
    /// real, structured zero.
    static func rawExecutedCount(forRequestedOutput requested: URL) -> Int? {
        let suites = candidatePaths(for: requested).compactMap { parse(contentsOf: $0) }
        guard !suites.isEmpty else { return nil }
        return suites.reduce(0) { $0 + $1.total }
    }

    struct Report {
        var total = 0
        var failed = 0
        var skipped = 0
        var duration: Double = 0
        var failingTests: [String] = []
    }

    static func parse(contentsOf url: URL) -> Report? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Report? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.report
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var report = Report()
        private var currentTest: String?
        /// One test case can emit several `<failure>` elements — Swift Testing
        /// writes one per failed expectation. Counting elements would report a
        /// test with three bad `#expect`s as three failed tests, which inflates
        /// `failed`, deflates `passed = total - failed - skipped`, and lists the
        /// same test three times as having caught the mutant.
        private var currentTestFailed = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            switch elementName {
            case "testsuite":
                // Suite-level attributes are authoritative for counts: a suite can
                // report more tests than it emits `<testcase>` elements for.
                report.total += attributes["tests"].flatMap(Int.init) ?? 0
                report.skipped += attributes["skipped"].flatMap(Int.init) ?? 0
                report.duration += attributes["time"].flatMap(Double.init) ?? 0

            case "testcase":
                let suite = attributes["classname"] ?? "?"
                let name = attributes["name"] ?? "?"
                currentTest = "\(suite)/\(name)"
                currentTestFailed = false

            case "failure", "error":
                // Derived from the elements rather than the suite's `failures`
                // attribute so the count and the named tests can never disagree,
                // but attributed per test case rather than per element.
                currentTestFailed = true

            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            guard elementName == "testcase" else { return }
            if currentTestFailed {
                report.failed += 1
                if let currentTest {
                    report.failingTests.append(currentTest)
                }
            }
            currentTest = nil
            currentTestFailed = false
        }
    }
}
