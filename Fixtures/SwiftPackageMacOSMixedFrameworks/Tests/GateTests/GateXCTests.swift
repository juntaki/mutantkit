import Foundation
import Gate
import XCTest

final class GateXCTests: XCTestCase {
    func testAnswer() {
        let expected = ProcessInfo.processInfo.environment["FIXTURE_BREAK_XCTEST"] == "1" ? 0 : 42
        XCTAssertEqual(Gate.answer(), expected)
    }
}
