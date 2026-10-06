import ArgumentParser
@testable import CLI
import Foundation
@testable import MutationModel
import Reporting
import Testing

/// `trust` only calls a report trustworthy when every required check was
/// verifiable and passed. A report that cannot be fully verified (no plan)
/// exits `notFullyVerified`, distinct from the `integrityFailure` of a mismatch.
@Suite("trust: fail-closed verdict and exit codes")
struct TrustFailClosedTests {
    private struct Fixture {
        let dir: URL
        let plan: MutationPlan
        let report: RunReport
        var reportPath: URL { dir.appendingPathComponent("report.json") }
        var planPath: URL { dir.appendingPathComponent("plan.json") }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFixture(writePlan: Bool, tamperedIntegrity: Bool = false) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let result: MutationResult = tamperedIntegrity
            ? makeResult(point: point, outcome: .notApplied, evidence: nil, testSummary: nil)
            : makeResult(point: point, outcome: .killedByAssertion, evidence: anchoredEvidence(point))
        var report = makeReport(plan: plan, results: [result])
        if tamperedIntegrity {
            report = try forgeIntegrity(report)
        }
        let fixture = Fixture(dir: dir, plan: plan, report: report)
        try report.encoded().write(to: fixture.reportPath)
        if writePlan { try plan.encoded().write(to: fixture.planPath) }
        return fixture
    }

