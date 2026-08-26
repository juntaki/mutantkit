@testable import BenchmarkRunner
import Testing

@Suite("BenchmarkValidityGuard (Phase B3.6)")
struct BenchmarkValidityGuardTests {
    @Test("Zero discovered mutants, clean exit, non-empty scope, no zero-mutants expectation: invalid")
    func zeroDiscoveredWithNonEmptyScopeIsInvalid() {
        let violation = BenchmarkValidityGuard.validate(
            tool: "swift-mutation-testing", toolExitedSuccessfully: true, requestedScopeIsNonEmpty: true,
            discoveredCount: 0, zeroMutantsExpected: false
        )
        #expect(violation != nil)
        #expect(violation?.description.contains("swift-mutation-testing") == true)
    }

    @Test("Non-zero discovered count is always valid, regardless of scope/expectation")
    func nonZeroDiscoveredIsAlwaysValid() {
        let violation = BenchmarkValidityGuard.validate(
            tool: "mutantkit", toolExitedSuccessfully: true, requestedScopeIsNonEmpty: true,
            discoveredCount: 5, zeroMutantsExpected: false
        )
        #expect(violation == nil)
    }

    @Test("A crashed or timed-out tool is never flagged by this guard — that failure is already visible elsewhere")
    func failedExecutionIsNotFlaggedByThisGuard() {
        let violation = BenchmarkValidityGuard.validate(
            tool: "muter", toolExitedSuccessfully: false, requestedScopeIsNonEmpty: true,
            discoveredCount: 0, zeroMutantsExpected: false
        )
        #expect(violation == nil)
    }

    @Test("An explicitly empty requested scope is exempt — nothing was asked of the tool")
    func emptyRequestedScopeIsExempt() {
        let violation = BenchmarkValidityGuard.validate(
            tool: "muter", toolExitedSuccessfully: true, requestedScopeIsNonEmpty: false,
            discoveredCount: 0, zeroMutantsExpected: false
        )
        #expect(violation == nil)
    }

    @Test("A fixture-documented zero-mutants expectation is exempt")
    func fixtureDocumentedZeroIsExempt() {
        let violation = BenchmarkValidityGuard.validate(
            tool: "muter", toolExitedSuccessfully: true, requestedScopeIsNonEmpty: true,
            discoveredCount: 0, zeroMutantsExpected: true
        )
        #expect(violation == nil)
    }
}
