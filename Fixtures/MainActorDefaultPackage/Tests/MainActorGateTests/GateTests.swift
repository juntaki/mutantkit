import MainActorGate
import XCTest

@MainActor
final class GateTests: XCTestCase {
    func testIsOpen() {
        XCTAssertTrue(Gate.isOpen())
    }

    func testIsAdultAwayFromTheBoundary() {
        XCTAssertFalse(Gate.isAdult(age: 17))
        XCTAssertTrue(Gate.isAdult(age: 19))
    }
}
