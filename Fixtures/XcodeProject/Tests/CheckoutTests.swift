import XCTest

@testable import Checkout

final class CheckoutTests: XCTestCase {
    /// Exercises the non-boundary values first. The `>=` → `>` mutant still
    /// passes this test, while `>=` → `<` fails immediately. Wave-based early
    /// kill therefore has one mutant to drop in wave 1 and one to carry into
    /// wave 2, instead of every mutant being detected by the same first test.
    func testCouponAboveMinimum() {
        XCTAssertFalse(Checkout.canApplyCoupon(subtotal: 19))
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 21))
    }

    /// The boundary witness. The `>=` → `>` mutant that survived
    /// `testCouponAboveMinimum` must be detected here in the next wave.
    func testCouponAtMinimum() {
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 20))
    }

    // `requiresSignature` and `expressCheckoutEnabled` are intentionally
    // untested; their mutants must survive.
}
