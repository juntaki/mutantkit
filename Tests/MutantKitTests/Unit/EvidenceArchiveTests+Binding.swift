@testable import CLI
import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// What Tier B may claim: an archive the report does not reference is not
/// re-judged, and the policy it re-judges under is compared with an
/// independently derived one or reported as taken from the archive itself.
extension EvidenceArchiveTests {
    private func archivedRunWithoutReference(_ fixture: Fixture) throws -> (RunReport, LoadedEvidenceArchive) {
        let archived = observations(fixture, .survived)
        try fixture.writer.record(archived)
        _ = try fixture.writer.seal()
        // The report never recorded the archive.
        let report = makeReport(plan: fixture.plan, results: [try result(fixture, observations: archived)])
        return (report, EvidenceArchiveReader.load(directory: fixture.writer.directory))
    }

    @Test("An archive the report does not reference is reported as unbound and Tier B is not performed")
    func unboundArchiveIsNotTierB() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, archive) = try archivedRunWithoutReference(fixture)

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: archive, expectedPolicy: Self.policy
        )

        #expect(!reverification.tierBPerformed)
        #expect(reverification.tierB == nil)
        let binding = try #require(reverification.checks.first { $0.name == "archive.binding" })
        #expect(binding.status == .notVerifiable)
        #expect(binding.detail.contains("Unbound archive"))
        #expect(!reverification.checks.contains { $0.name == "tierB.outcome" })
        #expect(!reverification.complete)
    }

    @Test("A policy that disagrees with the independently derived one fails")
    func policyDisagreementFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, archive) = try archivedRun(fixture)
        let stricter = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false
        )

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: archive, expectedPolicy: stricter
        )

        let policy = try #require(reverification.checks.first { $0.name == "archive.policy" })
        #expect(policy.status == .fail)
        #expect(!reverification.passed)
    }

    @Test("Without an independent policy the archive's own is flagged, and no required check depends on Tier B")
    func policyFromArchiveItselfIsNotARequiredCheck() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, archive) = try archivedRun(fixture)

        let withTierB = ReportReverifier.reverify(report: report, plan: fixture.plan, evidence: archive)
        let without = ReportReverifier.reverify(report: report, plan: fixture.plan)

        let policy = try #require(withTierB.checks.first { $0.name == "archive.policy" })
        #expect(policy.status == .notVerifiable)
        #expect(policy.detail.contains("not independently bound"))
        #expect(withTierB.tierBPerformed)
        #expect(withTierB.unverifiedRequiredChecks == without.unverifiedRequiredChecks)
        #expect(!ReportReverifier.requiredCheckNames.contains { $0.hasPrefix("archive.") || $0.hasPrefix("tierB.") })
    }

    @Test("The policy is derived from the configuration only when the plan's configuration hash binds it")
    func policyBoundToPlanNeedsMatchingHash() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("version: 1\n".utf8).write(to: root.appendingPathComponent("mutantkit.yml"))
        // `fixture.plan` carries the default configuration's hash.
        #expect(EvidenceArchiveLocator.policyBoundToPlan(fixture.plan, configPath: nil, root: root)
            == MutationVerdictVerifier.VerdictVerificationPolicy(Configuration().execution))

        try Data("version: 1\nexecution:\n  retestKilledMutants: true\n".utf8)
            .write(to: root.appendingPathComponent("mutantkit.yml"))
        #expect(EvidenceArchiveLocator.policyBoundToPlan(fixture.plan, configPath: nil, root: root) == nil)
        #expect(EvidenceArchiveLocator.policyBoundToPlan(nil, configPath: nil, root: root) == nil)
    }
}
