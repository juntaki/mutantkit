import Foundation
import MutationExecution
@testable import MutationModel
import Reporting
import Testing

/// Stored kill evidence outside the verifier: checkpoint resume, the result
/// cache, report re-verification and the `trust` tally.
@Suite("Kill attribution in stored reports")
struct KillAttributionReportTests {
    private var proven: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }

    private func restricted(_ tests: [String], _ attribution: TestExecutionRecord.Attribution = .standalone) -> TestExecutionRecord {
        TestExecutionRecord(attribution: attribution, selectedTests: tests)
    }

    private func evidenceWithCrash(crashedAgain: Bool) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1 +1 @@\n-true\n+false\n", buildProductHash: "h1",
            applicationEvidence: .isolated(proven),
            crashConfirmation: CrashConfirmation(
                confirmingBuildCommand: nil, confirmingTestCommand: nil, crashedAgain: crashedAgain, diagnosis: "d"
            )
        )
    }

    // MARK: - Checkpoint

    @Test("A checkpointed kill with no recorded execution is not resumed as a kill")
    func checkpointedKillWithoutExecutionIsNotAKill() async throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kill-attribution-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let withExecution = makeObservations(point: point, outcome: .killedByAssertion, planID: plan.planID, workUnitID: plan.workUnitID)
        let stripped = MutationObservations(
            plannedMutation: withExecution.plannedMutation, sourceApplication: withExecution.sourceApplication, build: withExecution.build,
            test: withExecution.test.map { SingleTestObservation(run: $0.run, applicationEvidence: $0.applicationEvidence, execution: nil) }
        )
        let store = CheckpointStore(url: url, policy: .permissive)
        try await store.record(stripped, durationSeconds: 1)

        let resumed = try await store.loadAll(plan: plan)
        #expect(resumed.count == 1)
        #expect(resumed.first?.outcome == .infrastructureFailure)
    }

    // MARK: - Result cache

    private struct CacheFixture {
        let cache: MutationResultCache
        let root: URL
        let point: MutationPoint
    }

    private func cacheFixture() throws -> CacheFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kill-attribution-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CacheFixture(cache: MutationResultCache(root: root, policy: .permissive), root: root, point: try makeAnchoredPoint())
    }

    private func cacheFile(_ root: URL, _ key: MutationResultCache.Key) -> URL {
        let name = ContentHash.shortDigest(of: key.mutationID.rawValue + "\u{1F}" + key.contextDigest, length: 32)
        return root.appendingPathComponent(name + ".json")
    }

    @Test("A stored failure with no recorded execution is never served as a kill")
    func storedFailureWithoutExecutionIsNotAKill() async throws {
        let fixture = try cacheFixture()
        let (cache, root, point) = (fixture.cache, fixture.root, fixture.point)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "no-execution")
        let survivor = makeObservations(point: point, outcome: .survived, planID: "p", workUnitID: "p")
        await cache.store(survivor, durationSeconds: 1, for: key)

        let url = cacheFile(root, key)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var observations = try #require(object["observations"] as? [String: Any])
        var test = try #require(observations["test"] as? [String: Any])
        var run = try #require(test["run"] as? [String: Any])
        run["status"] = "failed"
        test["run"] = run
        observations["test"] = test
        object["observations"] = observations
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        // The entry carries the current verifier version, so only the new rule
        // can reject it: a missing execution record is never read as "inside
        // the selection", and the entry reverifies to a non-cacheable outcome.
        #expect(await cache.load(key, point: point, planID: "p", workUnitID: "p") == nil)
    }

    @Test("A cached kill stamped by an older verifier version is a miss even if its observation would still verify")
    func olderVersionKillIsAMiss() async throws {
        struct RawCacheRecord: Codable {
            let key: MutationResultCache.Key
            let observations: MutationObservations
            let verificationVersion: Int
            let executionVersion: Int
        }
        let fixture = try cacheFixture()
        let (cache, root, point) = (fixture.cache, fixture.root, fixture.point)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "older-version-kill")
        let kill = makeObservations(point: point, outcome: .killedByAssertion, planID: "p", workUnitID: "p")
        #expect(MutationVerdictVerifier.verify(kill, policy: .permissive).outcome == .killedByAssertion)

        let record = RawCacheRecord(
            key: key, observations: kill, verificationVersion: MutationVerdictVerifier.currentVersion - 1,
            executionVersion: ExecutionImplementationVersion.current
        )
        try JSONEncoder().encode(record).write(to: cacheFile(root, key))

        #expect(await cache.load(key, point: point, planID: "p", workUnitID: "p") == nil)
    }

    // MARK: - Report re-verification and trust

    private func killReport(
        failing: [String]? = ["ExampleTests/testSomething()"], attribution: AssertionKillAttribution?, version: Int? = nil
    ) throws -> (RunReport, MutationPlan) {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let summary = failing.map { TestOutcomeSummary(total: 3, passed: 2, failed: 1, failingTests: $0, durationSeconds: 1) }
        let evidence = makeEvidence(activation: .buildProductDiffersFromBaseline(
            mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
        )).withAssertionKillAttribution(attribution)
        var result = makeResult(point: point, outcome: .killedByAssertion, evidence: evidence, testSummary: summary, attributeKill: false)
        if let version {
            result = result.settingVerificationVersion(version)
        }
        return (makeReport(plan: plan, results: [result]), plan)
    }

    private func findings(_ report: RunReport, _ plan: MutationPlan, _ name: String) -> [ReverificationCheck.Status] {
        ReportReverifier.reverify(report: report, plan: plan).checks.filter { $0.name == name }.map(\.status)
    }

    @Test("A kill verified under the current rules with its attribution stripped fails re-verification")
    func strippedAttributionFailsAtCurrentVersion() throws {
        let (report, plan) = try killReport(attribution: nil)
        #expect(findings(report, plan, "evidence.killAttribution") == [.fail])
    }

    @Test("A kill from before the record existed is not verifiable, never a pass")
    func olderKillIsNotVerifiable() throws {
        let (report, plan) = try killReport(attribution: nil, version: MutationVerdictVerifier.currentVersion - 1)
        #expect(findings(report, plan, "evidence.killAttribution") == [.notVerifiable])
    }

    @Test("A coherent attribution passes; an out-of-selection or contradictory one fails")
    func attributionIsRecheckedFromTheReport() throws {
        let names = ["ExampleTests/testSomething()"]
        let good = AssertionKillAttribution.evaluate(execution: restricted(names), failingTests: names)
        let (goodReport, plan) = try killReport(attribution: good)
        #expect(findings(goodReport, plan, "evidence.killAttribution") == [.pass])

        let outside = AssertionKillAttribution.evaluate(execution: restricted(["X/y()"]), failingTests: names)
        let (outsideReport, outsidePlan) = try killReport(attribution: outside)
        #expect(findings(outsideReport, outsidePlan, "evidence.killAttribution") == [.fail])

        // Claims "within selection" although the result's own summary names other tests.
        let mismatched = AssertionKillAttribution(
            disposition: .withinSelection, attribution: .standalone, selectedTestCount: 1, failingTests: ["Other/test()"]
        )
        let (mismatchedReport, mismatchedPlan) = try killReport(attribution: mismatched)
        #expect(findings(mismatchedReport, mismatchedPlan, "evidence.killAttribution") == [.fail])
    }

    @Test("A confirmation claiming to have reproduced on a result that is not that kill fails; a broken chain fails")
    func confirmationConsistencyIsRechecked() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let claimed = evidenceWithCrash(crashedAgain: true)
        let flaky = makeResult(point: point, outcome: .survived, evidence: claimed)
        let flakyReport = makeReport(plan: plan, results: [flaky])
        #expect(findings(flakyReport, plan, "evidence.confirmationChain") == [.fail])

        let broken = makeEvidence(activation: proven).withConfirmationChain([
            ConfirmationStep(kind: "timeout", outcomeBefore: .timedOut, outcomeAfter: .killedByAssertion, confirmingStatus: "failed"),
            ConfirmationStep(kind: "kill", outcomeBefore: .survived, outcomeAfter: .killedByAssertion, confirmingStatus: "failed")
        ])
        let brokenResult = makeResult(point: point, outcome: .killedByAssertion, evidence: broken)
        #expect(findings(makeReport(plan: plan, results: [brokenResult]), plan, "evidence.confirmationChain") == [.fail])
    }

    @Test("trust counts how each kill was credited and never files an unrecorded one under a favourable heading")
    func trustCountsKillEvidence() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let names = ["ExampleTests/testSomething()"]
        let within = makeEvidence(activation: proven).withAssertionKillAttribution(
            .evaluate(execution: restricted(names, .batch), failingTests: names)
        )
        let withinReport = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion, evidence: within)])
        let section = try #require(TrustReport.build(from: withinReport).killEvidence)
        #expect(section.assertionKills == 1)
        #expect(section.withinSelection == 1)
        #expect(section.batchAttributed == 1)
        #expect(section.attributionNotRecorded == 0)

        let (strippedReport, _) = try killReport(attribution: nil)
        let stripped = try #require(TrustReport.build(from: strippedReport).killEvidence)
        #expect(stripped.attributionNotRecorded == 1)
        #expect(stripped.withinSelection == 0)

        let survivor = makeReport(plan: plan, results: [makeResult(point: point, outcome: .survived)])
        #expect(TrustReport.build(from: survivor).killEvidence == nil)
    }
}

private extension MutationResult {
    func settingVerificationVersion(_ version: Int) -> MutationResult {
        MutationResult(
            mutationRef: mutationRef, verificationVersion: version, point: point, outcome: outcome, evidence: evidence,
            testSummary: testSummary, diagnosis: diagnosis, durationSeconds: durationSeconds,
            buildDurationSeconds: buildDurationSeconds, testDurationSeconds: testDurationSeconds,
            confirmationDurationSeconds: confirmationDurationSeconds, origin: origin
        )
    }
}

private extension MutationEvidence {
    func withConfirmationChain(_ chain: [ConfirmationStep]) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: sourceBeforeHash, sourceAfterHash: sourceAfterHash, sourceDiff: sourceDiff,
            buildProductHash: buildProductHash, applicationEvidence: applicationEvidence,
            assertionKillAttribution: assertionKillAttribution, confirmationChain: chain
        )
    }
}
