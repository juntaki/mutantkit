import XCTest

/// Exercises faults that only exist in a realized UI/accessibility tree —
/// exactly the gap Phase 5A's substrate exists to close. See
/// `Sources/ContentView.swift` for what each test is really checking, and
/// the internal Phase 5A UI-test-substrate research record (not part of
/// this public repo) for the substrate this fixture validates.
final class AccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// GREEN on the real source (`.accessibilityLabel("Close")` present).
    /// RED when that line is manually removed — an icon-only button then
    /// exposes no name to the accessibility tree at all, so the query below
    /// finds nothing.
    func testCloseButtonHasAccessibilityLabel() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.buttons["Close"].waitForExistence(timeout: 5),
            "The close button must expose an accessibility label of 'Close'."
        )
    }

    /// Same fault as above, caught a second, independent way: `xcodebuild`'s
    /// own accessibility audit (iOS 17+) flags a control with no accessible
    /// name as a real audit issue, not merely a query that fails to match.
    func testAccessibilityAuditFindsNoIssues() throws {
        let app = XCUIApplication()
        app.launch()

        try app.performAccessibilityAudit()
    }

    /// GREEN on the real source (`.contentShape(Rectangle())` present, so
    /// the row's whole frame is tappable). RED when that line is manually
    /// removed — SwiftUI then only hit-tests the row's actually-drawn
    /// content (the two `Text` glyphs), so a tap dead center, in the empty
    /// space between them, never reaches the button's action at all.
    func testTappingFarFromTextStillTriggersAction() {
        let app = XCUIApplication()
        app.launch()

        let row = app.buttons["itemRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        let label = app.staticTexts["tapCountLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertEqual(label.label, "Taps: 0")

        // Dead center of the row: deliberately between "Item" (pinned left)
        // and "$9.99" (pinned right, via the HStack's Spacer), where no text
        // glyph exists.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertEqual(label.label, "Taps: 1")
    }
}
