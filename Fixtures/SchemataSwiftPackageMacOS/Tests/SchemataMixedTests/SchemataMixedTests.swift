import XCTest
import SchemataMixed

final class SchemataMixedTests: XCTestCase {
    func testKilledFlag() {
        XCTAssertTrue(killedFlag())
    }

    func testSurvivedFlagIsCalled() {
        _ = survivedFlag()
        XCTAssertTrue(true)
    }

    func testPick() {
        XCTAssertEqual(pick(true), 1)
        XCTAssertEqual(pick(false), 2)
    }

    func testSum() {
        XCTAssertEqual(sum(2, 3), 5)
    }
}
