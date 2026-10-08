import Foundation
import MutationExecution
@testable import MutationModel
import Reporting
import Testing

/// Which tests credited an assertion kill (selection, naming, batch or
/// standalone attribution), the verifier-authored confirmation chain and
/// crash/timeout display flags, and how a stored report is re-checked.
@Suite("Kill attribution and confirmation chain")
struct KillAttributionTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"

    private var proven: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }

    private func run(
        _ status: TestRunStatus, failing: [String]? = nil, batchTimeout: Bool = false, diagnosis: String? = nil
    ) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: failing.map {
                TestOutcomeSummary(total: 10, passed: 10 - $0.count, failed: $0.count, failingTests: $0, durationSeconds: 1)
            },
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: diagnosis ?? "diag:\(status.rawValue)", isBatchAttributedTimeout: batchTimeout
        )
    }

    private func verify(
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = .permissive,
        evidence: MutationEvidence? = nil,
        test: (TestRunResult, TestExecutionRecord?),
        confirmations: [ConfirmationObservation] = []
    ) throws -> VerifiedMutationRecord {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: Self.planID, workUnitID: Self.workUnitID)
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(evidence ?? makeEvidence(buildProductHash: "h1", activation: proven)),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(run: test.0, applicationEvidence: .isolated(proven), execution: test.1),
            confirmations: confirmations
        )
        return MutationVerdictVerifier.verify(observations, policy: policy)
    }

    private func timeoutConfirmation(_ status: TestRunStatus) -> ConfirmationObservation {
        ConfirmationObservation(kind: .timeout, run: run(status), activation: proven, confirmingBuildProductHash: "h1")
    }

    private func restricted(_ tests: [String], _ attribution: TestExecutionRecord.Attribution = .standalone) -> TestExecutionRecord {
        TestExecutionRecord(attribution: attribution, selectedTests: tests)
    }

    // MARK: - The rule

    @Test("Failing tests inside the selection are within it, whatever decoration the identifiers carry")
    func withinSelectionIgnoresDecoration() {
        let execution = restricted(["AppTests/AddTests/testAdd()", "AppTests/Suite/other()"])
        for failing in ["AppTests/AddTests/testAdd()", "AddTests/testAdd", "App.AddTests/testAdd()"] {
            let result = AssertionKillAttribution.evaluate(execution: execution, failingTests: [failing])
            #expect(result.disposition == .withinSelection, "\(failing)")
        }
    }

    @Test("A failing test outside the selection is not credited, and the unmatched names are recorded")
    func outsideSelection() {
        let result = AssertionKillAttribution.evaluate(
            execution: restricted(["AppTests/AddTests/testAdd()"]),
            failingTests: ["AppTests/AddTests/testAdd()", "AppTests/Other/testUnrelated()"]
        )
        #expect(result.disposition == .outsideSelection)
        #expect(!result.disposition.admitsKill)
        #expect(result.unmatchedFailingTests == ["AppTests/Other/testUnrelated()"])
        #expect(result.selectedTestCount == 1)
    }

    @Test("Whole-suite runs, unnamed failures and missing executions each get their own disposition")
    func otherDispositions() {
        let whole = TestExecutionRecord(attribution: .batch, selection: .wholeSuite)
        #expect(AssertionKillAttribution.evaluate(execution: whole, failingTests: ["A/b()"]).disposition == .wholeSuiteRan)
        #expect(AssertionKillAttribution.evaluate(execution: whole, failingTests: nil).disposition == .failingTestsUnnamed)
        // An empty list is never "no failing test outside the selection".
        #expect(AssertionKillAttribution.evaluate(execution: restricted(["A/b()"]), failingTests: []).disposition == .failingTestsUnnamed)
        #expect(AssertionKillAttribution.evaluate(execution: nil, failingTests: ["A/b()"]).disposition == .executionNotRecorded)
        #expect(!AssertionKillAttribution.evaluate(execution: nil, failingTests: ["A/b()"]).disposition.admitsKill)
        let emptySelection = TestExecutionRecord(attribution: .standalone, selection: .restricted, selectedTests: [])
        #expect(AssertionKillAttribution.evaluate(execution: emptySelection, failingTests: ["A/b()"]).disposition == .outsideSelection)
    }

    // MARK: - The verdict

    @Test("A kill inside its selection stands and records how it was attributed")
    func killWithinSelectionStands() throws {
        let record = try verify(test: (run(.failed, failing: ["T/C/m()"]), restricted(["T/C/m()"], .batch)))
        #expect(record.outcome == .killedByAssertion)
        let attribution = try #require(record.proof.evidence?.assertionKillAttribution)
        #expect(attribution.disposition == .withinSelection)
        #expect(attribution.attribution == .batch)
    }

    @Test("A failure outside the selection is an infrastructure failure, never a kill")
    func killOutsideSelectionIsRejected() throws {
        let record = try verify(test: (run(.failed, failing: ["T/Other/x()"]), restricted(["T/C/m()"])))
        #expect(record.outcome == .infrastructureFailure)
        #expect(record.proof.evidence?.assertionKillAttribution?.disposition == .outsideSelection)
    }

    @Test("An observation with no recorded execution never credits an assertion kill")
    func missingExecutionIsNotAKill() throws {
        let record = try verify(test: (run(.failed, failing: ["T/C/m()"]), nil))
        #expect(record.outcome == .infrastructureFailure)
        #expect(record.proof.evidence?.assertionKillAttribution?.disposition == .executionNotRecorded)
    }

    @Test("Observations stored before the execution record existed decode with none and are not credited")
    func legacyObservationJSONHasNoExecution() throws {
        let observation = SingleTestObservation(
            run: run(.failed, failing: ["T/C/m()"]), applicationEvidence: .isolated(proven), execution: wholeSuiteExecution
        )
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
        json.removeValue(forKey: "execution")
        let legacy = try JSONDecoder().decode(SingleTestObservation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.execution == nil)

        let record = try verify(test: (legacy.run, legacy.execution))
        #expect(record.outcome != .killedByAssertion)
    }

    @Test("A kill that names no failing test stands, labelled so it stays visible")
    func unnamedKillIsVisible() throws {
        let record = try verify(test: (run(.failed), restricted(["T/C/m()"])))
        #expect(record.outcome == .killedByAssertion)
        #expect(record.proof.evidence?.assertionKillAttribution?.disposition == .failingTestsUnnamed)
        #expect(record.proof.evidence?.assertionKillAttribution?.failingTests == nil)
    }

    @Test("A stored attribution record is discarded: the verifier authors it from the execution")
    func forgedAttributionIsDiscarded() throws {
        let forged = makeEvidence(buildProductHash: "h1", activation: proven).withAssertionKillAttribution(
            AssertionKillAttribution(
                disposition: .withinSelection, attribution: .standalone, selectedTestCount: 1, failingTests: ["T/Other/x()"]
            )
        )
        let record = try verify(evidence: forged, test: (run(.failed, failing: ["T/Other/x()"]), restricted(["T/C/m()"])))
        #expect(record.outcome == .infrastructureFailure)
        #expect(record.proof.evidence?.assertionKillAttribution?.disposition == .outsideSelection)
    }

    @Test("A kill reached through a confirmation is held to the same selection rule")
    func confirmedKillOutsideSelectionIsRejected() throws {
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false
        )
        let outside = ["T/Other/x()"]
        let record = try verify(
            policy: policy, test: (run(.failed, failing: outside), restricted(["T/C/m()"])),
            confirmations: [
                ConfirmationObservation(kind: .kill, run: run(.failed, failing: outside), baselineControl: makePassingBaselineControl())
            ]
        )
        #expect(record.outcome == .infrastructureFailure)
        #expect(record.proof.evidence?.assertionKillConfirmation?.disposition == .confirmed)
    }

    // MARK: - Version rule

    @Test("The verifier version moved past the rules that accepted a kill without a recorded execution")
    func versionIsBumped() {
        #expect(MutationVerdictVerifier.currentVersion >= 13)
    }

    // MARK: - Confirmation chain and display flags

    @Test("A cascade leaves every confirmation round in the chain, not only the last")
    func cascadeChainIsRecorded() throws {
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: true
        )
        let failing = ["T/C/m()"]
        let record = try verify(
            policy: policy, test: (run(.timedOut, batchTimeout: true), restricted(failing, .batch)),
            confirmations: [
                ConfirmationObservation(
                    kind: .timeout, run: run(.failed, failing: failing), activation: proven, confirmingBuildProductHash: "h1"
                ),
                ConfirmationObservation(kind: .kill, run: run(.failed, failing: failing), baselineControl: makePassingBaselineControl())
            ]
        )
        #expect(record.outcome == .killedByAssertion)
        let chain = try #require(record.proof.evidence?.confirmationChain)
        #expect(chain.map(\.kind) == ["timeout", "kill"])
        #expect(chain.map(\.outcomeAfter) == [.killedByAssertion, .killedByAssertion])
        #expect(chain.first?.outcomeBefore == .timedOut)
    }

    private func evidenceWithCrash(crashedAgain: Bool) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a\n+++ b\n@@ -1 +1 @@\n-true\n+false\n", buildProductHash: "h1",
            applicationEvidence: .isolated(proven),
            crashConfirmation: CrashConfirmation(
                confirmingBuildCommand: nil, confirmingTestCommand: nil, crashedAgain: crashedAgain, diagnosis: "d"
            )
        )
    }

    private func evidenceWithTimeout(timedOutAgain: Bool) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a\n+++ b\n@@ -1 +1 @@\n-true\n+false\n", buildProductHash: "h1",
            applicationEvidence: .isolated(proven),
            timeoutConfirmation: TimeoutConfirmation(
                confirmingBuildCommand: nil, confirmingTestCommand: nil, timedOutAgain: timedOutAgain, diagnosis: "d"
            )
        )
    }

    @Test("crashedAgain is the verifier's call: a runner-set true on a non-confirmed result is corrected")
    func crashedAgainIsVerifierAuthored() throws {
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: true, confirmTimedOutMutants: false
        )
        let notConfirmed = try verify(
            policy: policy, evidence: evidenceWithCrash(crashedAgain: true), test: (run(.crashed), nil),
            confirmations: [ConfirmationObservation(kind: .crash, run: run(.passed), originalDiagnosis: "diag:crashed")]
        )
        #expect(notConfirmed.outcome == .flaky)
        #expect(notConfirmed.proof.evidence?.crashConfirmation?.crashedAgain == false)

        let confirmed = try verify(
            policy: policy, evidence: evidenceWithCrash(crashedAgain: false), test: (run(.crashed), nil),
            confirmations: [ConfirmationObservation(kind: .crash, run: run(.crashed), originalDiagnosis: "diag:crashed")]
        )
        #expect(confirmed.outcome == .killedByCrash)
        #expect(confirmed.proof.evidence?.crashConfirmation?.crashedAgain == true)
    }

    @Test("timedOutAgain is the verifier's call: a runner-set true on a non-confirmed result is corrected")
    func timedOutAgainIsVerifierAuthored() throws {
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
        )
        let notConfirmed = try verify(
            policy: policy, evidence: evidenceWithTimeout(timedOutAgain: true), test: (run(.timedOut), nil),
            confirmations: [timeoutConfirmation(.passed)]
        )
        #expect(notConfirmed.outcome == .flaky)
        #expect(notConfirmed.proof.evidence?.timeoutConfirmation?.timedOutAgain == false)

        let confirmed = try verify(
            policy: policy, evidence: evidenceWithTimeout(timedOutAgain: false), test: (run(.timedOut), nil),
            confirmations: [timeoutConfirmation(.timedOut)]
        )
        #expect(confirmed.outcome == .verifiedTimeout)
        #expect(confirmed.proof.evidence?.timeoutConfirmation?.timedOutAgain == true)
    }

    // MARK: - Codable

    @Test("Evidence written before the new records decodes with none; empty chains are not written")
    func evidenceCodableIsAdditive() throws {
        let plain = makeEvidence(buildProductHash: "h1", activation: proven)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(object["assertionKillAttribution"] == nil)
        #expect(object["confirmationChain"] == nil)
        let decoded = try JSONDecoder().decode(MutationEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.assertionKillAttribution == nil)
        #expect(decoded.confirmationChain.isEmpty)

        let attributed = plain.withAssertionKillAttribution(.evaluate(execution: wholeSuiteExecution, failingTests: ["A/b()"]))
        let roundTripped = try JSONDecoder().decode(MutationEvidence.self, from: JSONEncoder().encode(attributed))
        #expect(roundTripped == attributed)
    }
}
