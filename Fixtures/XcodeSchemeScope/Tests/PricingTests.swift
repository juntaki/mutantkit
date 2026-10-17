import XCTest
@testable import App

final class PricingTests: XCTestCase {
    func testReviewBoundary() {
        XCTAssertTrue(Pricing.needsReview(units: 101))
        XCTAssertFalse(Pricing.needsReview(units: 100))
        XCTAssertTrue(Pricing.needsReview(units: -1))
    }

    func testFree() {
        XCTAssertTrue(Pricing.isFree(units: 0))
        XCTAssertFalse(Pricing.isFree(units: 1))
    }
}
