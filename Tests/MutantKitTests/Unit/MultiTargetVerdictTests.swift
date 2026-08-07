import Foundation
import MutationModel
import Testing

/// `MultiTargetVerdict` claims every `TargetVerdict` in `perTarget` is this
/// same mutation's own verdict from a distinct target. Its initializer must
/// prove that, not merely assert it — see the type's own doc comment.
@Suite("MultiTargetVerdict validation")
struct MultiTargetVerdictTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"

    private func ref(for point: MutationPoint) -> PlannedMutationRef {
        PlannedMutationRef.forPoint(point, planID: Self.planID, workUnitID: Self.workUnitID)
    }

    private func record(for point: MutationPoint) throws -> VerifiedMutationRecord {
        let observations = MutationObservations(
            plannedMutation: ref(for: point),
            sourceApplication: .applied(makeEvidence()),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(
                run: TestRunResult(
                    status: .passed, summary: nil,
                    command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
                    resultArtifactPath: nil, diagnosis: "diag"
                ),
                applicationEvidence: .isolated(.buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0"))
            )
        )
        return MutationVerdictVerifier.verify(observations, policy: .permissive)
    }

    private func identity(_ target: String) -> TargetExecutionIdentity {
        TargetExecutionIdentity(projectIdentity: "proj", target: target, module: "Mod", product: "App")
    }

    @Test("At least one target's verdict is required")
    func emptyIsRejected() throws {
        let ref = ref(for: try makeAnchoredPoint())
        #expect(throws: MultiTargetVerdict.ValidationError.self) {
            _ = try MultiTargetVerdict(mutationRef: ref, perTarget: [])
        }
    }

    @Test("A TargetVerdict whose record.mutationRef disagrees with the outer mutationRef is rejected")
    func mismatchedRefIsRejected() throws {
        let point = try makeAnchoredPoint()
        let outerRef = ref(for: point)
        let otherPoint = try makeAnchoredPoint(file: "Sources/Other.swift")
        let mismatchedRecord = try record(for: otherPoint)

        #expect(throws: MultiTargetVerdict.ValidationError.self) {
            _ = try MultiTargetVerdict(
                mutationRef: outerRef,
                perTarget: [TargetVerdict(targetIdentity: identity("A"), record: mismatchedRecord)]
            )
        }
    }

    @Test("Two TargetVerdicts naming the same target identity are rejected")
    func duplicateTargetIsRejected() throws {
        let point = try makeAnchoredPoint()
        let outerRef = ref(for: point)
        let sharedRecord = try record(for: point)

        #expect(throws: MultiTargetVerdict.ValidationError.self) {
            _ = try MultiTargetVerdict(
                mutationRef: outerRef,
                perTarget: [
                    TargetVerdict(targetIdentity: identity("A"), record: sharedRecord),
                    TargetVerdict(targetIdentity: identity("A"), record: sharedRecord)
                ]
            )
        }
    }

    @Test("Consistent per-target verdicts are accepted and sorted by target identity")
    func validVerdictSortsByIdentity() throws {
        let point = try makeAnchoredPoint()
        let outerRef = ref(for: point)
        let sharedRecord = try record(for: point)

        let verdict = try MultiTargetVerdict(
            mutationRef: outerRef,
            perTarget: [
                TargetVerdict(targetIdentity: identity("Z"), record: sharedRecord),
                TargetVerdict(targetIdentity: identity("A"), record: sharedRecord)
            ]
        )

        #expect(verdict.perTarget.map(\.targetIdentity) == [identity("A"), identity("Z")])
    }
}
