import Testing

@testable import Spin

@Suite("Spin")
struct SpinTests {
    /// Calls `settle()` with no argument on purpose: the mutation is on the
    /// default, so the hang only happens if the default is the one being used.
    @Test("settle returns immediately")
    func settleReturnsImmediately() {
        #expect(Spin.settle() == 0)
    }

    /// Both sides of the boundary, so every relational mutant here dies fast.
    @Test("isPositive is exclusive of zero")
    func isPositiveBoundary() {
        #expect(Spin.isPositive(1) == true)
        #expect(Spin.isPositive(0) == false)
        #expect(Spin.isPositive(-1) == false)
    }
}
