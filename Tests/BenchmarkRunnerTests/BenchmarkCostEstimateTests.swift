@testable import BenchmarkRunner
import Testing

@Suite("BenchmarkCostEstimate / BenchmarkBudgetGuard")
struct BenchmarkCostEstimateTests {
    @Test("estimatedTotalSeconds sums setup + both tools when both candidate counts are known")
    func totalSumsBothTools() {
        let estimate = BenchmarkCostModel.estimate(
            projectID: "p", sourceScope: ["Sources/A.swift"], mutantKitCandidates: 4, muterCandidates: 3
        )
        #expect(estimate.estimatedMutantKitSeconds != nil)
        #expect(estimate.estimatedMuterSeconds != nil)
        #expect(estimate.estimatedTotalSeconds == estimate.estimatedSetupSeconds
            + estimate.estimatedMutantKitSeconds! + estimate.estimatedMuterSeconds!)
    }

    @Test("A nil Muter candidate count (unknown, no discovery-only mode) never fabricates a Muter estimate")
    func unknownMuterCandidatesStaysNil() {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: ["Sources/A.swift"], mutantKitCandidates: 4)
        #expect(estimate.muterCandidates == nil)
        #expect(estimate.estimatedMuterSeconds == nil)
        #expect(estimate.estimatedTotalSeconds == estimate.estimatedSetupSeconds + estimate.estimatedMutantKitSeconds!)
    }

    @Test("Confidence is always lowerBound — this benchmark has only ever run one calibration")
    func confidenceIsAlwaysLowerBound() {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: [], mutantKitCandidates: 1)
        #expect(estimate.confidence == .lowerBound)
    }

    @Test("An estimate under budget passes")
    func underBudgetPasses() throws {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: [], mutantKitCandidates: 1)
        try BenchmarkBudgetGuard.requireWithinBudget(
            estimate, maxEstimatedMinutes: 1000, maxMutantKitCandidates: 100, maxMuterCandidates: nil
        )
    }

    @Test("An estimate over the minute budget fails closed")
    func overMinuteBudgetFailsClosed() {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: [], mutantKitCandidates: 1000)
        #expect(throws: BenchmarkBudgetError.self) {
            try BenchmarkBudgetGuard.requireWithinBudget(
                estimate, maxEstimatedMinutes: 1, maxMutantKitCandidates: nil, maxMuterCandidates: nil
            )
        }
    }

    @Test("A candidate count over its own budget fails closed even if the time estimate is fine")
    func overCandidateBudgetFailsClosedIndependently() {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: [], mutantKitCandidates: 500)
        #expect(throws: BenchmarkBudgetError.self) {
            try BenchmarkBudgetGuard.requireWithinBudget(
                estimate, maxEstimatedMinutes: 100_000, maxMutantKitCandidates: 10, maxMuterCandidates: nil
            )
        }
    }

    @Test("allowOverride bypasses both checks — but only when explicitly set true")
    func explicitOverrideBypassesChecks() throws {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: [], mutantKitCandidates: 999_999)
        try BenchmarkBudgetGuard.requireWithinBudget(
            estimate, maxEstimatedMinutes: 1, maxMutantKitCandidates: 1, maxMuterCandidates: 1, allowOverride: true
        )
    }

    @Test("Nil budget limits never trigger a failure — an unset limit means unlimited, not zero")
    func nilLimitsNeverFail() throws {
        let estimate = BenchmarkCostModel.estimate(projectID: "p", sourceScope: [], mutantKitCandidates: 999_999)
        try BenchmarkBudgetGuard.requireWithinBudget(
            estimate, maxEstimatedMinutes: nil, maxMutantKitCandidates: nil, maxMuterCandidates: nil
        )
    }
}
