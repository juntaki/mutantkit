import XCTest

@testable import PerTestWidgets

/// F1-P0: Xcode-side mirror of `Fixtures/PerTestProfilingPartialFailure`
/// (SwiftPM). `widgetANeverFails` covers `widgetA()` and always passes, in
/// isolation or otherwise. `widgetBNeverProfiles` covers `widgetB()` but
/// fails unconditionally, every time. Pins that
/// `XcodeBuildAdapter.measurePerTestCoverage`'s per-test loop must never let
/// this become "widgetB() covers nothing" instead of "widgetB()'s coverage
/// is unknown" -- parity with P12-B Finding D's SwiftPM fix.
final class PerTestProfilingPartialFailureTests: XCTestCase {
    func testWidgetANeverFails() {
        XCTAssertEqual(PerTestWidgets.widgetA(), 1)
    }

    func testWidgetBNeverProfiles() {
        _ = PerTestWidgets.widgetB()
        XCTFail("deliberately unconditional failure: this test's per-test coverage run must never be treated as \"covers nothing\"")
    }
}
