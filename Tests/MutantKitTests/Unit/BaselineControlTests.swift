import Foundation
import MutationExecution
@testable import MutationModel
import Reporting
import Testing

/// The baseline control behind a confirmed assertion kill: the unmutated build
/// must pass the same tests, and an absent or unusable control never counts as
/// one that passed.
@Suite("Baseline control for assertion kills")
struct BaselineControlTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"
    private static let retestPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false
    )

    private var proven: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }
    private let failing = ["ExampleTests/testSomething()"]

    private func run(_ status: TestRunStatus, failing: [String]? = nil, total: Int = 10) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: failing.map {
                TestOutcomeSummary(total: total, passed: total - $0.count, failed: $0.count, failingTests: $0, durationSeconds: 1)
            } ?? (status == .passed ? makeTestSummary(total: total, passed: total) : nil),
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag:\(status.rawValue)"
        )
    }

    private func control(_ run: TestRunResult, selected: [String]? = nil) -> BaselineControlObservation {
        BaselineControlObservation(method: .unmutatedBuildProducts, run: run, selectedTests: selected)
    }

    private func observations(
        control: BaselineControlObservation?, planID: String = planID, workUnitID: String = workUnitID
    ) throws -> MutationObservations {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        return MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: proven)),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(
                run: run(.failed, failing: failing), applicationEvidence: .isolated(proven), execution: wholeSuiteExecution
            ),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(.failed, failing: failing), baselineControl: control
            )]
        )
    }

    private func verify(_ observations: MutationObservations) -> VerifiedMutationRecord {
        MutationVerdictVerifier.verify(observations, policy: Self.retestPolicy)
    }

    // MARK: - The rule

    @Test("The verifier version moved past the rules that confirmed a kill without a control")
    func versionIsBumped() {
        #expect(MutationVerdictVerifier.currentVersion >= 14)
    }

    @Test("A passing control confirms the kill and is recorded as structured evidence")
    func passingControlConfirms() throws {
        let record = verify(try observations(control: control(run(.passed))))
        #expect(record.outcome == .killedByAssertion)
        let confirmation = try #require(record.proof.evidence?.assertionKillConfirmation)
        #expect(confirmation.disposition == .confirmed)
        #expect(confirmation.isControlled)
        #expect(confirmation.control?.status == .passedOnBaseline)
        #expect(confirmation.control?.method == .unmutatedBuildProducts)
        #expect(confirmation.control?.runStatus == "passed")
    }

    @Test("A control that fails on the unmutated build makes the kill flaky, never a kill")
    func failingControlIsNotAKill() throws {
        let record = verify(try observations(control: control(run(.failed, failing: failing))))
        #expect(record.outcome == .flaky)
        let confirmation = try #require(record.proof.evidence?.assertionKillConfirmation)
        #expect(confirmation.disposition == .baselineControlFailed)
        #expect(confirmation.control?.status == .failedOnBaseline)
        #expect(!confirmation.isControlled)
        #expect(!confirmation.disposition.isConfirmed)
    }

    @Test("Unrelated tests failing on the unmutated build do not discredit a kill whose own tests passed there")
    func unrelatedControlFailureDoesNotDiscreditTheKill() throws {
        let other = control(run(.failed, failing: ["ExampleTests/testElse()"]))
        let record = verify(try observations(control: other))
        #expect(record.outcome == .killedByAssertion)
        #expect(record.proof.evidence?.assertionKillConfirmation?.control?.status == .passedOnBaseline)

        let unnamed = control(run(.failed))
        #expect(verify(try observations(control: unnamed)).outcome == .flaky)
        let crashed = control(run(.crashed))
        #expect(verify(try observations(control: crashed)).outcome == .flaky)
    }

    @Test("A missing control is never read as controlled: the kill is excluded, not credited")
    func missingControlIsNotAKill() throws {
        let record = verify(try observations(control: nil))
        #expect(record.outcome == .infrastructureFailure)
        let confirmation = try #require(record.proof.evidence?.assertionKillConfirmation)
        #expect(confirmation.disposition == .baselineControlNotEstablished)
        #expect(confirmation.control == nil)
        #expect(!confirmation.isControlled)
    }

    @Test("A control with no verdict, no tests run, or no per-test summary is not established")
    func unusableControlIsNotEstablished() throws {
        let unusable: [TestRunResult] = [
            run(.timedOut), run(.infrastructureFailure),
            run(.passed, total: 0),
            TestRunResult(
                status: .passed, summary: nil, command: CommandRecord(executable: "x", arguments: [], workingDirectory: "/"),
                resultArtifactPath: nil, diagnosis: "no summary"
            )
        ]
        for control in unusable.map({ self.control($0) }) {
            let record = verify(try observations(control: control))
            #expect(record.outcome == .infrastructureFailure, "\(control.run.status) / \(String(describing: control.run.summary))")
            #expect(record.proof.evidence?.assertionKillConfirmation?.control?.status == .notEstablished)
        }
    }

    @Test("A control narrowed to tests that do not include the failing one proves nothing about it")
    func controlSelectionMustCoverTheFailingTests() throws {
        let narrowed = control(run(.passed), selected: ["ExampleTests/Other/testElse()"])
        let record = verify(try observations(control: narrowed))
        #expect(record.outcome == .infrastructureFailure)
        #expect(record.proof.evidence?.assertionKillConfirmation?.control?.status == .notEstablished)

        let covering = control(run(.passed), selected: ["ExampleTests/testSomething()"])
        #expect(verify(try observations(control: covering)).outcome == .killedByAssertion)
    }

    // MARK: - Old data

    @Test("Data written before the control existed decodes to unknown, which is never controlled")
    func legacyDataDecodesToUnknown() throws {
        let legacyConfirmation = Data("""
        {"disposition":"confirmed","method":"retestOfBuiltMutant","primaryFailingTests":["A"],\
        "confirmingFailingTests":["A"],"confirmingStatus":"failed"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AssertionKillConfirmation.self, from: legacyConfirmation)
        #expect(decoded.control == nil)
        #expect(!decoded.isControlled)

        // An observation recorded without a control (every entry from before
        // this field) re-verifies to a non-kill under the current rules.
        let current = try observations(control: control(run(.passed)))
        let data = try JSONEncoder().encode(current)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var confirmations = try #require(object["confirmations"] as? [[String: Any]])
        confirmations[0].removeValue(forKey: "baselineControl")
        object["confirmations"] = confirmations
        let stripped = try JSONDecoder().decode(
            MutationObservations.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(stripped.confirmations.first?.baselineControl == nil)
        #expect(verify(stripped).outcome == .infrastructureFailure)
    }

    @Test("A checkpoint entry recorded without a control is re-verified and not resumed as a kill")
    func checkpointWithoutControlIsNotAKill() async throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-control-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CheckpointStore(url: url, policy: Self.retestPolicy)
        try await store.record(try observations(control: nil, planID: plan.planID, workUnitID: plan.workUnitID), durationSeconds: 1)

        let resumed = try await store.loadAll(plan: plan)
        #expect(resumed.count == 1)
        #expect(resumed.first?.outcome != .killedByAssertion)
    }

    @Test("A cached kill stamped by the previous verifier version is a miss, and one without a control never reloads as a kill")
    func cacheDoesNotServeUncontrolledKills() async throws {
        struct RawCacheRecord: Codable {
            let key: MutationResultCache.Key
            let observations: MutationObservations
            let verificationVersion: Int
            let executionVersion: Int
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-control-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: Self.retestPolicy)
        func file(_ key: MutationResultCache.Key) -> URL {
            let name = ContentHash.shortDigest(of: key.mutationID.rawValue + "\u{1F}" + key.contextDigest, length: 32)
            return root.appendingPathComponent(name + ".json")
        }

        let uncontrolled = try observations(control: nil, planID: Self.planID)
        let previous = MutationResultCache.Key(mutationID: point.id, contextDigest: "version-13")
        try JSONEncoder().encode(RawCacheRecord(
            key: previous, observations: uncontrolled, verificationVersion: 13, executionVersion: ExecutionImplementationVersion.current
        )).write(to: file(previous))
        #expect(await cache.load(previous, point: point, planID: Self.planID, workUnitID: Self.workUnitID) == nil)

        let current = MutationResultCache.Key(mutationID: point.id, contextDigest: "version-current")
        try JSONEncoder().encode(RawCacheRecord(
            key: current, observations: uncontrolled, verificationVersion: MutationVerdictVerifier.currentVersion,
            executionVersion: ExecutionImplementationVersion.current
        )).write(to: file(current))
        let loaded = await cache.load(current, point: point, planID: Self.planID, workUnitID: Self.workUnitID)
        #expect(loaded?.outcome != .killedByAssertion)
    }

    // MARK: - Reports: verify-run and trust

    private func killReport(confirmation: AssertionKillConfirmation, version: Int? = nil) throws -> (RunReport, MutationPlan) {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let evidence = MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1 +1 @@\n-true\n+false\n", buildProductHash: "h1",
            applicationEvidence: .isolated(proven), assertionKillConfirmation: confirmation
        )
        var result = makeResult(point: point, outcome: .killedByAssertion, evidence: evidence)
        if let version {
            result = MutationResult(
                mutationRef: result.mutationRef, verificationVersion: version, point: result.point, outcome: result.outcome,
                evidence: result.evidence, testSummary: result.testSummary, diagnosis: result.diagnosis,
                durationSeconds: result.durationSeconds, buildDurationSeconds: result.buildDurationSeconds,
                testDurationSeconds: result.testDurationSeconds, confirmationDurationSeconds: result.confirmationDurationSeconds,
                origin: result.origin
            )
        }
        return (makeReport(plan: plan, results: [result]), plan)
    }

    private func confirmed(control: AssertionKillConfirmation.Control?) -> AssertionKillConfirmation {
        let tests = makeTestSummary(failed: 1).failingTests
        return AssertionKillConfirmation(
            disposition: .confirmed, primaryFailingTests: tests, confirmingFailingTests: tests, confirmingStatus: "failed",
            control: control
        )
    }

    private func statuses(_ report: RunReport, _ plan: MutationPlan) -> [ReverificationCheck.Status] {
        ReportReverifier.reverify(report: report, plan: plan).checks.filter { $0.name == "evidence.assertionConfirmation" }.map(\.status)
    }

    @Test("verify-run: a confirmed kill needs its passing control; a missing one fails, an older one is not verifiable")
    func verifyRunChecksTheControl() throws {
        let (good, goodPlan) = try killReport(confirmation: confirmed(control: makePassedControl()))
        #expect(statuses(good, goodPlan) == [.pass])

        let (stripped, strippedPlan) = try killReport(confirmation: confirmed(control: nil))
        #expect(statuses(stripped, strippedPlan) == [.fail])

        let (older, olderPlan) = try killReport(
            confirmation: confirmed(control: nil), version: MutationVerdictVerifier.currentVersion - 1
        )
        #expect(statuses(older, olderPlan) == [.notVerifiable])

        let failedControl = AssertionKillConfirmation.Control(
            status: .failedOnBaseline, method: .unmutatedBuildProducts, runStatus: "failed", selectedTestCount: nil, failingTests: ["A"]
        )
        let (contradicted, contradictedPlan) = try killReport(confirmation: confirmed(control: failedControl))
        #expect(statuses(contradicted, contradictedPlan) == [.fail])
    }

    @Test("trust: a confirmed record without a passing control is not counted as confirmed")
    func trustCountsOnlyControlledKillsAsConfirmed() throws {
        let (good, _) = try killReport(confirmation: confirmed(control: makePassedControl()))
        #expect(TrustReport.build(from: good).assertionKills?.confirmed == 1)

        let (uncontrolled, _) = try killReport(confirmation: confirmed(control: nil))
        let section = try #require(TrustReport.build(from: uncontrolled).assertionKills)
        #expect(section.confirmed == 0)
        #expect(section.unconfirmed == 1)
    }
}
