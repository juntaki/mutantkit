@testable import AppleBuildAdapters
import Foundation
import MutationExecution
@testable import MutationModel
import Testing

/// A Swift Testing test selected through SwiftPM was recorded as
/// `Target/Suite/method()()`, so its own failure was rejected as outside the
/// selection. The identity is now recorded once, and a record that already
/// carries the doubled list is still read as that test.
@Suite("Swift Testing selection identity")
struct SwiftTestingSelectionIdentityTests {
    private func inside(_ failing: String, selected: [String]) -> Bool {
        let execution = TestExecutionRecord(attribution: .standalone, selectedTests: selected)
        return AssertionKillAttribution.evaluate(execution: execution, failingTests: [failing]).disposition == .withinSelection
    }

    @Test("SwiftPM enumeration of Swift Testing and XCTest records each selection once")
    func selectionStringsAsStored() {
        let listed = SwiftPackageMacOSAdapter.parseTestIdentifiers("""
        CoreTests.ThresholdTests/belowBoundaryIsNotLarge()
        PricingTests.PricingXCTests/testSeniorRate
        """)
        #expect(listed.map(\.onlyTestingArgument) == [
            "CoreTests/ThresholdTests/belowBoundaryIsNotLarge()",
            "PricingTests/PricingXCTests/testSeniorRate()"
        ])
    }

    @Test("Xcode enumeration, which strips the parentheses, is unchanged")
    func xcodeIdentifiersUnchanged() {
        let identifier = TestIdentifier(target: "AppTests", qualifiedName: "AppTests/check")
        #expect(identifier.onlyTestingArgument == "AppTests/AppTests/check()")
    }

    @Test("A recorded Swift Testing selection matches the failing names SwiftPM and xcresult report")
    func failingNamesMatch() {
        let selected = ["CoreTests/ThresholdTests/belowBoundaryIsNotLarge()"]
        for failing in [
            "CoreTests.ThresholdTests/belowBoundaryIsNotLarge()", "ThresholdTests/belowBoundaryIsNotLarge()",
            "CoreTests/ThresholdTests/belowBoundaryIsNotLarge()"
        ] {
            #expect(inside(failing, selected: selected), "\(failing)")
        }
    }

    @Test("A selection already recorded with the doubled list is read as the same test")
    func doubledListIsTolerated() {
        let recorded = ["CoreTests/ThresholdTests/belowBoundaryIsNotLarge()()"]
        #expect(inside("CoreTests.ThresholdTests/belowBoundaryIsNotLarge()", selected: recorded))
        #expect(inside("ThresholdTests/belowBoundaryIsNotLarge()", selected: recorded))
    }

    @Test("Tolerating the doubled list does not widen matching")
    func conservativeRulesStillHold() {
        let recorded = ["CoreTests/ThresholdTests/belowBoundaryIsNotLarge()()"]
        #expect(!inside("CoreTests.OtherTests/belowBoundaryIsNotLarge()", selected: recorded))
        #expect(!inside("belowBoundaryIsNotLarge()", selected: recorded))
        #expect(!inside("CoreTests.ThresholdTests/belowBoundaryIsNotLarge(x:)", selected: recorded))
        let parameterized = ["CoreTests/ThresholdTests/belowBoundaryIsNotLarge(x:)()"]
        #expect(!inside("CoreTests.ThresholdTests/belowBoundaryIsNotLarge", selected: parameterized))
        // A parameter list is never collapsed into an empty one.
        #expect(!inside("S/m()", selected: ["T/S/m(a:)()"]))
        // An ambiguous identifier (no owner) is still not inside the selection.
        #expect(!inside("m()", selected: ["T/S/m()()"]))
    }
}
