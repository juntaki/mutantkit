import Foundation
import MutationModel
import Testing

/// A crash inferred from SwiftPM's fixed diagnostic line carries `CrashProvenance`. The line is an observation
/// only: the verifier must require the independent crash confirmation for it whatever the run's own
/// `confirmCrashKills` says, and a crash without that confirmation is not a kill.
@Suite("Crash provenance requires the independent crash confirmation")
struct CrashProvenanceVerifierTests {
    private func run(status: TestRunStatus, provenance: CrashProvenance? = nil) -> TestRunResult {
        TestRunResult(
            status: status, summary: nil,
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag:\(status.rawValue)", crashProvenance: provenance
        )
    }

    private let provenance = CrashProvenance(
        source: .swiftPMTestHelperSignalDiagnostic, matchedLine: "error: Process 'x' exited with unexpected signal code 5",
        signal: 5, standardErrorTail: "e", standardOutputTail: "o"
    )
    private var proven: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }

    private func verify(
        policy: MutationVerdictVerifier.VerdictVerificationPolicy, provenance: CrashProvenance?, confirmed: Bool
    ) throws -> MutationOutcome {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "p", workUnitID: "u")
        let confirmations = confirmed
            ? [ConfirmationObservation(kind: .crash, run: run(status: .crashed, provenance: provenance), originalDiagnosis: "diag:crashed")]
            : []
        let observations = MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: proven)),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(run: run(status: .crashed, provenance: provenance), applicationEvidence: .isolated(proven)),
            confirmations: confirmations
        )
        return MutationVerdictVerifier.verify(observations, policy: policy).outcome
    }

    @Test("with provenance and the run's confirmCrashKills OFF, no confirmation means no kill")
    func provenanceForcesConfirmation() throws {
        #expect(try verify(policy: .permissive, provenance: provenance, confirmed: false) == .infrastructureFailure)
        let requirement = MutationVerdictVerifier.confirmationRequirement(
            for: MutationObservations(
                plannedMutation: PlannedMutationRef.forPoint(try makeAnchoredPoint(), planID: "p", workUnitID: "u"),
                sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: proven)),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: SingleTestObservation(run: run(status: .crashed, provenance: provenance), applicationEvidence: .isolated(proven))
            ),
            policy: .permissive
        )
        #expect(requirement == .confirmCrash)
    }

    @Test("with provenance and a confirming crash, it is a crash kill")
    func provenanceWithConfirmationIsAKill() throws {
        #expect(try verify(policy: .permissive, provenance: provenance, confirmed: true) == .killedByCrash)
    }

    @Test("a crash without provenance behaves exactly as before under the same permissive policy")
    func withoutProvenanceUnchanged() throws {
        #expect(try verify(policy: .permissive, provenance: nil, confirmed: false) == .killedByCrash)
    }

    @Test("provenance survives a JSON round trip, and older observations without it still decode")
    func codableAndBackwardCompatible() throws {
        let original = run(status: .crashed, provenance: provenance)
        let decoded = try JSONDecoder().decode(TestRunResult.self, from: JSONEncoder().encode(original))
        #expect(decoded.crashProvenance == provenance)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "crashProvenance")
        let old = try JSONDecoder().decode(TestRunResult.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.crashProvenance == nil)
    }
}
