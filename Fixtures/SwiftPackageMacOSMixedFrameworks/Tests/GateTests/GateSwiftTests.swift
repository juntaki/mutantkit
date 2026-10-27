import Foundation
import Gate
import Testing

@Suite struct GateSwiftTests {
    @Test func answerIsPositive() {
        #expect(Gate.answer() > 0)
    }

    @Test func endsProcessOnRequest() {
        if ProcessInfo.processInfo.environment["FIXTURE_EXIT"] == "1" {
            exit(1)
        }
        #expect(Gate.answer() == 42)
    }
}
