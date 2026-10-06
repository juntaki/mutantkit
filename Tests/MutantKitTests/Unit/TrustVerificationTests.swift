import ArgumentParser
@testable import CLI
import Foundation
@testable import MutationModel
import Reporting
import Testing

/// `mutantkit trust` re-verifies the report instead of believing its stored
/// `integrity.passed`: any failed re-verification check makes the report
/// untrustworthy, and claims a report cannot prove are never counted as verified.
@Suite("TrustCommand: re-verification")
struct TrustVerificationTests {
    private func evidence(for point: MutationPoint, confirmation: AssertionKillConfirmation?) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: point.sourceFileHash,
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1 +1 @@\n-true\n+false\n",
            buildProductHash: ContentHash.of("mutant"),
            applicationEvidence: .isolated(
                .buildProductDiffersFromBaseline(mutantHash: ContentHash.of("mutant"), baselineHash: ContentHash.of("baseline-binary"))
            ),
            assertionKillConfirmation: confirmation
        )
    }

    private func confirmed() -> AssertionKillConfirmation {
        AssertionKillConfirmation(
            disposition: .confirmed, primaryFailingTests: ["T/a"], confirmingFailingTests: ["T/a"],
            confirmingStatus: "failed", control: makePassedControl()
        )
    }

    private struct Fixture {
        let plan: MutationPlan
        let report: RunReport
        let point: MutationPoint
    }

    private func cleanFixture() throws -> Fixture {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let result = makeResult(point: point, outcome: .killedByAssertion, evidence: evidence(for: point, confirmation: confirmed()))
        return Fixture(plan: plan, report: makeReport(plan: plan, results: [result]), point: point)
    }

    private func tamper(_ report: RunReport, _ edit: (inout [String: Any]) -> Void) throws -> RunReport {
        var json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        edit(&json)
        return try RunReport.decode(from: JSONSerialization.data(withJSONObject: json))
    }

    private func check(_ trust: TrustReport, _ name: String) -> ReverificationCheck.Status? {
        trust.verification?.checks.first { $0.name == name }?.status
    }

    // MARK: - Clean

    @Test("A clean report with its plan is trustworthy and fully verified")
    func cleanReportWithPlan() throws {
        let fixture = try cleanFixture()
        let trust = TrustReport.build(from: fixture.report, verifyingAgainst: fixture.plan)

        #expect(trust.trustworthy)
        let verification = try #require(trust.verification)
        #expect(verification.passed)
        #expect(verification.failCount == 0)
        #expect(verification.notVerifiableCount == 0)
        #expect(verification.planSupplied)
        #expect(trust.score != nil)
    }

    @Test("Without a plan a clean report is not trustworthy: it is not fully verified, and says which checks were not")
    func cleanReportWithoutPlan() throws {
        let fixture = try cleanFixture()
        let trust = TrustReport.build(from: fixture.report, verifyingAgainst: nil)

        #expect(!trust.trustworthy)
        #expect(trust.trustStatus == .notFullyVerified)
        #expect(trust.verification?.passed == true)
        #expect(trust.verification?.unverifiedRequiredChecks.contains("integrity.recompute") == true)
        let verification = try #require(trust.verification)
        #expect(!verification.planSupplied)
        #expect(verification.notVerifiableCount >= 1)
        #expect(check(trust, "integrity.recompute") == .notVerifiable)
        #expect(check(trust, "plan.identity") == .notVerifiable)
        // Not-verifiable checks are never counted as passed.
        #expect(verification.passCount + verification.failCount + verification.notVerifiableCount == verification.checks.count)
    }

    // MARK: - Tampering

    @Test("A tampered score makes the report untrustworthy and withholds the score")
    func tamperedScore() throws {
        let fixture = try cleanFixture()
        let tampered = try tamper(fixture.report) { json in
            var score = json["score"] as? [String: Any] ?? [:]
            score["killed"] = 99
            json["score"] = score
        }
        #expect(tampered.integrity.passed)

        let trust = TrustReport.build(from: tampered, verifyingAgainst: fixture.plan)

        #expect(!trust.trustworthy)
        #expect(check(trust, "score.recompute") == .fail)
        #expect(trust.score == nil)
        // Plan-less, the score check alone still catches it.
        #expect(!TrustReport.build(from: tampered, verifyingAgainst: nil).trustworthy)
    }

    @Test("Tampered evidence (a kill whose build product equals the baseline) is untrustworthy")
    func tamperedEvidence() throws {
        let fixture = try cleanFixture()
        let hollow = MutationEvidence(
            sourceBeforeHash: fixture.point.sourceFileHash,
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1 +1 @@\n-true\n+false\n",
            buildProductHash: ContentHash.of("same"),
            applicationEvidence: .isolated(.buildProductIdenticalToBaseline(hash: ContentHash.of("same"))),
            assertionKillConfirmation: confirmed()
        )
        let report = makeReport(
            plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .killedByAssertion, evidence: hollow)]
        )

        let trust = TrustReport.build(from: report, verifyingAgainst: fixture.plan)

        #expect(report.integrity.passed)
        #expect(!trust.trustworthy)
        #expect(check(trust, "evidence.activation") == .fail)
    }

    @Test("A stored integrity.passed that the recompute contradicts is not trusted")
    func storedIntegrityContradictedByRecompute() throws {
        let fixture = try cleanFixture()
        let phantom = makeResult(point: fixture.point, outcome: .notApplied, evidence: nil, testSummary: nil)
        let honest = makeReport(plan: fixture.plan, results: [phantom])
        #expect(!honest.integrity.passed)

        let forged = try tamper(honest) { json in
            var integrity = json["integrity"] as? [String: Any] ?? [:]
            integrity["violations"] = [Any]()
            json["integrity"] = integrity
        }
        #expect(forged.integrity.passed)

        // Believing the stored field alone would call this trustworthy.
        #expect(!TrustReport.build(from: forged).trustworthy)
        // Without a plan nothing contradicts it, but it is still not trusted.
        let planless = TrustReport.build(from: forged, verifyingAgainst: nil)
        #expect(!planless.trustworthy)
        #expect(planless.trustStatus == .notFullyVerified)

        let trust = TrustReport.build(from: forged, verifyingAgainst: fixture.plan)
        #expect(trust.integrity.passed)
        #expect(!trust.trustworthy)
        #expect(trust.trustStatus == .mismatch)
        #expect(check(trust, "integrity.recompute") == .fail)
    }

    // MARK: - Older reports

    @Test("A report written before the confirmation field existed decodes; the missing confirmation is not verified")
    func oldReportWithoutConfirmationField() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let result = makeResult(point: point, outcome: .killedByAssertion, evidence: evidence(for: point, confirmation: nil))
        let old = try tamper(makeReport(plan: plan, results: [result])) { json in
            json.removeValue(forKey: "operationalIssues")
        }

        let trust = TrustReport.build(from: old, verifyingAgainst: plan)

        #expect(trust.trustworthy)
        #expect(check(trust, "evidence.assertionConfirmation") == .notVerifiable)
        let verification = try #require(trust.verification)
        #expect(verification.notVerifiableCount == 1)
        #expect(verification.passed)
    }

    @Test("Plain build(from:) carries no verification and is not a trust verdict")
    func plainBuildHasNoVerification() throws {
        let trust = TrustReport.build(from: try cleanFixture().report)
        #expect(trust.verification == nil)
        let json = try #require(
            JSONSerialization.jsonObject(with: MutationPlan.encoder().encode(trust)) as? [String: Any]
        )
        #expect(json["verification"] == nil)
        #expect(json["trustworthy"] as? Bool == false)
        #expect(json["trustStatus"] as? String == "notFullyVerified")
    }

    // MARK: - Command

    @Test("trust exits 0 on a clean report with --plan, and with the integrity code on a tampered score")
    func commandExitCodes() throws {
        let fixture = try cleanFixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let planPath = dir.appendingPathComponent("plan.json")
        let reportPath = dir.appendingPathComponent("report.json")
        try fixture.plan.encoded().write(to: planPath)
        try fixture.report.encoded().write(to: reportPath)

        let arguments = ["--report", reportPath.path, "--plan", planPath.path, "--json", "--project-root", dir.path]
        try TrustCommand.parse(arguments).run()
        // Without --plan it still runs.
        try TrustCommand.parse(["--report", reportPath.path, "--json", "--project-root", dir.path]).run()

        let tampered = try tamper(fixture.report) { json in
            var score = json["score"] as? [String: Any] ?? [:]
            score["killed"] = 5
            json["score"] = score
        }
        try tampered.encoded().write(to: reportPath)
        #expect(throws: ExitCode(MutantKitExit.integrityFailure)) {
            try TrustCommand.parse(arguments).run()
        }
    }
}
