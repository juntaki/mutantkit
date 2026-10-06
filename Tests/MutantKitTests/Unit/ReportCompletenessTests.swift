@testable import CLI
import Foundation
@testable import MutationModel
import Reporting
import SwiftFrontend
import Testing

/// A report with any not-verifiable check has no failure (`passed`) but is
/// PARTIAL: `complete` is the one flag that says every check passed.
@Suite("Report re-verification: complete vs partial")
struct ReportCompletenessTests {
    private func report(confirmation: AssertionKillConfirmation?) throws -> (RunReport, MutationPlan) {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let source = "struct Example {\n    func isReady() -> Bool { return true }\n}"
        let applied = try MutationApplication.apply(point, to: Data(source.utf8)).evidence
        let evidence = MutationEvidence(
            sourceBeforeHash: applied.sourceBeforeHash,
            sourceAfterHash: applied.sourceAfterHash,
            sourceDiff: applied.sourceDiff,
            buildProductHash: ContentHash.of("mutant"),
            applicationEvidence: .isolated(
                .buildProductDiffersFromBaseline(mutantHash: ContentHash.of("mutant"), baselineHash: ContentHash.of("baseline-binary"))
            ),
            assertionKillConfirmation: confirmation
        )
        let result = makeResult(point: point, outcome: .killedByAssertion, evidence: evidence)
        return (makeReport(plan: plan, results: [result]), plan)
    }

    private func confirmed() -> AssertionKillConfirmation {
        AssertionKillConfirmation(
            disposition: .confirmed, primaryFailingTests: ["T/a"], confirmingFailingTests: ["T/a"],
            confirmingStatus: "failed", control: makePassedControl()
        )
    }

    @Test("Every check passing is complete")
    func allPassIsComplete() throws {
        let (report, plan) = try report(confirmation: confirmed())
        let reverification = ReportReverifier.reverify(report: report, plan: plan)
        #expect(reverification.passed)
        #expect(reverification.complete)
    }

    @Test("A not-verifiable check keeps passed true but is never complete")
    func notVerifiableIsPartial() throws {
        let (report, plan) = try report(confirmation: nil)
        let reverification = ReportReverifier.reverify(report: report, plan: plan)
        #expect(reverification.passed)
        #expect(reverification.notVerifiableCount == 1)
        #expect(!reverification.complete)
    }

    @Test("A failed check is not complete")
    func failureIsNotComplete() throws {
        let (report, _) = try report(confirmation: confirmed())
        let reverification = ReportReverifier.reverify(report: report, plan: makePlan(mutations: []))
        #expect(!reverification.passed)
        #expect(!reverification.complete)
    }

    @Test("verify-run --json carries complete, and the closing line says PARTIAL")
    func verifyRunResultCarriesComplete() throws {
        let (partialReport, plan) = try report(confirmation: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("complete-\(UUID().uuidString)")
        let file = root.appendingPathComponent("Sources/Example.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "struct Example {\n    func isReady() -> Bool { return true }\n}"
        try Data(source.utf8).write(to: file)
        let partial = VerifyRunCommand.evaluate(report: partialReport, plan: plan, root: root)
        #expect(partial.passed)
        #expect(!partial.complete)
        let json = try #require(
            JSONSerialization.jsonObject(with: MutationPlan.encoder().encode(partial)) as? [String: Any]
        )
        #expect(json["passed"] as? Bool == true)
        #expect(json["complete"] as? Bool == false)
        #expect(VerifyRunCommand.summaryLine(for: partial).hasPrefix("PARTIAL"))
    }

    @Test("trust --json verification carries complete")
    func trustVerificationCarriesComplete() throws {
        let (report, plan) = try report(confirmation: nil)
        let trust = TrustReport.build(from: report, verifyingAgainst: plan)
        let verification = try #require(trust.verification)
        #expect(verification.passed)
        #expect(!verification.complete)
        let json = try #require(JSONSerialization.jsonObject(with: MutationPlan.encoder().encode(trust)) as? [String: Any])
        let object = try #require(json["verification"] as? [String: Any])
        #expect(object["complete"] as? Bool == false)
    }
}
