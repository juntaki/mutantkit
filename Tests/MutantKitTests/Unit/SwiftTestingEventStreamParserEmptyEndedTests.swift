@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Streams from a real `swiftpm-testing-helper --event-stream-version 0` run
/// of the same four-test Swift Testing suite, once on each toolchain, with the
/// instants, backtraces and source locations trimmed.
///
/// The older helper (Xcode 26.5) ends each function with a `pass`/`fail`
/// message. The newer one (Xcode 27) ends it with `"messages":[]` whatever the
/// outcome, and reports a failure only as an `issueRecorded` event.
private enum EmptyEndedFixtures {
    static let widgetA = "WidgetsTests.WidgetsTests/widgetA()"
    static let widgetB = "WidgetsTests.WidgetsTests/widgetB()"
    static let widgetAEvent = "\(widgetA)/WidgetsTests.swift:6:6"
    static let widgetBEvent = "\(widgetB)/WidgetsTests.swift:12:6"
    static let idA = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()")
    static let idB = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetB()")

    static let declarations = [
        StreamFixtures.suiteDeclaration,
        StreamFixtures.functionDeclaration(id: widgetA, name: "widgetA()"),
        StreamFixtures.functionDeclaration(id: widgetB, name: "widgetB()")
    ]

    static func runStarted() -> String {
        """
        {"kind":"event","payload":{"kind":"runStarted","messages":[{"symbol":"default","text":"Test run started."},{"symbol":"details","text":"Testing Library Version: 2084"}]},"version":0}
        """
    }

    static func runEnded(symbol: String) -> String {
        """
        {"kind":"event","payload":{"kind":"runEnded","messages":[{"symbol":"\(symbol)","text":"Test run with 2 tests in 1 suite ended."}]},"version":0}
        """
    }

