import Foundation

/// Mixed test quality, same as the other fixtures: the acceptance test asserts
/// which of these mutants must die and which must survive.
public enum Checkout {
    /// Boundary-tested. Its mutants should be killed.
    public static func canApplyCoupon(subtotal: Decimal) -> Bool {
        subtotal >= 20
    }

    /// Untested. Its mutants should survive.
    public static func requiresSignature(itemCount: Int) -> Bool {
        itemCount > 5
    }

    public static var expressCheckoutEnabled: Bool = true
}
