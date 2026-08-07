import Foundation
import MutationModel
import Testing

/// `OperatorBudgetSummary.tally` is what lets a plan answer "how many
/// eligible/selected/budgetDropped mutants did each operator have" without a
/// separate bookkeeping structure — it reads straight off `plan.mutations`
/// and `plan.skipped`, the same two lists the integrity checker already
/// treats as the plan's single source of truth.
@Suite("Operator budget summary")
struct OperatorBudgetSummaryTests {
    @Test("selected counts come from mutations, budgetDropped only from .budgetExceeded skips")
    func tallyCountsSelectedAndBudgetDropped() {
        let selectedA = BudgetSelectorTests.point(
            id: "a-selected", file: "Sources/A.swift", rawID: "a-selected", operatorID: "op.a"
        )
        let selectedB = BudgetSelectorTests.point(
            id: "b-selected", file: "Sources/B.swift", rawID: "b-selected", operatorID: "op.b"
        )
        let droppedA = SkippedMutation(
            id: MutationID(rawValue: "a-dropped"), file: "Sources/A.swift",
            reason: .budgetExceeded, operatorID: "op.a"
        )
        // A non-budget skip must not count toward budgetDropped or eligible —
        // the budget gate never even considered a confidence-floor drop.
        let confidenceDropped = SkippedMutation(
            id: MutationID(rawValue: "c-dropped"), file: "Sources/C.swift",
            reason: .confidenceBelowProfile, operatorID: "op.c"
        )

        let summary = OperatorBudgetSummary.tally(
            mutations: [selectedA, selectedB],
            skipped: [droppedA, confidenceDropped]
        )

        let byOperator = Dictionary(uniqueKeysWithValues: summary.map { ($0.operatorID, $0) })
        #expect(byOperator["op.a"] == OperatorBudgetSummary(operatorID: "op.a", eligible: 2, selected: 1, budgetDropped: 1))
        #expect(byOperator["op.b"] == OperatorBudgetSummary(operatorID: "op.b", eligible: 1, selected: 1, budgetDropped: 0))
        // op.c was skipped for a reason other than budget, so it never
        // appears in a budget summary at all.
        #expect(byOperator["op.c"] == nil)
    }

    @Test("An operator with no budget-exceeded skips reports budgetDropped: 0")
    func operatorWithNoDropsReportsZero() {
        let selected = BudgetSelectorTests.point(
            id: "only", file: "Sources/A.swift", rawID: "only", operatorID: "op.a"
        )

        let summary = OperatorBudgetSummary.tally(mutations: [selected], skipped: [])

        #expect(summary == [OperatorBudgetSummary(operatorID: "op.a", eligible: 1, selected: 1, budgetDropped: 0)])
    }

    @Test("Results are sorted by operatorID")
    func resultsAreSortedByOperatorID() {
        let points = ["op.z", "op.a", "op.m"].map { operatorID in
            BudgetSelectorTests.point(id: operatorID, file: "Sources/A.swift", rawID: operatorID, operatorID: operatorID)
        }

        let summary = OperatorBudgetSummary.tally(mutations: points, skipped: [])

        #expect(summary.map(\.operatorID) == ["op.a", "op.m", "op.z"])
    }

    @Test("An operator skipped entirely before the budget gate (e.g. disabled) does not appear")
    func operatorSkippedBeforeBudgetGateDoesNotAppear() {
        let onlySkip = SkippedMutation(
            id: MutationID(rawValue: "x"), file: "Sources/X.swift",
            reason: .outsideDiff, operatorID: "op.x"
        )

        let summary = OperatorBudgetSummary.tally(mutations: [], skipped: [onlySkip])

        #expect(summary.isEmpty)
    }
}
