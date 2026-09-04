import XCTest
import CoverageGapWidget

final class CoverageGapWidgetTests: XCTestCase {
    func testCoveredFlag() {
        XCTAssertTrue(coveredFlag())
    }
}
