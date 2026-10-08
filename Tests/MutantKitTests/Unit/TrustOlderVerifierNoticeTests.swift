@testable import CLI
import Foundation
@testable import MutationModel
import Reporting
import Testing

/// A report whose results an older verifier judged is never trustworthy (the
/// required `result.provenance` check is not verifiable, even with a plan);
/// `trust` says so and what to do, rather than only naming the check.
@Suite("trust: older-verifier notice")
struct TrustOlderVerifierNoticeTests {
    private func report(version: Int?) throws -> (RunReport, MutationPlan) {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        var result = makeResult(point: point, outcome: .survived)
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

    @Test("an older verifier version is named, with the current one and the way out")
    func olderVersionIsNamed() throws {
        let (report, plan) = try report(version: MutationVerdictVerifier.currentVersion - 1)
        let notice = try #require(TrustCommand.olderVerifierNotice(for: report))
        #expect(notice.contains("older verifier (version \(MutationVerdictVerifier.currentVersion - 1)"))
        #expect(notice.contains("re-run to obtain a verifiable report"))
        let trust = TrustReport.build(from: report, verifyingAgainst: plan)
        #expect(!trust.trustworthy)
        #expect(trust.verification?.unverifiedRequiredChecks.contains("result.provenance") == true)
    }

    @Test("a report judged by the current verifier gets no notice")
    func currentVersionHasNoNotice() throws {
        let (report, _) = try report(version: nil)
        #expect(TrustCommand.olderVerifierNotice(for: report) == nil)
    }
}
