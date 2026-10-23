import Testing

@testable import Alpha

@Suite("Alpha")
struct AlphaTests {
    @Test("an adult is 18 or older")
    func adultBoundary() {
        #expect(Alpha.isAdult(age: 17) == false)
        #expect(Alpha.isAdult(age: 18) == true)
    }
}

/// Skipped under every configuration: exercises how a test that never runs is attributed.
@Suite("Alpha (disabled)", .disabled("exercises the skipped-test path"))
struct DisabledAlphaTests {
    @Test("never runs")
    func neverRuns() {
        #expect(Alpha.isAdult(age: 18))
    }
}
