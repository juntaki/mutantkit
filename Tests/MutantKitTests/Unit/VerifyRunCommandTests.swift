import ArgumentParser
@testable import CLI
import Foundation
@testable import MutationModel
import SwiftFrontend
import Testing

/// `mutantkit verify-run`: re-derives what a report alone can prove, and says
/// plainly what it cannot.
@Suite("VerifyRunCommand")
struct VerifyRunCommandTests {
    private static let sourceText = """
    struct Example {
        func isReady() -> Bool { return true }
    }
    """

    private struct Fixture {
        let dir: URL
        let point: MutationPoint
        let plan: MutationPlan

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verify-run-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("Sources/Example.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.sourceText.utf8).write(to: file)
        let point = try makeAnchoredPoint()
        return Fixture(dir: dir, point: point, plan: makePlan(mutations: [point]))
    }

    private func provenIsolated() -> ActivationEvidence {
        .buildProductDiffersFromBaseline(mutantHash: ContentHash.of("mutant"), baselineHash: ContentHash.of("baseline-binary"))
    }

    private func evidence(
        for point: MutationPoint, confirmation: AssertionKillConfirmation? = nil, activation: ActivationEvidence? = nil
    ) -> MutationEvidence {
        // swiftlint:disable:next force_try
        let applied = try! MutationApplication.apply(point, to: Data(Self.sourceText.utf8)).evidence
        return MutationEvidence(
            sourceBeforeHash: applied.sourceBeforeHash,
            sourceAfterHash: applied.sourceAfterHash,
            sourceDiff: applied.sourceDiff,
            buildProductHash: ContentHash.of("mutant"),
            applicationEvidence: .isolated(activation ?? provenIsolated()),
            assertionKillConfirmation: confirmation
        )
    }

    private func confirmed() -> AssertionKillConfirmation {
        AssertionKillConfirmation(
            disposition: .confirmed, primaryFailingTests: ["T/a"], confirmingFailingTests: ["T/a"],
            confirmingStatus: "failed", control: makePassedControl()
        )
    }

    private func cleanReport(_ fixture: Fixture, confirmation: AssertionKillConfirmation?) -> RunReport {
        let result = makeResult(
            point: fixture.point, outcome: .killedByAssertion,
            evidence: evidence(for: fixture.point, confirmation: confirmation)
        )
        return makeReport(plan: fixture.plan, results: [result])
    }

    private func tamper(_ report: RunReport, _ edit: (inout [String: Any]) -> Void) throws -> RunReport {
        var json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        edit(&json)
        return try RunReport.decode(from: JSONSerialization.data(withJSONObject: json))
    }

    private func status(_ result: VerifyRunResult, _ name: String) -> [ReverificationCheck.Status] {
        result.checks.filter { $0.name == name }.map(\.status)
    }

    // MARK: - Clean

    @Test("A clean report with its plan and source passes every check, with nothing unverifiable")
    func cleanReportPasses() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = VerifyRunCommand.evaluate(
            report: cleanReport(fixture, confirmation: confirmed()), plan: fixture.plan, root: fixture.dir
        )

        #expect(result.passed)
        #expect(result.failCount == 0)
        #expect(result.notVerifiableCount == 0)
        #expect(result.checks.allSatisfy { $0.status == .pass })
        let names = [
            "plan.identity", "plan.mutationIDs", "source.anchors", "integrity.recompute", "score.recompute",
            "evidence.assertionConfirmation"
        ]
        for name in names {
            #expect(status(result, name) == [.pass], "\(name)")
        }
        #expect(!result.tierBPerformed)
    }

    // MARK: - Honest about what a report cannot prove

    @Test("A kill with no recorded confirmation is reported as not verifiable, never as confirmed")
    func nilConfirmationIsNotConfirmed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = VerifyRunCommand.evaluate(
            report: cleanReport(fixture, confirmation: nil), plan: fixture.plan, root: fixture.dir
        )

