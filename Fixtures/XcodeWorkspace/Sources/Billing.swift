import Foundation

/// Deliberately mixed test quality, like every other fixture: the acceptance
/// test asserts which of these mutants must die and which must survive.
public enum Billing {
    /// Boundary-tested from both sides. Its mutants should be killed.
    public static func isOverdue(daysLate: Int) -> Bool {
        daysLate > 30
    }

    /// Untested. Its mutants should survive.
    public static func requiresDeposit(amount: Decimal) -> Bool {
        amount >= 500
    }
}
