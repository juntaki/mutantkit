@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Fixtures below are lines taken verbatim (or trivially trimmed of
/// irrelevant fields) from real `swiftpm-testing-helper
/// --event-stream-version 0` captures against a real built `.xctest`
/// bundle — a plain passing test, a failing test, a 3-case
/// `@Test(arguments:)` parameterized test, and a `.disabled` test. Not
/// reconstructed from documentation or invented shapes. Shared by both
/// test structs in this file (split in two to stay under `type_body_length`).
enum StreamFixtures {
    static let runStarted = """
    {"kind":"event","payload":{"kind":"runStarted","messages":[{"symbol":"default","text":"Test run started."}]},"version":0}
    """
    static let runEndedPass = """
    {"kind":"event","payload":{"kind":"runEnded","messages":[{"symbol":"pass","text":"Test run passed."}]},"version":0}
    """
    static let suiteDeclaration = """
    {"kind":"test","payload":{"id":"WidgetsTests.WidgetsTests","kind":"suite","name":"WidgetsTests"},"version":0}
    """
    static func suiteStarted(id: String = "WidgetsTests.WidgetsTests") -> String {
        """
        {"kind":"event","payload":{"kind":"testStarted","testID":"\(id)","messages":[{"symbol":"default","text":"Suite started."}]},"version":0}
        """
    }
    static func suiteEnded(id: String = "WidgetsTests.WidgetsTests") -> String {
        """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(id)","messages":[{"symbol":"pass","text":"Suite passed."}]},"version":0}
        """
    }

    static func functionDeclaration(id: String, name: String, isParameterized: Bool = false) -> String {
        """
        {"kind":"test","payload":{"id":"\(id)","kind":"function","isParameterized":\(isParameterized),"name":"\(name)"},"version":0}
        """
    }

    static func testStarted(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testStarted","testID":"\(id)","messages":[{"symbol":"default","text":"Test started."}]},"version":0}
        """
    }

    static func testEnded(id: String, symbol: String = "pass") -> String {
        """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(id)","messages":[{"symbol":"\(symbol)","text":"Test ended."}]},"version":0}
        """
    }

    static func testCaseStarted(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testCaseStarted","testID":"\(id)","_testCase":{"displayName":"1"},"messages":[{"symbol":"default","text":"Test case started."}]},"version":0}
        """
    }

    static func testCaseEnded(id: String) -> String {
        // Confirmed live: testCaseEnded's own messages array is present but empty.
        """
        {"kind":"event","payload":{"kind":"testCaseEnded","testID":"\(id)","_testCase":{"displayName":"1"},"messages":[]},"version":0}
        """
    }

    static func testSkipped(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testSkipped","testID":"\(id)","messages":[{"symbol":"skip","text":"Test skipped."}]},"version":0}
        """
    }

    /// Not empirically captured (see `SwiftTestingEventStreamParser
    /// .RunEvidence.cancelledTests`'s own doc comment) -- modeled by
    /// structural analogy to every other function-scoped event this file's
    /// other fixtures capture verbatim.
    static func testCancelled(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testCancelled","testID":"\(id)","messages":[{"symbol":"default","text":"Test cancelled."}]},"version":0}
        """
    }

    static func testCaseCancelled(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testCaseCancelled","testID":"\(id)","messages":[{"symbol":"default","text":"Test case cancelled."}]},"version":0}
        """
    }
}

@Suite("Swift Testing event stream parser")
struct SwiftTestingEventStreamParserTests {

    @Test("A clean single-test run parses to exactly the expected TestIdentifier, started and ended")
    func cleanSingleTestRunParses() throws {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let stream = [
            StreamFixtures.suiteDeclaration,
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.suiteStarted(),
            StreamFixtures.testStarted(id: eventID),
            StreamFixtures.testEnded(id: eventID),
            StreamFixtures.suiteEnded(),
            StreamFixtures.runEndedPass
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
        #expect(evidence.passedTests == [expected])
        #expect(evidence.failedTests.isEmpty)
    }

    @Test("A testEnded event with a fail symbol marks the test failed, even though it still ended cleanly")
    func failSymbolMarksTestFailed() throws {
        let functionID = "WidgetTests.WidgetTests/alwaysFails()"
        let eventID = "\(functionID)/WidgetTests.swift:4:2"
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "alwaysFails()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            StreamFixtures.testEnded(id: eventID, symbol: "fail"),
            StreamFixtures.runEndedPass
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
            StreamFixtures.suiteDeclaration,
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.suiteStarted(),
            StreamFixtures.testStarted(id: eventID),
            StreamFixtures.testEnded(id: eventID),
            StreamFixtures.suiteEnded(),
            StreamFixtures.runEndedPass
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
            StreamFixtures.functionDeclaration(id: functionID, name: "parameterized(_:)", isParameterized: true),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            StreamFixtures.testCaseStarted(id: eventID),
            StreamFixtures.testCaseStarted(id: eventID),
            StreamFixtures.testCaseStarted(id: eventID),
            StreamFixtures.testCaseEnded(id: eventID),
            StreamFixtures.testCaseEnded(id: eventID),
            StreamFixtures.testCaseEnded(id: eventID),
            StreamFixtures.testEnded(id: eventID),
            StreamFixtures.runEndedPass
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
            StreamFixtures.functionDeclaration(id: functionID, name: "parameterized(_:)", isParameterized: true),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
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
            StreamFixtures.functionDeclaration(id: functionID, name: "skippedTest()"),
            StreamFixtures.runStarted,
            StreamFixtures.testSkipped(id: eventID),
            StreamFixtures.runEndedPass
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
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
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
        let stream = [StreamFixtures.runStarted, unknownEvent, StreamFixtures.runEndedPass].joined(separator: "\n")

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

/// Split from `SwiftTestingEventStreamParserTests` to stay under
/// `type_body_length` -- terminal-outcome (`messages` content) and
/// declared-event-accountability coverage, added after independent review
/// found both gaps in the original implementation.
@Suite("Swift Testing event stream parser: terminal outcome and declared-event accountability")
struct SwiftTestingEventStreamParserOutcomeTests {
    // MARK: - Terminal outcome (messages content, not just shape)

    @Test("A testEnded message missing its own symbol fails the whole stream closed")
    func testEndedMessageMissingSymbolFailsClosed() {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let malformedEnded = """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(eventID)","messages":[{"text":"Test ended."}]},"version":0}
        """
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            malformedEnded
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A testEnded message with a wrong-typed symbol fails the whole stream closed")
    func testEndedMessageWrongTypedSymbolFailsClosed() {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let malformedEnded = """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(eventID)","messages":[{"symbol":1,"text":"Test ended."}]},"version":0}
        """
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            malformedEnded
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A testEnded with no recognized terminal-outcome symbol is unsupported, never a presumed pass")
    func testEndedWithNoTerminalOutcomeFailsClosed() {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        // Only informational messages -- no "pass"/"passWithKnownIssue"/"fail".
        let ambiguousEnded = """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(eventID)","messages":[{"symbol":"default","text":"Test ended."}]},"version":0}
        """
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            ambiguousEnded
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported -- unknown evidence is not a verdict, including a presumed pass")
            return
        }
    }

    @Test("A testEnded with both pass and fail symbols is unsupported, never resolved in either direction")
    func testEndedWithContradictorySymbolsFailsClosed() {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let contradictoryEnded = """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(eventID)","messages":[{"symbol":"pass","text":"a"},{"symbol":"fail","text":"b"}]},"version":0}
        """
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            contradictoryEnded
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A testEnded with a passWithKnownIssue symbol is a recognized pass")
    func testEndedPassWithKnownIssueIsPass() throws {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let knownIssueEnded = """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(eventID)","messages":[{"symbol":"passWithKnownIssue","text":"a"}]},"version":0}
        """
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            knownIssueEnded
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()")
        #expect(evidence.passedTests == [expected])
        #expect(evidence.failedTests.isEmpty)
    }

    // MARK: - Declared-event accountability

    @Test("An event naming a test this stream never declared fails the whole stream closed")
    func undeclaredFunctionEventFailsClosed() {
        // "A" is declared and cleanly started/ended; "B" is not declared at
        // all, yet still gets its own testStarted -- exactly the shape an
        // undeclared, unaccountable test's evidence must not silently
        // vanish through.
        let declaredID = "WidgetsTests.WidgetsTests/widgetA()"
        let declaredEventID = "\(declaredID)/WidgetsTests.swift:6:6"
        let undeclaredEventID = "WidgetsTests.WidgetsTests/widgetB()/WidgetsTests.swift:9:6"
        let stream = [
            StreamFixtures.functionDeclaration(id: declaredID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: declaredEventID),
            StreamFixtures.testEnded(id: declaredEventID),
            StreamFixtures.testStarted(id: undeclaredEventID)
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported -- an event about an undeclared test must not silently vanish")
            return
        }
    }

    @Test("A case-scoped event naming a test this stream never declared fails the whole stream closed")
    func undeclaredCaseEventFailsClosed() {
        let declaredID = "WidgetsTests.WidgetsTests/widgetA()"
        let declaredEventID = "\(declaredID)/WidgetsTests.swift:6:6"
        let undeclaredEventID = "WidgetsTests.WidgetsTests/widgetB()/WidgetsTests.swift:9:6"
        let stream = [
            StreamFixtures.functionDeclaration(id: declaredID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: declaredEventID),
            StreamFixtures.testCaseStarted(id: undeclaredEventID)
        ].joined(separator: "\n")

        guard case .unsupported = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A testCancelled event is tracked in cancelledTests")
    func testCancelledIsTracked() throws {
        let functionID = "WidgetsTests.WidgetsTests/widgetA()"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "widgetA()"),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            StreamFixtures.testCancelled(id: eventID)
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()")
        #expect(evidence.cancelledTests == [expected])
    }

    @Test("A testCaseCancelled event folds into its parent function's cancelledTests")
    func testCaseCancelledFoldsIntoParent() throws {
        let functionID = "WidgetsTests.WidgetsTests/parameterized(_:)"
        let eventID = "\(functionID)/WidgetsTests.swift:6:6"
        let stream = [
            StreamFixtures.functionDeclaration(id: functionID, name: "parameterized(_:)", isParameterized: true),
            StreamFixtures.runStarted,
            StreamFixtures.testStarted(id: eventID),
            StreamFixtures.testCaseStarted(id: eventID),
            StreamFixtures.testCaseCancelled(id: eventID)
        ].joined(separator: "\n")

        guard case .parsed(let evidence) = SwiftTestingEventStreamParser.parse(Data(stream.utf8)) else {
            Issue.record("expected a parsed result")
            return
        }
        let expected = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/parameterized(_:)")
        #expect(evidence.cancelledTests == [expected])
    }
}
