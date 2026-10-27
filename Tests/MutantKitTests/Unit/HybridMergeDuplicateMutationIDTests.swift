import Foundation
@testable import MutationExecution
import MutationModel
import Testing

/// A hybrid run records exactly one result per MutationID. The merge
/// used to insert both portions with `try? ledger.insert`, so a second result
/// for the same MutationID was silently dropped (first-wins). That hides a
/// double MutationID, which must stop the run. A duplicate is now a run-level
/// failure: no report, never first-wins or last-wins.
@Suite("Hybrid merge fails closed on a duplicate MutationID")
struct HybridMergeDuplicateMutationIDTests {
    @Test("A schemata result and a fallback result for the same MutationID fail the merge")
    func schemataAndFallbackDuplicateFails() throws {
        let m1 = try makeAnchoredPoint()
        let schemata = makeResult(point: m1, outcome: .killedByAssertion)
        let fallback = makeResult(point: m1, outcome: .survived)

        #expect(throws: HybridExecutionEngine.EngineError.duplicateMutationResult(
            mutationID: m1.id.rawValue, portions: "schemata + isolated fallback"
        )) {
            _ = try HybridExecutionEngine.mergedLedger(schemataResults: [schemata], fallbackResults: [fallback])
        }
    }

    /// The realistic shape. The schemata portion stamps refs with
    /// `workUnitID = plan.planID`. The fallback `MutationRunner` stamps them
    /// with its own `fallbackPlan.workUnitID`, a digest of the fallback
    /// subset. The two refs for M1 therefore differ, and `ResultLedger`
    /// (keyed by the whole ref) would accept both. The merge has to check
    /// MutationID itself, as `PlanSharding.merge` does for shards.
    @Test("A duplicate MutationID fails the merge even when the two portions' refs differ")
    func duplicateAcrossDifferentWorkUnitsFails() throws {
        let m1 = try makeAnchoredPoint()
        let fallbackPlan = makePlan(mutations: [m1])
        #expect(fallbackPlan.workUnitID != fallbackPlan.planID)
        let schemata = makeResult(
            point: m1, outcome: .killedByAssertion, planID: fallbackPlan.planID, workUnitID: fallbackPlan.planID
        )
        let fallback = makeResult(
            point: m1, outcome: .survived, planID: fallbackPlan.planID, workUnitID: fallbackPlan.workUnitID
        )
        #expect(schemata.mutationRef != fallback.mutationRef)

        #expect(throws: HybridExecutionEngine.EngineError.duplicateMutationResult(
            mutationID: m1.id.rawValue, portions: "schemata + isolated fallback"
        )) {
            _ = try HybridExecutionEngine.mergedLedger(schemataResults: [schemata], fallbackResults: [fallback])
        }
    }

    @Test("Two schemata results for the same MutationID fail the merge")
    func duplicateWithinSchemataFails() throws {
        let m1 = try makeAnchoredPoint()
        let first = makeResult(point: m1, outcome: .survived)
        let second = makeResult(point: m1, outcome: .killedByAssertion)

        #expect(throws: HybridExecutionEngine.EngineError.duplicateMutationResult(
            mutationID: m1.id.rawValue, portions: "schemata + schemata"
        )) {
            _ = try HybridExecutionEngine.mergedLedger(schemataResults: [first, second], fallbackResults: [])
        }
    }

    @Test("Two fallback results for the same MutationID fail the merge")
    func duplicateWithinFallbackFails() throws {
        let m1 = try makeAnchoredPoint()
        let first = makeResult(point: m1, outcome: .survived)
        let second = makeResult(point: m1, outcome: .survived)

        #expect(throws: HybridExecutionEngine.EngineError.duplicateMutationResult(
            mutationID: m1.id.rawValue, portions: "isolated fallback + isolated fallback"
        )) {
            _ = try HybridExecutionEngine.mergedLedger(schemataResults: [], fallbackResults: [first, second])
        }
    }

    @Test("Distinct MutationIDs from both portions all merge")
    func distinctResultsMerge() throws {
        let m1 = try makeAnchoredPoint()
        let m2 = m1.with(id: MutationID(rawValue: m1.id.rawValue + "-other"))
        let ledger = try HybridExecutionEngine.mergedLedger(
            schemataResults: [makeResult(point: m1, outcome: .killedByAssertion)],
            fallbackResults: [makeResult(point: m2, outcome: .survived)]
        )

        #expect(ledger.mutationIDs == [m1.id, m2.id])
    }

    @Test("The run-level error names the duplicated MutationID")
    func errorNamesTheMutationID() {
        let error = HybridExecutionEngine.EngineError.duplicateMutationResult(
            mutationID: "mut_abc", portions: "schemata + isolated fallback"
        )

        #expect(error.description.contains("mut_abc"))
        #expect(error.description.contains("exactly-once"))
    }
}