        #expect(status(result, "evidence.assertionConfirmation") == [.notVerifiable])
        let check = try #require(result.checks.first { $0.name == "evidence.assertionConfirmation" })
        #expect(check.detail.contains("no confirmation recorded"))
        #expect(check.mutationIDs == [fixture.point.id.rawValue])
        // Not a mismatch, so the verdict stays a pass, but it is not counted as one.
        #expect(result.passed)
        #expect(result.notVerifiableCount == 1)
    }

    @Test("A report written before assertionKillConfirmation and operationalIssues existed decodes and verifies")
    func oldReportWithoutNewFields() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let current = cleanReport(fixture, confirmation: nil)

        let old = try tamper(current) { json in
            json.removeValue(forKey: "operationalIssues")
            var results = json["results"] as? [[String: Any]] ?? []
            for index in results.indices {
                var evidence = results[index]["evidence"] as? [String: Any] ?? [:]
                evidence.removeValue(forKey: "assertionKillConfirmation")
                results[index]["evidence"] = evidence
            }
            json["results"] = results
        }
        #expect(old.results.first?.evidence?.assertionKillConfirmation == nil)

        let result = VerifyRunCommand.evaluate(report: old, plan: fixture.plan, root: fixture.dir)

        #expect(result.passed)
        #expect(status(result, "evidence.assertionConfirmation") == [.notVerifiable])
    }

    @Test("Without a plan, plan-dependent checks are not verifiable rather than passed")
    func noPlanIsNotVerifiable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = VerifyRunCommand.evaluate(
            report: cleanReport(fixture, confirmation: confirmed()), plan: nil, root: fixture.dir
        )

        #expect(result.passed)
        #expect(status(result, "plan.identity") == [.notVerifiable])
        #expect(status(result, "plan.mutationIDs") == [.notVerifiable])
        #expect(status(result, "integrity.recompute") == [.notVerifiable])
        #expect(status(result, "source.anchors") == [.pass])
        #expect(!result.planSupplied)
    }

    // MARK: - Tampering

    @Test("A tampered score is a mismatch")
    func tamperedScoreFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tampered = try tamper(cleanReport(fixture, confirmation: confirmed())) { json in
            var score = json["score"] as? [String: Any] ?? [:]
            score["killed"] = 99
            json["score"] = score
        }

        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)

        #expect(!result.passed)
        #expect(status(result, "score.recompute") == [.fail])
    }

    @Test("A flipped outcome that the evidence does not support is a mismatch")
    func flippedOutcomeFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let survivor = makeResult(point: fixture.point, outcome: .survived, evidence: evidence(for: fixture.point))
        let report = makeReport(plan: fixture.plan, results: [survivor])

        let tampered = try tamper(report) { json in
            var results = json["results"] as? [[String: Any]] ?? []
            results[0]["outcome"] = MutationOutcome.verifiedTimeout.rawValue
            json["results"] = results
        }

        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)

        #expect(!result.passed)
        #expect(status(result, "evidence.timeoutConfirmation") == [.fail])
        // The stored score was computed for a survivor; it no longer matches.
        #expect(status(result, "score.recompute") == [.fail])
    }

    @Test("A kill whose evidence shows the build product identical to baseline is a mismatch")
    func killWithoutActivationFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let hollow = evidence(
            for: fixture.point, confirmation: confirmed(), activation: .buildProductIdenticalToBaseline(hash: ContentHash.of("same"))
        )
        let report = makeReport(
            plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .killedByAssertion, evidence: hollow)]
        )

        let result = VerifyRunCommand.evaluate(report: report, plan: fixture.plan, root: fixture.dir)

        #expect(!result.passed)
        #expect(status(result, "evidence.activation") == [.fail])
    }

    @Test("An assertion kill whose confirmation says it was not confirmed is a mismatch")
    func killContradictingItsConfirmationFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let notConfirmed = AssertionKillConfirmation(
            disposition: .failingSetDiffers, primaryFailingTests: ["T/a"], confirmingFailingTests: ["T/b"], confirmingStatus: "failed"
        )

        let result = VerifyRunCommand.evaluate(
            report: cleanReport(fixture, confirmation: notConfirmed), plan: fixture.plan, root: fixture.dir
        )

        #expect(!result.passed)
        #expect(status(result, "evidence.assertionConfirmation") == [.fail])
    }

    @Test("Emptying integrity.violations on a report with a phantom mutant is a mismatch")
    func emptiedIntegrityViolationsFail() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let phantom = makeResult(point: fixture.point, outcome: .notApplied, evidence: nil, testSummary: nil)
        let honest = makeReport(plan: fixture.plan, results: [phantom])
        #expect(!honest.integrity.passed)

        let tampered = try tamper(honest) { json in
            var integrity = json["integrity"] as? [String: Any] ?? [:]
            integrity["violations"] = [Any]()
            json["integrity"] = integrity
        }
        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)

        #expect(!result.passed)
        #expect(status(result, "integrity.recompute") == [.fail])
    }

    @Test("A report for a different plan fails plan identity")
    func planMismatchFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tampered = try tamper(cleanReport(fixture, confirmation: confirmed())) { $0["planID"] = "plan-other" }

        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)

        #expect(status(result, "plan.identity") == [.fail])
        #expect(!result.passed)
    }

    @Test("Source that no longer matches the anchors fails, and a missing file fails closed")
    func anchorsAgainstCurrentSource() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let report = cleanReport(fixture, confirmation: confirmed())

        try Data("// changed\n".utf8).write(to: fixture.dir.appendingPathComponent("Sources/Example.swift"))
        #expect(status(VerifyRunCommand.evaluate(report: report, plan: fixture.plan, root: fixture.dir), "source.anchors") == [.fail])

        try FileManager.default.removeItem(at: fixture.dir.appendingPathComponent("Sources/Example.swift"))
        let missing = VerifyRunCommand.evaluate(report: report, plan: fixture.plan, root: fixture.dir)
        #expect(status(missing, "source.anchors") == [.fail])
        #expect(!missing.passed)
    }

    @Test("A report with no results never passes")
    func emptyReportFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let empty = makeReport(plan: makePlan(mutations: []), results: [])

        let result = VerifyRunCommand.evaluate(report: empty, plan: nil, root: fixture.dir)

        #expect(!result.passed)
        #expect(status(result, "report.results") == [.fail])
    }

    // MARK: - Command surface

    @Test("The command exits 0 on a clean report and with the integrity code on a tampered one")
    func exitCodes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let clean = cleanReport(fixture, confirmation: confirmed())
        let planPath = fixture.dir.appendingPathComponent("plan.json")
        try fixture.plan.encoded().write(to: planPath)
        let reportPath = fixture.dir.appendingPathComponent("report.json")
        try clean.encoded().write(to: reportPath)

        let arguments = ["--plan", planPath.path, "--project-root", fixture.dir.path, "--json"]
        try await VerifyRunCommand.parse([reportPath.path] + arguments).run()

        let tampered = try tamper(clean) { json in
            var score = json["score"] as? [String: Any] ?? [:]
            score["killed"] = 5
            json["score"] = score
        }
        try tampered.encoded().write(to: reportPath)
        await #expect(throws: ExitCode(MutantKitExit.integrityFailure)) {
            try await VerifyRunCommand.parse([reportPath.path] + arguments).run()
        }
    }

    @Test("An unreadable report exits with the operational-error code")
    func unreadableReport() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let path = fixture.dir.appendingPathComponent("report.json")
        try Data("not json".utf8).write(to: path)

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await VerifyRunCommand.parse([path.path, "--project-root", fixture.dir.path]).run()
        }
    }
}
