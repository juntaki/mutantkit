@testable import CLI
import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

extension EvidenceArchiveTests {
    private static let retestPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false
    )

    /// A kill confirmed by a retest, carrying the given baseline control.
    private func controlledKill(_ fixture: Fixture, control: BaselineControlObservation?) -> MutationObservations {
        let base = observations(fixture, .killedByAssertion)
        let failing = TestRunResult(
            status: .failed, summary: makeTestSummary(failed: 1),
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "failed"
        )
        return MutationObservations(
            plannedMutation: base.plannedMutation, sourceApplication: base.sourceApplication, build: base.build,
            test: base.test.map {
                SingleTestObservation(run: failing, applicationEvidence: $0.applicationEvidence, execution: $0.execution)
            },
            confirmations: [ConfirmationObservation(kind: .kill, run: failing, baselineControl: control)]
        )
    }

    @Test("The archive records the baseline control and Tier B re-derives the same verdict from it")
    func controlRoundTripsThroughTheArchive() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let writer = EvidenceArchiveWriter(
            evidenceRoot: fixture.dir.appendingPathComponent("controlled"), runID: "run-control", plan: fixture.plan,
            policy: Self.retestPolicy
        )
        let observations = controlledKill(fixture, control: makePassingBaselineControl())
        try writer.record(observations)
        let reference = try writer.seal()
        let stored = try MutationResult.projected(
            from: MutationVerdictVerifier.verify(observations, policy: Self.retestPolicy), point: fixture.point,
            planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID, durationSeconds: 1
        )
        #expect(stored.outcome == .killedByAssertion)
        #expect(stored.evidence?.assertionKillConfirmation?.control?.status == .passedOnBaseline)

        let archive = EvidenceArchiveReader.load(directory: writer.directory)
        let archived = try #require(archive.entries[stored.id.rawValue])
        #expect(archived.observations.confirmations.first?.baselineControl != nil)

        let report = makeReport(plan: fixture.plan, results: [stored]).attachingEvidenceArchive(reference)
        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: archive, expectedPolicy: Self.retestPolicy
        )
        #expect(tierBStatuses(reverification) == [.pass])
    }

    @Test("Tier B fails a kill whose archived control does not support it")
    func archivedFailingControlContradictsAStoredKill() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let writer = EvidenceArchiveWriter(
            evidenceRoot: fixture.dir.appendingPathComponent("contradicted"), runID: "run-contradicted", plan: fixture.plan,
            policy: Self.retestPolicy
        )
        let passing = controlledKill(fixture, control: makePassingBaselineControl())
        let failingRun = try #require(passing.test?.run)
        // The archive holds a control that failed on the unmutated build.
        let archivedObservations = controlledKill(
            fixture, control: BaselineControlObservation(method: .unmutatedBuildProducts, run: failingRun, selectedTests: nil)
        )
        try writer.record(archivedObservations)
        let reference = try writer.seal()
        let stored = try MutationResult.projected(
            from: MutationVerdictVerifier.verify(passing, policy: Self.retestPolicy), point: fixture.point,
            planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID, durationSeconds: 1
        )
        let report = makeReport(plan: fixture.plan, results: [stored]).attachingEvidenceArchive(reference)
        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: EvidenceArchiveReader.load(directory: writer.directory)
        )
        #expect(tierBStatuses(reverification).contains(.fail))
    }
}
