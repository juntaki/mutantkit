import Testing

@testable import Core

/// Pins `>=` on both sides of the boundary, so every relational mutant of
/// `isLarge` dies: 5 maps to exactly 10, 4 maps to 8.
@Suite("Threshold")
struct ThresholdTests {
    @Test("the boundary value counts as large")
    func boundaryIsLarge() {
        #expect(Threshold.isLarge(5) == true)
    }

    @Test("below the boundary is not large")
    func belowBoundaryIsNotLarge() {
        #expect(Threshold.isLarge(4) == false)
    }
}
