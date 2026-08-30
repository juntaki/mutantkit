@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Fixtures below are hand-built to the exact shape confirmed live against
/// the real toolchain (`swiftpm-testing-helper --event-stream-version 0`,
/// see `SwiftTestingEventStreamParser`'s own doc comment) — not a
/// reconstruction from documentation alone.
@Suite("Swift Testing event stream parser")
struct SwiftTestingEventStreamParserTests {
    private static func line(_ json: String) -> String { json }

    private static let suiteDeclaration = line("""
    {"kind":"test","payload":{"id":"PricingTests.PricingTests","kind":"suite","name":"PricingTests"},"version":0}
    """)

    private static func functionDeclaration(id: String, name: String = "bulkDiscountRoughly()") -> String {
        line("""
        {"kind":"test","payload":{"id":"\(id)","kind":"function","isParameterized":false,"name":"\(name)"},"version":0}
        """)
    }

    private static func event(kind: String, testID: String? = nil, symbol: String? = nil) -> String {
        let messages = symbol.map { ",\"messages\":[{\"symbol\":\"\($0)\",\"text\":\"...\"}]" } ?? ""
        if let testID {
            return line("""
            {"kind":"event","payload":{"kind":"\(kind)","testID":"\(testID)"\(messages)},"version":0}
            """)
        }
        return line("""
        {"kind":"event","payload":{"kind":"\(kind)"\(messages)},"version":0}
        """)
    }

    @Test("A clean single-test run parses to exactly the expected TestIdentifier, started and ended")
    func cleanSingleTestRunParses() throws {
        let functionID = "PricingTests.PricingTests/bulkDiscountRoughly()"
        let eventID = "\(functionID)/PricingTests.swift:22:6"
        let stream = [
            Self.suiteDeclaration,
            Self.functionDeclaration(id: functionID),
            Self.event(kind: "runStarted"),
            Self.event(kind: "testStarted", testID: "PricingTests.PricingTests"),
            Self.event(kind: "testStarted", testID: eventID),
            Self.event(kind: "testEnded", testID: eventID),
            Self.event(kind: "testEnded", testID: "PricingTests.PricingTests"),
            Self.event(kind: "runEnded")
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }

        let expected = TestIdentifier(target: "PricingTests", qualifiedName: "PricingTests/bulkDiscountRoughly()")
        #expect(evidence.runStarted)
        #expect(evidence.runEnded)
        #expect(evidence.declaredTests == [expected])
        #expect(evidence.startedTests == [expected])
        #expect(evidence.endedTests == [expected])
        #expect(evidence.failedTests.isEmpty)
    }

    @Test("A testEnded event with a fail symbol marks the test failed, even though it still ended cleanly")
    func failSymbolMarksTestFailed() throws {
        // Suite-scoped, matching the real fixture shape used elsewhere in
        // this file -- a global (non-suite) Swift Testing function's own id
        // has no "/" at all (confirmed live: `swift test list` reports it
        // as "<Target>.<method>()"), which even the existing serial oracle's
        // own TestIdentifier parsing already excludes (`SwiftPackageMacOSAdapter
        // .parseTestIdentifiers`'s `qualifiedName.contains("/")` guard) --
        // a pre-existing, codebase-wide limitation this fast path
        // intentionally matches rather than fixes.
        let functionID = "WidgetTests.WidgetTests/alwaysFails()"
        let eventID = "\(functionID)/WidgetTests.swift:4:2"
        let stream = [
            Self.functionDeclaration(id: functionID, name: "alwaysFails()"),
            Self.event(kind: "runStarted"),
            Self.event(kind: "testStarted", testID: eventID),
            Self.event(kind: "testEnded", testID: eventID, symbol: "fail"),
            Self.event(kind: "runEnded", symbol: "fail")
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "WidgetTests", qualifiedName: "WidgetTests/alwaysFails()")
        // Still ended -- a failure is not a crash or a hang.
        #expect(evidence.endedTests == [expected])
        #expect(evidence.failedTests == [expected])
    }

