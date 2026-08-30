@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Fixtures below are lines taken verbatim (or trivially trimmed of
/// irrelevant fields) from real `swiftpm-testing-helper
/// --event-stream-version 0` captures against a real built `.xctest`
/// bundle — a plain passing test, a failing test, a 3-case
/// `@Test(arguments:)` parameterized test, and a `.disabled` test. Not
/// reconstructed from documentation or invented shapes.
@Suite("Swift Testing event stream parser")
struct SwiftTestingEventStreamParserTests {
    private static let runStarted = """
    {"kind":"event","payload":{"kind":"runStarted","messages":[{"symbol":"default","text":"Test run started."}]},"version":0}
    """
    private static let runEndedPass = """
    {"kind":"event","payload":{"kind":"runEnded","messages":[{"symbol":"pass","text":"Test run passed."}]},"version":0}
    """
    private static let suiteDeclaration = """
    {"kind":"test","payload":{"id":"WidgetsTests.WidgetsTests","kind":"suite","name":"WidgetsTests"},"version":0}
    """
    private static func suiteStarted(id: String = "WidgetsTests.WidgetsTests") -> String {
        """
        {"kind":"event","payload":{"kind":"testStarted","testID":"\(id)","messages":[{"symbol":"default","text":"Suite started."}]},"version":0}
        """
    }
    private static func suiteEnded(id: String = "WidgetsTests.WidgetsTests") -> String {
        """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(id)","messages":[{"symbol":"pass","text":"Suite passed."}]},"version":0}
        """
    }

    private static func functionDeclaration(id: String, name: String, isParameterized: Bool = false) -> String {
        """
        {"kind":"test","payload":{"id":"\(id)","kind":"function","isParameterized":\(isParameterized),"name":"\(name)"},"version":0}
        """
    }

    private static func testStarted(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testStarted","testID":"\(id)","messages":[{"symbol":"default","text":"Test started."}]},"version":0}
        """
    }

    private static func testEnded(id: String, symbol: String = "pass") -> String {
        """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(id)","messages":[{"symbol":"\(symbol)","text":"Test ended."}]},"version":0}
        """
    }

    private static func testCaseStarted(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testCaseStarted","testID":"\(id)","_testCase":{"displayName":"1"},"messages":[{"symbol":"default","text":"Test case started."}]},"version":0}
        """
    }

    private static func testCaseEnded(id: String) -> String {
        // Confirmed live: testCaseEnded's own messages array is present but empty.
        """
        {"kind":"event","payload":{"kind":"testCaseEnded","testID":"\(id)","_testCase":{"displayName":"1"},"messages":[]},"version":0}
        """
    }

    private static func testSkipped(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testSkipped","testID":"\(id)","messages":[{"symbol":"skip","text":"Test skipped."}]},"version":0}
        """
    }

    @Test("A clean single-test run parses to exactly the expected TestIdentifier, started and ended")
    func cleanSingleTestRunParses() throws {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let stream = [
            Self.suiteDeclaration,
            Self.functionDeclaration(id: functionID, name: "widgetA()"),
            Self.runStarted,
            Self.suiteStarted(),
            Self.testStarted(id: eventID),
            Self.testEnded(id: eventID),
            Self.suiteEnded(),
            Self.runEndedPass
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }

        let expected = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()")
        #expect(evidence.runStarted)
        #expect(evidence.runEnded)
        #expect(evidence.declaredTests == [expected])
        #expect(evidence.startedTests == [expected])
        #expect(evidence.endedTests == [expected])
        #expect(evidence.failedTests.isEmpty)
    }

    @Test("A testEnded event with a fail symbol marks the test failed, even though it still ended cleanly")
    func failSymbolMarksTestFailed() throws {
        let functionID = "WidgetTests.WidgetTests/alwaysFails()"
        let eventID = "\(functionID)/WidgetTests.swift:4:2"
        let stream = [
            Self.functionDeclaration(id: functionID, name: "alwaysFails()"),
            Self.runStarted,
            Self.testStarted(id: eventID),
            Self.testEnded(id: eventID, symbol: "fail"),
            Self.runEndedPass
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
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let stream = [
            Self.suiteDeclaration,
            Self.functionDeclaration(id: functionID, name: "widgetA()"),
            Self.runStarted,
            Self.suiteStarted(),
            Self.testStarted(id: eventID),
            Self.testEnded(id: eventID),
            Self.suiteEnded(),
            Self.runEndedPass
        ].joined(separator: "\n")

        guard case .parsed = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("suite container events must not make the whole stream unsupported")
            return
        }
    }

    @Test("A parameterized test's single function-level start/end pair is its evidence -- case events don't multiply it")
    func parameterizedFunctionUsesOneStartEndPairRegardlessOfCaseCount() throws {
        // Real shape: ONE "test"/"function" declaration (isParameterized:
        // true, no per-case declarations), ONE testStarted/testEnded pair
        // at the function's own testID, with testCaseStarted/testCaseEnded
        // (same testID) interleaved for each of the 3 cases -- confirmed
        // live against a real @Test(arguments: [1, 2, 3]) function.
        let functionID = "WidgetsTests.WidgetsTests/parameterized(_:)"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let stream = [
            Self.functionDeclaration(id: functionID, name: "parameterized(_:)", isParameterized: true),
            Self.runStarted,
            Self.testStarted(id: eventID),
            Self.testCaseStarted(id: eventID),
            Self.testCaseStarted(id: eventID),
            Self.testCaseStarted(id: eventID),
            Self.testCaseEnded(id: eventID),
            Self.testCaseEnded(id: eventID),
            Self.testCaseEnded(id: eventID),
            Self.testEnded(id: eventID),
            Self.runEndedPass
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/parameterized(_:)")
        #expect(evidence.declaredTests == [expected])
        #expect(evidence.startedTests == [expected])
        #expect(evidence.endedTests == [expected])
        #expect(evidence.failedTests.isEmpty)
    }

    @Test("testCaseStarted/testCaseEnded with a malformed messages field fails the whole stream closed")
    func malformedCaseEventFailsClosed() {
        let functionID = "WidgetsTests.WidgetsTests/parameterized(_:)"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let malformedCaseEvent = """
        {"kind":"event","payload":{"kind":"testCaseStarted","testID":"\(eventID)"},"version":0}
        """
        let stream = [
            Self.functionDeclaration(id: functionID, name: "parameterized(_:)", isParameterized: true),
            Self.runStarted,
            Self.testStarted(id: eventID),
            malformedCaseEvent
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported: testCaseStarted is a known event kind, its messages field is required")
            return
        }
    }

    @Test("A disabled test emits testSkipped, never testStarted/testEnded, and is tracked separately")
    func disabledTestEmitsTestSkipped() throws {
        // Real shape, confirmed live: a .disabled test gets its own "test"/
        // "function" declaration but never testStarted/testEnded at all --
        // only a single testSkipped event.
        let functionID = "WidgetsTests.WidgetsTests/skippedTest()"
        let eventID = "\(functionID)/WidgetsTests.swift:11:6"
        let stream = [
            Self.functionDeclaration(id: functionID, name: "skippedTest()"),
            Self.runStarted,
            Self.testSkipped(id: eventID),
            Self.runEndedPass
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/skippedTest()")
        #expect(evidence.declaredTests == [expected])
        #expect(evidence.startedTests.isEmpty)
        #expect(evidence.endedTests.isEmpty)
        #expect(evidence.skippedTests == [expected])
    }

    @Test("An unsupported record version fails closed")
    func unsupportedVersionFailsClosed() {
        let stream = """
        {"kind":"event","payload":{"kind":"runStarted","messages":[]},"version":7}
        """
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
        let stream = """
        {"kind":"test","payload":{"kind":"function"},"version":0}
        """
        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A testStarted event missing its own messages field fails closed, not treated as no-failure")
    func testStartedMissingMessagesFailsClosed() {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let malformedEvent = """
        {"kind":"event","payload":{"kind":"testStarted","testID":"\(eventID)"},"version":0}
        """
        let stream = [
            Self.functionDeclaration(id: functionID, name: "widgetA()"),
            Self.runStarted,
            malformedEvent
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A known event kind with a missing payload fails the whole stream closed")
    func knownEventWithMissingPayloadFailsClosed() {
        let stream = """
        {"kind":"event","version":0}
        """
        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("An unrecognized event kind is safely ignored, not a failure")
    func unrecognizedEventKindIsIgnored() throws {
        let unknownEvent = """
        {"kind":"event","payload":{"kind":"someFutureEventKind"},"version":0}
        """
        let stream = [Self.runStarted, unknownEvent, Self.runEndedPass].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result -- an unrecognized event kind must not fail the stream")
            return
        }
        #expect(evidence.runStarted)
        #expect(evidence.runEnded)
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
