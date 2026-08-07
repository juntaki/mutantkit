import XCTest

@testable import Billing

final class BillingTests: XCTestCase {
    /// Both sides of the boundary, so every relational mutant on `> 30` dies.
    func testOverdueStartsAfterThirtyDays() {
        XCTAssertFalse(Billing.isOverdue(daysLate: 30))
        XCTAssertTrue(Billing.isOverdue(daysLate: 31))
    }

    // `requiresDeposit` is intentionally untested; its mutants must survive.
}
