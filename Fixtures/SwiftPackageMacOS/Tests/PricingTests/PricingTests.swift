import Testing

@testable import Pricing

/// The expected mutation outcomes are asserted by the acceptance test that runs
/// MutantKit against this fixture. Changing these tests changes that expectation —
/// they are calibrated, not incidental.
@Suite("Pricing")
struct PricingTests {
    /// Both sides of the boundary. Pins `>=` completely: `>` fails at 65, `<`
    /// and `<=` fail at 64, so every relational mutant here dies.
    @Test("senior rate applies from 65 and not before")
    func seniorRateBoundary() {
        #expect(Pricing.qualifiesForSeniorRate(age: 64) == false)
        #expect(Pricing.qualifiesForSeniorRate(age: 65) == true)
        #expect(Pricing.qualifiesForSeniorRate(age: 66) == true)
    }

    /// Deliberately weak: samples well inside each branch and never at 10 or 11.
    /// The negation mutants die here, but `>` → `>=` survives, because nothing
    /// distinguishes "more than 10" from "10 or more" at these inputs.
    @Test("bulk discount applies to large orders")
    func bulkDiscountRoughly() {
        #expect(Pricing.bulkDiscountRate(itemCount: 3) == 0.0)
        #expect(Pricing.bulkDiscountRate(itemCount: 50) == 0.15)
    }

    @Test("loyalty discount stacks with the senior rate")
    func totalWithLoyalty() {
        let pricing = Pricing(loyaltyDiscountEnabled: true)
        #expect(pricing.total(subtotal: 100, itemCount: 50, age: 70) == 80.0)
    }

    @Test("loyalty discount can be turned off")
    func totalWithoutLoyalty() {
        let pricing = Pricing(loyaltyDiscountEnabled: false)
        #expect(pricing.total(subtotal: 100, itemCount: 50, age: 70) == 85.0)
    }
}
