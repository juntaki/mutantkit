import XCTest

@testable import Widgets

/// XCTest, not Swift Testing, on purpose: SwiftPM filters XCTest itself
/// (`swift test --filter` narrows the process before it runs, unlike Swift
/// Testing's runtime-side filtering), so this fixture's per-test isolation
/// works correctly today, independent of the separate Swift Testing
/// filter-escaping bug this investigation is also fixing. That independence
/// is the whole point: `widgetBNeverProfiles` must fail its own isolated
/// run for a reason with nothing to do with filter generation, so this
/// fixture keeps meaning what it is supposed to mean before, during and
/// after Phase B2 lands.
///
/// `widgetANeverFails` covers `widgetA()` and always passes, in isolation or
/// otherwise. `widgetBNeverProfiles` covers `widgetB()` but fails
/// unconditionally, every time. See
/// Fixtures/PerTestProfilingPartialFailure in the P12-B investigation for
/// what this pins.
final class WidgetsTests: XCTestCase {
    func testWidgetANeverFails() {
        XCTAssertEqual(Widgets.widgetA(), 1)
    }

    func testWidgetBNeverProfiles() {
        _ = Widgets.widgetB()
        XCTFail("deliberately unconditional failure: this test's per-test coverage run must never be treated as \"covers nothing\"")
    }
}