    @Test("A suite's own container testStarted/testEnded are not mistaken for malformed leaf-test evidence")
    func suiteContainerEventsAreNotMalformed() {
        // Same as the clean run above, but this is the exact regression
        // case: without declaredSuiteIDs tracking, the suite's own
        // "PricingTests.PricingTests" testID (no "/") fails
        // testIdentifier(fromEventStreamID:) and must not be treated as
        // corrupted evidence.
        let functionID = "PricingTests.PricingTests/bulkDiscountRoughly()"
        let eventID = "\(functionID)/PricingTests.swift:22:6"
        let stream = [
            Self.suiteDeclaration,
            Self.functionDeclaration(id: functionID),
            Self.event(kind: "runStarted"),
            Self.event(kind: "testStarted", testID: "PricingTests.PricingTests"),
            Self.event(kind: "testStarted", testID: eventID),
            Self.event(kind: "testEnded", testID: eventID),
            Self.event(kind: "testEnded", testID: "PricingTests.PricingTests"),
            Self.event(kind: "runEnded")
        ].joined(separator: "\n")

        guard case .parsed = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("suite container events must not make the whole stream unsupported")
            return
        }
    }

    @Test("A parameterized test's multiple cases all fold into one TestIdentifier, and all must end")
    func parameterizedCasesFoldIntoOneIdentifier() throws {
        let functionID = "PricingTests.PricingTests/parameterized(value:)"
        let case1 = "\(functionID)/PricingTests.swift:30:6"
        let case2 = "\(functionID)/PricingTests.swift:31:6"
        let stream = [
            Self.functionDeclaration(id: functionID, name: "parameterized(value:)"),
            Self.functionDeclaration(id: functionID, name: "parameterized(value:)"), // one declaration per case
            Self.event(kind: "runStarted"),
            Self.event(kind: "testStarted", testID: case1),
            Self.event(kind: "testEnded", testID: case1),
            Self.event(kind: "testStarted", testID: case2),
            Self.event(kind: "testEnded", testID: case2),
            Self.event(kind: "runEnded")
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "PricingTests", qualifiedName: "PricingTests/parameterized(value:)")
        #expect(evidence.declaredTests == [expected])
        #expect(evidence.endedTests == [expected])
    }

    @Test("A parameterized test missing one case's testEnded is not marked ended")
    func parameterizedTestMissingOneCaseEndIsNotEnded() {
        let functionID = "PricingTests.PricingTests/parameterized(value:)"
        let case1 = "\(functionID)/PricingTests.swift:30:6"
        let case2 = "\(functionID)/PricingTests.swift:31:6"
        let stream = [
            Self.functionDeclaration(id: functionID, name: "parameterized(value:)"),
            Self.functionDeclaration(id: functionID, name: "parameterized(value:)"),
            Self.event(kind: "runStarted"),
            Self.event(kind: "testStarted", testID: case1),
            Self.event(kind: "testEnded", testID: case1),
            Self.event(kind: "testStarted", testID: case2),
            // case2 never ends -- a crash mid-case, for instance.
            Self.event(kind: "runEnded")
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "PricingTests", qualifiedName: "PricingTests/parameterized(value:)")
        #expect(!evidence.endedTests.contains(expected))
    }

    @Test("An unsupported record version fails closed")
    func unsupportedVersionFailsClosed() {
        let stream = Self.line("""
        {"kind":"event","payload":{"kind":"runStarted"},"version":7}
        """)
        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A malformed JSON line fails closed, not treated as zero tests")
    func malformedLineFailsClosed() {
        let stream = "not json at all"
        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A test declaration missing its own id fails closed")
    func declarationMissingIDFailsClosed() {
        let stream = Self.line("""
        {"kind":"test","payload":{"kind":"function"},"version":0}
        """)
        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("testIdentifier(fromEventStreamID:) strips the source-location suffix and matches swift test list's own shape")
    func testIdentifierStripsSourceLocationSuffix() throws {
        let identifier = try #require(
            SwiftTestingEventStreamParser.testIdentifier(
                fromEventStreamID: "PricingTests.PricingTests/bulkDiscountRoughly()/PricingTests.swift:22:6"
            )
        )
        #expect(identifier == TestIdentifier(target: "PricingTests", qualifiedName: "PricingTests/bulkDiscountRoughly()"))
    }

    @Test("A suite id (no slash) does not resolve to a TestIdentifier")
    func suiteIDDoesNotResolve() {
        #expect(SwiftTestingEventStreamParser.testIdentifier(fromEventStreamID: "PricingTests.PricingTests") == nil)
    }
}
