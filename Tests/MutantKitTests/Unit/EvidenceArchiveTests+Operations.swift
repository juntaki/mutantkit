@testable import CLI
import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// Archive write failures and archive discovery.
extension EvidenceArchiveTests {
    // MARK: - Write failures

    private func unwritableWriter(_ fixture: Fixture) throws -> EvidenceArchiveWriter {
        // A regular file where the evidence directory would have to be.
        let blocker = fixture.dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        return EvidenceArchiveWriter(
            evidenceRoot: blocker.appendingPathComponent("evidence"), runID: "run-x", plan: fixture.plan, policy: Self.policy
        )
    }

    @Test("A failed archive write is an operational issue and leaves the verdict untouched")
    func writeFailureDoesNotCorruptTheRun() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let log = OperationalIssueLog()
        func assembler(archive: EvidenceArchiveWriter?) -> MutationEvidenceAssembler {
            MutationEvidenceAssembler(
                plan: fixture.plan, policy: Self.policy, checkpoints: nil, artifactsRoot: nil, resultCache: nil,
                resultCacheDigest: nil, progress: nil, operationalIssues: log, evidenceArchive: archive
            )
        }
        func finalize(_ assembler: MutationEvidenceAssembler) async -> MutationResult {
            let observations = observations(fixture, .killedByAssertion)
            return await assembler.finalize(
                point: fixture.point, sourceApplication: observations.sourceApplication, build: observations.build,
                test: observations.test, durationSeconds: 1
            )
        }

        let without = await finalize(assembler(archive: nil))
        let writer = try unwritableWriter(fixture)
        let failing = await finalize(assembler(archive: writer))

        #expect(failing.outcome == without.outcome)
        #expect(failing.outcome == .killedByAssertion)
        // Counted on the writer and reported once at seal, not per mutant.
        #expect(await log.snapshot().isEmpty)
        #expect(writer.writeFailureSummary.count == 1)
    }

    @Test("A manifest that cannot be written is reported in the run's issues; results and score stand")
    func sealFailureIsReported() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let observations = observations(fixture, .survived)
        let report = makeReport(plan: fixture.plan, results: [try result(fixture, observations: observations)])

        let sealed = RunCommand.sealEvidenceArchive(try unwritableWriter(fixture), in: report)

        #expect(sealed.evidenceArchive == nil)
        #expect(sealed.operationalIssues.map(\.kind).contains(.evidenceArchiveWriteFailed))
        #expect(sealed.operationalIssues.map(\.kind).contains(.evidenceArchiveIncomplete))
        #expect(try sortedJSON(sealed.results) == sortedJSON(report.results))
        #expect(sealed.score == report.score)
    }

    @Test("No archive requested leaves the report exactly as it was")
    func noArchiveNoChange() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let report = makeReport(plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .survived)])
        let sealed = RunCommand.sealEvidenceArchive(nil, in: report)
        #expect(sealed.evidenceArchive == nil)
        #expect(try sealed.encoded() == report.encoded())
    }

    // MARK: - Locating

    @Test("An explicit --evidence directory that does not exist is an operational error")
    func explicitMissingDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let report = makeReport(plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .survived)])
        #expect(throws: (any Error).self) {
            try EvidenceArchiveLocator.resolve(
                for: report, explicit: fixture.dir.appendingPathComponent("nope").path, root: fixture.dir, json: false
            )
        }
    }

    @Test("The archive a report records is auto-discovered under the project root")
    func autoDiscovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // The writer's root is <dir>/evidence; discovery looks under <root>/.mutantkit/evidence/<run-id>.
        let (report, _) = try archivedRun(fixture)
        let root = fixture.dir.appendingPathComponent("project")
        let target = root.appendingPathComponent(EvidenceArchiveCodec.relativeRoot)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.writer.directory, to: target.appendingPathComponent("run-a"))

        let located = try #require(try EvidenceArchiveLocator.resolve(for: report, explicit: nil, root: root, json: false))
        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: located, expectedPolicy: Self.policy
        )
        #expect(reverification.tierBPerformed)
        #expect(tierBStatuses(reverification) == [.pass])
    }
}
