import Foundation
@testable import MutationModel
import Testing

/// Pins `MultiTargetVerdict`'s aggregation policy (version 2,
/// the current policy): a kill in any placement wins; otherwise a
/// MutationID with any placement that cannot be scored is never reported
/// as `survived` or `noCoverage`, and is flagged for one whole-MutationID
/// isolated re-run instead.
@Suite("MultiTargetVerdict aggregation policy")
struct MultiTargetAggregationPolicyTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"

    /// Every outcome that must never be aggregated as if it were evidence
    /// about the test suite. `.timedOut` is the unconfirmed timeout; a
    /// confirmed one is `.verifiedTimeout`, which is kill-like.
    private static let nonScorable: [MutationOutcome] = [
        .infrastructureFailure, .skipped, .flaky, .timedOut, .notApplied, .baselineMismatch, .unviable
    ]
    private static let killLike: [MutationOutcome] = [.killedByAssertion, .killedByCrash, .verifiedTimeout]

    private func identity(_ target: String) -> TargetExecutionIdentity {
        TargetExecutionIdentity(projectIdentity: "proj", target: target, module: "Mod", product: "App")
    }

    private func record(_ outcome: MutationOutcome, ref: PlannedMutationRef) -> VerifiedMutationRecord {
        let proof: VerdictProof = switch outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived:
            .executed(ExecutedMutationProof(
                mutationRef: ref, outcome: outcome, evidence: makeEvidence(), testSummary: makeTestSummary(), diagnosis: "d"
            ))
        case .noCoverage:
            .noCoverage(NoCoverageProof(
                mutationRef: ref, sourceApplication: makeEvidence(), coverageSource: "test-coverage", diagnosis: "d"
            ))
        case .unviable:
            .unviable(BuildFailureProof(mutationRef: ref, diagnosis: "d", evidence: nil))
        default:
            .excluded(ExclusionProof(mutationRef: ref, outcome: outcome, diagnosis: "d"))
        }
        return VerifiedMutationRecord(mutationRef: ref, proof: proof, verificationVersion: MutationVerdictVerifier.currentVersion)
    }

    private func verdict(_ outcomes: MutationOutcome...) throws -> MultiTargetVerdict {
        let ref = PlannedMutationRef.forPoint(try makeAnchoredPoint(), planID: Self.planID, workUnitID: Self.workUnitID)
        let targets = outcomes.enumerated().map { index, outcome in
            TargetVerdict(targetIdentity: identity("T\(index)"), record: record(outcome, ref: ref))
        }
        return try MultiTargetVerdict(mutationRef: ref, perTarget: targets)
    }

    @Test("The aggregation policy version is 2")
    func policyVersionIsTwo() throws {
        #expect(MultiTargetVerdict.currentAggregationPolicyVersion == 2)
        #expect(try verdict(.survived, .survived).aggregationPolicyVersion == 2)
    }

    @Test("survived + infrastructureFailure is not survived, and asks for an isolated re-run")
    func survivedWithInfrastructureFailure() throws {
        let verdict = try verdict(.survived, .infrastructureFailure)
        #expect(verdict.aggregateOutcome == .infrastructureFailure)
        #expect(verdict.requiresIsolatedFallback)
    }

    @Test("survived + flaky is not survived, and asks for an isolated re-run")
    func survivedWithFlaky() throws {
        let verdict = try verdict(.survived, .flaky)
        #expect(verdict.aggregateOutcome == .flaky)
        #expect(verdict.requiresIsolatedFallback)
    }

    @Test("An unconfirmed timeout counts as not scorable")
    func unverifiedTimeoutIsNotScorable() throws {
        let verdict = try verdict(.survived, .timedOut)
        #expect(verdict.aggregateOutcome == .timedOut)
        #expect(verdict.requiresIsolatedFallback)
        #expect(!MultiTargetVerdict.isScorable(.timedOut))
    }

    @Test("Every non-scorable outcome beside survived or noCoverage blocks both and asks for a re-run", arguments: nonScorable)
    func everyNonScorableOutcomeBlocksPromotion(_ bad: MutationOutcome) throws {
        #expect(!MultiTargetVerdict.isScorable(bad))
        for good in [MutationOutcome.survived, .noCoverage] {
            let verdict = try verdict(good, bad)
            #expect(verdict.aggregateOutcome == bad, "\(good) + \(bad)")
            #expect(verdict.requiresIsolatedFallback, "\(good) + \(bad)")
        }
    }

    @Test("A kill in any placement wins with no re-run, whatever the other placement is", arguments: killLike)
    func killWinsWithoutFallback(_ kill: MutationOutcome) throws {
        for other in Self.nonScorable + [.survived, .noCoverage] {
            let verdict = try verdict(other, kill)
            #expect(verdict.aggregateOutcome == kill, "\(kill) + \(other)")
            #expect(!verdict.requiresIsolatedFallback, "\(kill) + \(other)")
        }
    }

    @Test("killed + infrastructureFailure is killed, with no re-run")
    func killedWithInfrastructureFailure() throws {
        let verdict = try verdict(.killedByAssertion, .infrastructureFailure)
        #expect(verdict.aggregateOutcome == .killedByAssertion)
        #expect(!verdict.requiresIsolatedFallback)
    }

    @Test("All placements scorable and none killed aggregates normally, with no re-run")
    func allScorableAggregatesNormally() throws {
        #expect(try verdict(.survived, .noCoverage).aggregateOutcome == .survived)
        #expect(try verdict(.noCoverage, .noCoverage).aggregateOutcome == .noCoverage)
        #expect(try !verdict(.survived, .noCoverage).requiresIsolatedFallback)
    }

    @Test("Every placement non-scorable stays non-scorable and asks for a re-run")
    func allNonScorable() throws {
        let verdict = try verdict(.flaky, .infrastructureFailure)
        #expect(!MultiTargetVerdict.isScorable(verdict.aggregateOutcome))
        #expect(verdict.requiresIsolatedFallback)
    }

    @Test("A single placement is not a multi-target aggregation, so it never asks for a re-run")
    func singlePlacementNeverFallsBack() throws {
        let verdict = try verdict(.flaky)
        #expect(verdict.aggregateOutcome == .flaky)
        #expect(!verdict.requiresIsolatedFallback)
    }
}
