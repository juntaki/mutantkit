import Testing

@testable import Billing

/// Phase C2 (competitive-parity program): proves Swift Testing support
/// under an Xcode *workspace* is real end to end. Mirrors
/// `SwiftTestingCheckoutTests` in the `XcodeProject` fixture.
///
/// Deliberately exercises only `isOverdue` — `requiresDeposit` is never
/// referenced here, so its mutants survive (see `SwiftTestingCheckoutTests`'
/// own doc comment for why this is `.survived`, not `.noCoverage`, under
/// this fixture's plain config).
/// The expected mutation outcomes are asserted by the acceptance test that
/// runs MutantKit against this fixture — see `XcodeSwiftTestingAcceptanceTests`.
@Suite("SwiftTestingBilling")
struct SwiftTestingBillingTests {
    /// Split into two `@Test` functions, mirroring `SwiftTestingCheckoutTests`.
    @Test("not overdue at exactly 30 days")
    func notOverdueAtBoundary() {
        #expect(Billing.isOverdue(daysLate: 30) == false)
    }

    @Test("overdue strictly after 30 days")
    func overdueAboveBoundary() {
        #expect(Billing.isOverdue(daysLate: 31) == true)
    }
}
