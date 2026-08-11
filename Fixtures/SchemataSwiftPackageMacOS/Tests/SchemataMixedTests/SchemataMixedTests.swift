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

    func testMagicNumber() {
        XCTAssertEqual(magicNumber(), 42)
    }
}
