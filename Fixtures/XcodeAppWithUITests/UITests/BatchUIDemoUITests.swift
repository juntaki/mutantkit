import XCTest

/// Exists only so the scheme has a second test target alongside
/// `BatchUIDemoTests` — the shape `BatchXCTestRunBuilder` must handle
/// correctly: a mutation covered exclusively by the unit test target must
/// narrow the batch to that target alone, never launching this one with an
/// `OnlyTestIdentifiers` filter matching none of its own tests. This suite
/// is deliberately never selected by any acceptance test's mutation.
final class BatchUIDemoUITests: XCTestCase {
    func testAppLaunches() {
        XCUIApplication().launch()
    }
}
