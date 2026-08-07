import XCTest

@testable import BatchUIDemo

final class BatchUIDemoTests: XCTestCase {
    /// Both sides of the boundary, so every relational mutant on `>= 1` dies.
    /// This is the only test covering `isInStock` — a mutation there must
    /// narrow to only this identifier, never anything from the UI test
    /// target below.
    func testStockRequiresAtLeastOne() {
        XCTAssertFalse(AppDelegate.isInStock(count: 0))
        XCTAssertTrue(AppDelegate.isInStock(count: 1))
    }

    // `requiresConfirmation` is intentionally untested; its mutants must
    // survive.
}