    private func anchoredEvidence(_ point: MutationPoint) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: point.sourceFileHash,
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1 +1 @@\n-true\n+false\n",
            buildProductHash: ContentHash.of("mutant"),
            applicationEvidence: .isolated(
                .buildProductDiffersFromBaseline(mutantHash: ContentHash.of("mutant"), baselineHash: ContentHash.of("baseline-binary"))
            )
        )
    }

    /// Empties `integrity.violations` and claims it passed, as a hand edit would.
    private func forgeIntegrity(_ report: RunReport) throws -> RunReport {
        var json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        var integrity = json["integrity"] as? [String: Any] ?? [:]
        integrity["violations"] = [Any]()
        json["integrity"] = integrity
        return try RunReport.decode(from: JSONSerialization.data(withJSONObject: json))
    }

    private func exitCode(_ arguments: [String]) throws -> Int32 {
        do {
            try TrustCommand.parse(arguments).run()
            return 0
        } catch let code as ExitCode {
            return code.rawValue
        }
    }

    @Test("The exit codes are distinct, and the documented ones keep their values")
    func exitCodesAreDistinct() {
        let codes = [
            MutantKitExit.success, MutantKitExit.operationalError, MutantKitExit.integrityFailure,
            MutantKitExit.survivorsFound, MutantKitExit.qualityGateFailure, MutantKitExit.notFullyVerified
        ]
        #expect(Set(codes).count == codes.count)
        #expect(MutantKitExit.integrityFailure == 2)
        #expect(MutantKitExit.notFullyVerified == 5)
    }

    @Test("A hand-edited integrity self-report with no plan is not trustworthy")
    func tamperedIntegrityWithoutPlan() throws {
        let fixture = try makeFixture(writePlan: false, tamperedIntegrity: true)
        defer { fixture.cleanup() }
        #expect(fixture.report.integrity.passed)

        let trust = TrustReport.build(from: fixture.report, verifyingAgainst: nil)
        #expect(!trust.trustworthy)
        #expect(trust.trustStatus == .notFullyVerified)
        #expect(trust.verification?.unverifiedRequiredChecks.contains("integrity.recompute") == true)

        let code = try exitCode(["--report", fixture.reportPath.path, "--json", "--project-root", fixture.dir.path])
        #expect(code == MutantKitExit.notFullyVerified)
    }

    @Test("The same forged report with its plan is a mismatch")
    func tamperedIntegrityWithPlan() throws {
        let fixture = try makeFixture(writePlan: false, tamperedIntegrity: true)
        defer { fixture.cleanup() }
        try fixture.plan.encoded().write(to: fixture.planPath)

        let trust = TrustReport.build(from: fixture.report, verifyingAgainst: fixture.plan)
        #expect(!trust.trustworthy)
        #expect(trust.trustStatus == .mismatch)

        let explicit = ["--report", fixture.reportPath.path, "--plan", fixture.planPath.path, "--json", "--project-root", fixture.dir.path]
        #expect(try exitCode(explicit) == MutantKitExit.integrityFailure)
        // Discovered next to the report, it fails the same way.
        let discovered = ["--report", fixture.reportPath.path, "--json", "--project-root", fixture.dir.path]
        #expect(try exitCode(discovered) == MutantKitExit.integrityFailure)
    }

    @Test("A clean report with its plan is trustworthy; without any plan it is not fully verified")
    func cleanReportWithAndWithoutPlan() throws {
        let withPlan = try makeFixture(writePlan: true)
        defer { withPlan.cleanup() }
        let explicit = [
            "--report", withPlan.reportPath.path, "--plan", withPlan.planPath.path, "--json", "--project-root", withPlan.dir.path
        ]
        #expect(try exitCode(explicit) == MutantKitExit.success)

        let without = try makeFixture(writePlan: false)
        defer { without.cleanup() }
        let trust = TrustReport.build(from: without.report, verifyingAgainst: nil)
        #expect(!trust.trustworthy)
        #expect(trust.trustStatus == .notFullyVerified)
        let code = try exitCode(["--report", without.reportPath.path, "--json", "--project-root", without.dir.path])
        #expect(code == MutantKitExit.notFullyVerified)
    }

    @Test("A plan beside the report is auto-discovered by planID; one with another planID is ignored")
    func planDiscovery() throws {
        let fixture = try makeFixture(writePlan: true)
        defer { fixture.cleanup() }
        let found = try #require(PlanLocator.discover(for: fixture.report, reportPath: fixture.reportPath.path, root: fixture.dir))
        #expect(found.plan.planID == fixture.plan.planID)
        #expect(try exitCode(["--report", fixture.reportPath.path, "--project-root", fixture.dir.path]) == MutantKitExit.success)

        var other = try #require(JSONSerialization.jsonObject(with: fixture.plan.encoded()) as? [String: Any])
        other["planID"] = "plan-other"
        try JSONSerialization.data(withJSONObject: other).write(to: fixture.planPath)
        #expect(PlanLocator.discover(for: fixture.report, reportPath: fixture.reportPath.path, root: fixture.dir) == nil)
        let code = try exitCode(["--report", fixture.reportPath.path, "--project-root", fixture.dir.path])
        #expect(code == MutantKitExit.notFullyVerified)
    }

    @Test("A mismatch outranks not-fully-verified: a tampered score with no plan exits with the integrity code")
    func mismatchOutranksNotFullyVerified() throws {
        let fixture = try makeFixture(writePlan: false)
        defer { fixture.cleanup() }
        var json = try #require(JSONSerialization.jsonObject(with: fixture.report.encoded()) as? [String: Any])
        var score = json["score"] as? [String: Any] ?? [:]
        score["killed"] = 99
        json["score"] = score
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.reportPath)

        let code = try exitCode(["--report", fixture.reportPath.path, "--json", "--project-root", fixture.dir.path])
        #expect(code == MutantKitExit.integrityFailure)
    }

    @Test("trust --json carries trustStatus and unverifiedRequiredChecks")
    func jsonCarriesStatus() throws {
        let fixture = try makeFixture(writePlan: false)
        defer { fixture.cleanup() }
        let trust = TrustReport.build(from: fixture.report, verifyingAgainst: nil)
        let json = try #require(JSONSerialization.jsonObject(with: MutationPlan.encoder().encode(trust)) as? [String: Any])
        #expect(json["trustworthy"] as? Bool == false)
        #expect(json["trustStatus"] as? String == "notFullyVerified")
        let verification = try #require(json["verification"] as? [String: Any])
        #expect(verification["planSource"] as? String == "none")
        #expect((verification["unverifiedRequiredChecks"] as? [String])?.contains("integrity.recompute") == true)
    }
}
