import Foundation
import MutationExecution
import MutationModel
import Testing

/// Direct unit tests for `TimeoutController.mutantLimitSeconds(selectedTests:)`.
/// A `10...30`s, `selectedTests.count`-scaled clamp lived here previously;
/// Gate 3's real-iOS-project run found it uncalibrated (see
/// `TimeoutController.swift`'s doc comment and
/// `Research/benchmarks/gate3-ios-schemata-2026-08-23`), so this now always
/// answers with the whole-suite-scaled `mutantLimitSeconds`, regardless of
/// `selectedTests` — the same fallback `nil`/empty already used.
@Suite("Timeout controller: selected-test-aware resolution")
struct TimeoutControllerTests {
    private let addTest = TestIdentifier(target: "FooTests", qualifiedName: "AddTests/testAdd")
    private let subTest = TestIdentifier(target: "FooTests", qualifiedName: "SubTests/testSub")
    private let mulTest = TestIdentifier(target: "FooTests", qualifiedName: "MulTests/testMul")

    private func controller(baselineDuration: Double = 62) -> TimeoutController {
        let settings = TimeoutSettings(
            mutant: MutantTimeoutSettings(
                strategy: .adaptive, multiplier: 3, minimumSeconds: 30, maximumSeconds: 300,
                overheadAllowanceSeconds: 60
            )
        )
        return TimeoutController(settings: settings, baselineDurationSeconds: baselineDuration)
    }

    @Test("A known, non-empty selection resolves to the same whole-suite number, not a narrower clamp")
    func selectionPresentMatchesWholeSuite() {
        let controller = controller()
        // 62s baseline -> whole-suite mutantLimitSeconds = min(max(62*3+60, 30), 300) = 246.
        #expect(controller.mutantLimitSeconds == 246)

        let resolved = controller.mutantLimitSeconds(selectedTests: [addTest])

        #expect(resolved == controller.mutantLimitSeconds)
    }

    @Test("A single selected test does not resolve to a small floor")
    func singleTestDoesNotResolveToFloor() {
        let controller = controller()

        let resolved = controller.mutantLimitSeconds(selectedTests: [addTest])

        #expect(resolved == controller.mutantLimitSeconds)
    }

    @Test("Selection size never changes the resolved limit")
    func selectionSizeNeverChangesResolvedLimit() {
        let controller = controller()

        let one = controller.mutantLimitSeconds(selectedTests: [addTest])
        let three = controller.mutantLimitSeconds(selectedTests: [addTest, subTest, mulTest])

        #expect(one == controller.mutantLimitSeconds)
        #expect(three == controller.mutantLimitSeconds)
    }

    @Test("nil selectedTests resolves to the whole-suite-scaled limit unchanged")
    func nilSelectionFallsBack() {
        let controller = controller()

        let resolved = controller.mutantLimitSeconds(selectedTests: nil)

        #expect(resolved == controller.mutantLimitSeconds)
    }

    @Test("An empty selectedTests set resolves to the whole-suite-scaled limit unchanged")
    func emptySelectionFallsBack() {
        let controller = controller()

        let resolved = controller.mutantLimitSeconds(selectedTests: [])

        #expect(resolved == controller.mutantLimitSeconds)
    }

    @Test("Before a baseline is recorded, the selected-test path still matches the unselected one")
    func selectedTestPathWorksWithoutBaseline() {
        let controller = TimeoutController(settings: TimeoutSettings())

        let resolved = controller.mutantLimitSeconds(selectedTests: [addTest])

        #expect(resolved == controller.mutantLimitSeconds)
    }
}
