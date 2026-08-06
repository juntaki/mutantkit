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

    func testIsPositive() {
        XCTAssertTrue(isPositive(5))
        XCTAssertFalse(isPositive(-5))
        // The boundary: kills a `>` -> `>=` mutant, which the two cases
        // above alone would miss (both sides of the boundary agree with
        // `>=` too).
        XCTAssertFalse(isPositive(0))
    }
}
