import Testing

@testable import Checkout

/// Phase C2 (competitive-parity program): proves Swift Testing support under
/// an Xcode *project* (as opposed to SwiftPM, which `SwiftPackageMacOS`'s
/// `PricingTests` already covers) is real end to end — real `@Test`/
/// `#expect`, run via `xcodebuild` against a real iOS Simulator, read back
/// from the same `.xcresult` structured data XCTest already uses, with a
/// verdict for every mutant.
///
/// Deliberately exercises only `canApplyCoupon` — `requiresSignature` and
/// `expressCheckoutEnabled` are never referenced here at all, so their
/// mutants survive (this fixture's plain config never requests per-test
/// coverage attribution, so this is the same fail-safe "run the full
/// target" behavior `CheckoutTests`' own identically-unconfigured XCTest
/// run relies on for the same declarations — see
/// `XcodeSwiftTestingAcceptanceTests` for the full account, including a
/// recorded, unresolved finding that `selectCoveringTests: true` does not
/// currently narrow attribution for this scheme the way it does for
/// `Checkout`/`CheckoutTests`).
/// The expected mutation outcomes are asserted by the acceptance test that
/// runs MutantKit against this fixture — see `XcodeSwiftTestingAcceptanceTests`.
@Suite("SwiftTestingCheckout")
struct SwiftTestingCheckoutTests {
    /// Split into two `@Test` functions, mirroring `CheckoutTests`' own
    /// two-witness structure.
    @Test("coupon does not apply below the boundary")
    func couponBelowBoundary() {
        #expect(Checkout.canApplyCoupon(subtotal: 19) == false)
    }

    @Test("coupon applies at and above the boundary")
    func couponAtBoundary() {
        #expect(Checkout.canApplyCoupon(subtotal: 20) == true)
    }
}
