import XCTest
import MatrixWidget

/// Half the coverage lives here (XCTest), half in
/// MatrixWidgetSwiftTestingTests.swift (Swift Testing) — same test bundle,
/// both frameworks, deliberately.
final class MatrixWidgetXCTestTests: XCTestCase {
    func testIsFeatureEnabled() {
        XCTAssertTrue(MatrixWidget.isFeatureEnabled())
    }

    func testIsAdultBoundary() {
        XCTAssertFalse(MatrixWidget.isAdult(age: 17))
        XCTAssertTrue(MatrixWidget.isAdult(age: 18))
        XCTAssertTrue(MatrixWidget.isAdult(age: 19))
    }

    func testBothRequired() {
        XCTAssertTrue(MatrixWidget.bothRequired(a: true, b: true))
        XCTAssertFalse(MatrixWidget.bothRequired(a: true, b: false))
        XCTAssertFalse(MatrixWidget.bothRequired(a: false, b: true))
        XCTAssertFalse(MatrixWidget.bothRequired(a: false, b: false))
    }
}
