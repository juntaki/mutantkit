import XCTest

@testable import Formatting

/// XCTest rather than Swift Testing, deliberately: the two frameworks report
/// differently, and the adapter must read both correctly from the same
/// `.xcresult`. The macOS fixture covers Swift Testing; this one covers XCTest.
final class BadgeFormatterTests: XCTestCase {
    /// Both sides of the boundary. Every relational mutant on `> 99` dies here.
    func testBadgeTextCapsAtNinetyNinePlus() {
        XCTAssertEqual(BadgeFormatter.text(forCount: 99), "99")
        XCTAssertEqual(BadgeFormatter.text(forCount: 100), "99+")
    }

    func testBadgeTextShowsExactSmallCounts() {
        XCTAssertEqual(BadgeFormatter.text(forCount: 0), "0")
        XCTAssertEqual(BadgeFormatter.text(forCount: 7), "7")
    }

    // `isProminent` and `color(forCount:)` are intentionally untested, so their
    // mutants must survive. A run that reports them killed is reporting a
    // mutation it did not really make.
}
