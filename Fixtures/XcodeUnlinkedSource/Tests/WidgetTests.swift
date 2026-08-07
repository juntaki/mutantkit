import XCTest

@testable import UnlinkedSource

final class WidgetTests: XCTestCase {
    func testInStockBoundary() {
        XCTAssertFalse(Widget.isInStock(count: 0))
        XCTAssertTrue(Widget.isInStock(count: 1))
    }
}
