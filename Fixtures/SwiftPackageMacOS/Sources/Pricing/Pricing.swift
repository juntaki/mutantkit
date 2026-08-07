import Foundation

/// Deliberately mixed test quality: some rules below are pinned by tests and
/// some are not. A correct mutation run must kill the first kind and let the
/// second kind survive — a fixture where everything dies proves nothing.
public struct Pricing {
    public var loyaltyDiscountEnabled: Bool

    public init(loyaltyDiscountEnabled: Bool = true) {
        self.loyaltyDiscountEnabled = loyaltyDiscountEnabled
    }

    /// Well tested, including both sides of the boundary.
    /// Every mutant here should be killed.
    public static func qualifiesForSeniorRate(age: Int) -> Bool {
        age >= 65
    }

    /// Tested only in the middle of each branch, never at the boundary itself.
    /// The `>` → `>=` boundary mutant should SURVIVE: that is the off-by-one
    /// this suite cannot see.
    public static func bulkDiscountRate(itemCount: Int) -> Double {
        if itemCount > 10 {
            return 0.15
        }
        return 0.0
    }

    /// Not tested at all. Its mutants should survive.
    public static func isFreeShipping(total: Double) -> Bool {
        total >= 50.0
    }

    public func total(subtotal: Double, itemCount: Int, age: Int) -> Double {
        var rate = Self.bulkDiscountRate(itemCount: itemCount)

        if loyaltyDiscountEnabled, Self.qualifiesForSeniorRate(age: age) {
            rate += 0.05
        }

        return subtotal * (1.0 - rate)
    }
}
