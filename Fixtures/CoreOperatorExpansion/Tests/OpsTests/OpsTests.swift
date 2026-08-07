import Testing

@testable import Ops

/// The expected mutation outcomes are asserted by the acceptance test that runs
/// MutantKit against this fixture. Changing these tests changes that expectation —
/// they are calibrated, not incidental.
@Suite("Ops")
struct OpsTests {
    @Test("label reports pass at and above 60, fail below it")
    func labelBothOutcomes() {
        #expect(Ops.label(forScore: 60) == "pass")
        #expect(Ops.label(forScore: 59) == "fail")
    }

    @Test("isInactive negates active")
    func isInactiveBothOutcomes() {
        #expect(Ops.isInactive(true) == false)
        #expect(Ops.isInactive(false) == true)
    }

    @Test("displayName prefers a non-nil name over the fallback")
    func displayNamePrefersNonNil() {
        #expect(Ops.displayName("Ada") == "Ada")
    }

    @Test("bonus is awarded only at tier 3")
    func bonusBothOutcomes() {
        #expect(Ops.bonus(forTier: 3) == 100)
        #expect(Ops.bonus(forTier: 1) == 0)
    }

    @Test("sum adds its two operands")
    func sumIsAddition() {
        #expect(Ops.sum(2, 3) == 5)
    }

    @Test("scale multiplies by the given factor")
    func scaleIsMultiplication() {
        #expect(Ops.scale(3, by: 4) == 12)
    }

    @Test("accumulate adds delta into the running total")
    func accumulateAddsDelta() {
        var total = 10
        Ops.accumulate(&total, by: 5)
        #expect(total == 15)
    }

    @Test("validate appends a warning when invalid, ok otherwise")
    func validateBothOutcomes() {
        var notes: [String] = []
        #expect(Ops.validate(true, notes: &notes) == true)
        #expect(notes == ["ok"])

        notes = []
        #expect(Ops.validate(false, notes: &notes) == false)
        #expect(notes == ["warning"])
    }

    @Test("elementCount counts 0 up to but excluding count")
    func elementCountExcludesCount() {
        #expect(Ops.elementCount(upTo: 4) == 4)
    }
}