    static func emptyEnded(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(id)","messages":[]},"version":0}
        """
    }

    static func startedEmpty(id: String) -> String {
        """
        {"kind":"event","payload":{"kind":"testStarted","testID":"\(id)","messages":[]},"version":0}
        """
    }

    static func issue(id: String?, symbol: String) -> String {
        let testID = id.map { "\"testID\":\"\($0)\"," } ?? ""
        return """
        {"kind":"event","payload":{"kind":"issueRecorded",\(testID)"messages":[{"symbol":"\(symbol)","text":"Expectation failed: 1 == 2"},{"symbol":"details","text":"1 == 2 → false"}]},"version":0}
        """
    }

    /// Xcode 27 shape: both tests pass, both `testEnded` events are empty.
    static func cleanNewShape(tail: [String]? = nil) -> String {
        (declarations + [
            runStarted(),
            StreamFixtures.suiteStarted(),
            startedEmpty(id: widgetAEvent),
            startedEmpty(id: widgetBEvent),
            emptyEnded(id: widgetAEvent),
            emptyEnded(id: widgetBEvent),
            StreamFixtures.suiteEnded()
        ] + (tail ?? [runEnded(symbol: "pass")])).joined(separator: "\n")
    }

    static func parse(_ stream: String) -> SwiftTestingEventStreamParser.ParseResult {
        SwiftTestingEventStreamParser.parse(Data(stream.utf8))
    }
}

@Suite("Swift Testing event stream parser: testEnded without messages")
struct SwiftTestingEventStreamParserEmptyEndedTests {
    @Test("Xcode 27 shape: empty testEnded with no issues and a passing run summary is a pass")
    func newShapeCleanRunIsPass() throws {
        guard case let .parsed(evidence) = EmptyEndedFixtures.parse(EmptyEndedFixtures.cleanNewShape()) else {
            Issue.record("expected a parsed result")
            return
        }
        #expect(evidence.passedTests == [EmptyEndedFixtures.idA, EmptyEndedFixtures.idB])
        #expect(evidence.failedTests.isEmpty)
        #expect(evidence.endedTests == [EmptyEndedFixtures.idA, EmptyEndedFixtures.idB])
    }

    @Test("Xcode 26.5 shape: testEnded with a pass message is still a pass")
    func oldShapeStillPasses() throws {
        let stream = (EmptyEndedFixtures.declarations + [
            EmptyEndedFixtures.runStarted(),
            StreamFixtures.testStarted(id: EmptyEndedFixtures.widgetAEvent),
            StreamFixtures.testEnded(id: EmptyEndedFixtures.widgetAEvent),
            StreamFixtures.testStarted(id: EmptyEndedFixtures.widgetBEvent),
            StreamFixtures.testEnded(id: EmptyEndedFixtures.widgetBEvent),
            EmptyEndedFixtures.runEnded(symbol: "pass")
        ]).joined(separator: "\n")
        guard case let .parsed(evidence) = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected a parsed result")
            return
        }
        #expect(evidence.passedTests == [EmptyEndedFixtures.idA, EmptyEndedFixtures.idB])
    }

    @Test("An empty testEnded with a fail issue for that test is a failure")
    func emptyEndedWithFailIssueIsFailure() throws {
        let stream = EmptyEndedFixtures.cleanNewShape(tail: [
            EmptyEndedFixtures.issue(id: EmptyEndedFixtures.widgetAEvent, symbol: "fail"),
            EmptyEndedFixtures.issue(id: EmptyEndedFixtures.widgetBEvent, symbol: "fail"),
            EmptyEndedFixtures.runEnded(symbol: "fail")
        ])
        guard case let .parsed(evidence) = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected a parsed result")
            return
        }
        #expect(evidence.failedTests == [EmptyEndedFixtures.idA, EmptyEndedFixtures.idB])
        #expect(evidence.passedTests.isEmpty)
    }

    @Test("A passing-looking sibling in a failing run cannot be proven, so the whole stream is unsupported")
    func siblingOfAFailureIsNotProvenPassing() {
        let stream = EmptyEndedFixtures.cleanNewShape(tail: [
            EmptyEndedFixtures.issue(id: EmptyEndedFixtures.widgetBEvent, symbol: "fail"),
            EmptyEndedFixtures.runEnded(symbol: "fail")
        ])
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("An empty testEnded in a run whose summary is a failure is unsupported, never a presumed pass")
    func emptyEndedInFailingRunWithoutIssueIsUnsupported() {
        let stream = EmptyEndedFixtures.cleanNewShape(tail: [EmptyEndedFixtures.runEnded(symbol: "fail")])
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("An empty testEnded without any run summary is unsupported")
    func emptyEndedWithoutRunSummaryIsUnsupported() {
        let stream = EmptyEndedFixtures.cleanNewShape(tail: [])
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A run summary with no pass symbol is unsupported")
    func emptyEndedWithInformationalRunSummaryIsUnsupported() {
        let stream = EmptyEndedFixtures.cleanNewShape(tail: [EmptyEndedFixtures.runEnded(symbol: "default")])
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("An empty testEnded with only a non-failing issue (known issue) is unsupported")
    func emptyEndedWithKnownIssueIsUnsupported() {
        let stream = EmptyEndedFixtures.cleanNewShape(tail: [
            EmptyEndedFixtures.issue(id: EmptyEndedFixtures.widgetAEvent, symbol: "passWithKnownIssue"),
            EmptyEndedFixtures.runEnded(symbol: "pass")
        ])
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("An empty testEnded for a test that never started is unsupported")
    func emptyEndedWithoutStartIsUnsupported() {
        let stream = (EmptyEndedFixtures.declarations + [
            EmptyEndedFixtures.runStarted(),
            EmptyEndedFixtures.emptyEnded(id: EmptyEndedFixtures.widgetAEvent),
            EmptyEndedFixtures.runEnded(symbol: "pass")
        ]).joined(separator: "\n")
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("A message-bearing testEnded without a terminal symbol is still unsupported")
    func nonEmptyMessagesWithoutTerminalSymbolStayUnsupported() {
        let ambiguous = """
        {"kind":"event","payload":{"kind":"testEnded","testID":"\(EmptyEndedFixtures.widgetAEvent)","messages":[{"symbol":"details","text":"x"}]},"version":0}
        """
        let stream = (EmptyEndedFixtures.declarations + [
            EmptyEndedFixtures.runStarted(),
            EmptyEndedFixtures.startedEmpty(id: EmptyEndedFixtures.widgetAEvent),
            ambiguous,
            EmptyEndedFixtures.runEnded(symbol: "pass")
        ]).joined(separator: "\n")
        guard case .unsupported = EmptyEndedFixtures.parse(stream) else {
            Issue.record("expected unsupported")
            return
        }
    }
}
