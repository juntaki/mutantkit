import XCTest

@testable import Pricing

/// Phase C2 (competitive-parity program): proves SwiftPM + XCTest is real,
/// acceptance-tested end to end. Mirrors `PricingTests`' own coverage
/// pattern for `qualifiesForSeniorRate`, but leaves `bulkDiscountRate` and
/// `isFreeShipping` completely unreferenced -- under this target's own,
/// separate coverage universe, both are `noCoverage`, not `survived`.
///
/// The expected mutation outcomes are asserted by the acceptance test that
/// runs MutantKit against this fixture — see
/// `SwiftPackageMacOSXCTestAcceptanceTests`.
final class PricingXCTestTests: XCTestCase {
    /// Both sides of the boundary. Kills every relational mutant on `>= 65`.
    func testSeniorRateBoundary() {
        XCTAssertFalse(Pricing.qualifiesForSeniorRate(age: 64))
        XCTAssertTrue(Pricing.qualifiesForSeniorRate(age: 65))
        XCTAssertTrue(Pricing.qualifiesForSeniorRate(age: 66))
    }
}
