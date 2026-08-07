import XCTest

@testable import DebugDylibDemo

final class DebugDylibDemoTests: XCTestCase {
    /// Both sides of the boundary, so every relational mutant on `>= 1` dies.
    func testStockRequiresAtLeastOne() {
        XCTAssertFalse(AppDelegate.isInStock(count: 0))
        XCTAssertTrue(AppDelegate.isInStock(count: 1))
    }

    // `requiresConfirmation` is intentionally untested; its mutants must
    // survive.
}
