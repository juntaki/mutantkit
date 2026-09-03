import XCTest
import MatrixWidget

final class MatrixWidgetTests: XCTestCase {
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

    func testIsInvalid() {
        XCTAssertTrue(MatrixWidget.isInvalid(flag: false))
        XCTAssertFalse(MatrixWidget.isInvalid(flag: true))
    }

    func testGreeting() {
        XCTAssertEqual(MatrixWidget.greeting(), "hello")
    }

    func testLabel() {
        XCTAssertEqual(MatrixWidget.label(flag: true), "yes")
        XCTAssertEqual(MatrixWidget.label(flag: false), "no")
    }
}
