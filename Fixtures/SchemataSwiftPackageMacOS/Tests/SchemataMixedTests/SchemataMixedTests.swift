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

    func testNegated() {
        XCTAssertFalse(negated(true))
        XCTAssertTrue(negated(false))
    }
}
