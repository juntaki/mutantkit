@testable import CompatibilityGate
import XCTest

final class ToggleTests: XCTestCase {
    func testZero() {
        XCTAssertTrue(isZero(0))
    }

    func testNonZero() {
        XCTAssertFalse(isZero(1))
    }
}
