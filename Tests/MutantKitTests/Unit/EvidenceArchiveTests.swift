@testable import CLI
import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// The opt-in evidence archive and Tier B: raw observations written per
/// result, hash-checked on read, and re-run through the verifier offline.
@Suite("Evidence archive and Tier B")
struct EvidenceArchiveTests {
    struct Fixture {
        let dir: URL
        let point: MutationPoint
        let plan: MutationPlan
        let writer: EvidenceArchiveWriter

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    static let policy = MutationVerdictVerifier.VerdictVerificationPolicy.permissive

    func makeFixture(runID: String = "run-a") throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let writer = EvidenceArchiveWriter(
            evidenceRoot: dir.appendingPathComponent("evidence"), runID: runID, plan: plan, policy: Self.policy
        )
        return Fixture(dir: dir, point: point, plan: plan, writer: writer)
    }

    func observations(_ fixture: Fixture, _ outcome: MutationOutcome) -> MutationObservations {
        makeObservations(point: fixture.point, outcome: outcome, planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID)
    }

    /// A result projected from the same observations that get archived, as a
    /// real run does.
    func result(_ fixture: Fixture, observations: MutationObservations) throws -> MutationResult {
        try MutationResult.projected(
            from: MutationVerdictVerifier.verify(observations, policy: Self.policy), point: fixture.point,
            planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID, durationSeconds: 1
        )
    }

    /// An archived survived run and a report that references it.
    func archivedRun(_ fixture: Fixture, outcome: MutationOutcome = .survived) throws -> (RunReport, LoadedEvidenceArchive) {
        let observations = observations(fixture, outcome)
        try fixture.writer.record(observations)
        let reference = try fixture.writer.seal()
        let report = makeReport(plan: fixture.plan, results: [try result(fixture, observations: observations)])
            .attachingEvidenceArchive(reference)
        return (report, EvidenceArchiveReader.load(directory: fixture.writer.directory))
    }

    func names(_ reverification: ReportReverification, _ status: ReverificationCheck.Status) -> [String] {
        reverification.checks.filter { $0.status == status }.map(\.name)
    }

    /// Statuses of the archive and Tier B checks only: the fixture's Tier A
    /// evidence is deliberately minimal and is not what these tests are about.
    func tierBStatuses(_ reverification: ReportReverification) -> Set<ReverificationCheck.Status> {
        Set(reverification.checks.filter { $0.name.hasPrefix("archive.") || $0.name.hasPrefix("tierB.") }.map(\.status))
    }

    func sortedJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    func editFile(_ url: URL, _ edit: (String) -> String) throws {
        try Data(edit(try String(contentsOf: url, encoding: .utf8)).utf8).write(to: url)
    }

    // MARK: - Round trip

    @Test("Archived observations round-trip and Tier B re-derives the stored outcome")
    func roundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, archive) = try archivedRun(fixture)

        #expect(archive.problems.isEmpty)
        #expect(archive.entries.count == 1)
        let manifest = try #require(archive.manifest)
        #expect(manifest.runID == "run-a")
        #expect(manifest.policy == Self.policy)
        #expect(manifest.verifierVersion == MutationVerdictVerifier.currentVersion)
        #expect(manifest.executionVersion == ExecutionImplementationVersion.current)
        #expect(report.evidenceArchive == EvidenceArchiveReference(
            runID: "run-a", manifestHash: try #require(archive.manifestHash), entryCount: 1
        ))

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: archive, expectedPolicy: Self.policy
        )
        #expect(tierBStatuses(reverification) == [.pass])
        #expect(reverification.tierBPerformed)
        #expect(reverification.tierB?.reverifiedCount == 1)
        #expect(reverification.tierB?.matchedCount == 1)
        #expect(names(reverification, .pass).contains("tierB.outcome"))
        #expect(names(reverification, .pass).contains("archive.integrity"))
    }

    @Test("The recorded confirmation policy is the one Tier B judges under")
    func recordedPolicyIsUsed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let strict = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: true, confirmCrashKills: true, confirmTimedOutMutants: true
        )
        let writer = EvidenceArchiveWriter(
            evidenceRoot: fixture.dir.appendingPathComponent("strict"), runID: "run-strict", plan: fixture.plan, policy: strict
        )
        // A kill whose confirmation was stripped: under a strict policy the verifier refuses it.
        let observations = observations(fixture, .killedByAssertion)
        try writer.record(observations)
        let reference = try writer.seal()
        let stored = try MutationResult.projected(
            from: MutationVerdictVerifier.verify(observations, policy: strict), point: fixture.point,
            planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID, durationSeconds: 1
        )
        #expect(stored.outcome != .killedByAssertion)
        let report = makeReport(plan: fixture.plan, results: [stored]).attachingEvidenceArchive(reference)
        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: EvidenceArchiveReader.load(directory: writer.directory),
            expectedPolicy: strict
        )
        #expect(tierBStatuses(reverification) == [.pass])
        #expect(reverification.tierB?.policy == strict)
    }

    @Test("Writing the archive never changes the report's verdicts, integrity or score")
    func attachingLeavesVerdictsAlone() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let observations = observations(fixture, .killedByAssertion)
        let plain = makeReport(plan: fixture.plan, results: [try result(fixture, observations: observations)])
        try fixture.writer.record(observations)
        let attached = plain.attachingEvidenceArchive(try fixture.writer.seal())

        #expect(try sortedJSON(attached.results) == sortedJSON(plain.results))
        #expect(attached.score == plain.score)
        #expect(attached.integrity.passed == plain.integrity.passed)
        #expect(attached.planID == plain.planID)
    }

    // MARK: - Tamper detection

    @Test("An edited observation is detected and nothing is re-verified from it")
    func editedObservation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, _) = try archivedRun(fixture)
        let observationFile = fixture.writer.directory.appendingPathComponent("observations")
            .appendingPathComponent(EvidenceArchiveCodec.fileName(forMutationID: fixture.point.id.rawValue))
        try editFile(observationFile) { $0.replacingOccurrences(of: "\"passed\"", with: "\"failed\"") }

        let archive = EvidenceArchiveReader.load(directory: fixture.writer.directory)
        let reverification = ReportReverifier.reverify(report: report, plan: fixture.plan, evidence: archive)

        #expect(names(reverification, .fail).contains("archive.integrity"))
        #expect(!reverification.tierBPerformed)
        #expect(archive.entries.isEmpty)
    }

    @Test("An edited hash in the manifest is detected")
    func editedHash() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, original) = try archivedRun(fixture)
        let manifestFile = fixture.writer.directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName)
        let recorded = try #require(original.manifest?.entries.first?.hash)
        try editFile(manifestFile) { $0.replacingOccurrences(of: recorded, with: ContentHash.of("forged")) }

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: EvidenceArchiveReader.load(directory: fixture.writer.directory)
        )

        let integrity = try #require(reverification.checks.first { $0.name == "archive.integrity" })
        #expect(integrity.status == .fail)
        #expect(integrity.detail.contains("manifest does not match the hash the report records"))
        #expect(!reverification.tierBPerformed)
    }

    @Test("An archive from another run cannot stand in for this report's run")
    func swappedRunID() throws {
        let fixture = try makeFixture(runID: "run-a")
        defer { fixture.cleanup() }
        let (report, _) = try archivedRun(fixture)

        // The same observations archived under a different run.
        let other = EvidenceArchiveWriter(
            evidenceRoot: fixture.dir.appendingPathComponent("evidence"), runID: "run-b", plan: fixture.plan, policy: Self.policy
        )
        try other.record(observations(fixture, .survived))
        _ = try other.seal()

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: EvidenceArchiveReader.load(directory: other.directory)
        )
        let integrity = try #require(reverification.checks.first { $0.name == "archive.integrity" })
        #expect(integrity.status == .fail)
        #expect(integrity.detail.contains("run run-a"))
    }

    @Test("A run id edited inside the manifest is detected")
    func editedRunIDInManifest() throws {
        let fixture = try makeFixture(runID: "run-a")
        defer { fixture.cleanup() }
        let (report, _) = try archivedRun(fixture)
        try editFile(fixture.writer.directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName)) {
            $0.replacingOccurrences(of: "\"runID\" : \"run-a\"", with: "\"runID\" : \"run-z\"")
        }

        let archive = EvidenceArchiveReader.load(directory: fixture.writer.directory)
        let reverification = ReportReverifier.reverify(report: report, plan: fixture.plan, evidence: archive)

        #expect(names(reverification, .fail).contains("archive.integrity"))
        #expect(!reverification.tierBPerformed)
    }

    @Test("A file added to the archive but not listed in its manifest is a problem")
    func unlistedFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, _) = try archivedRun(fixture)
        try Data("{}".utf8).write(to: fixture.writer.directory.appendingPathComponent("observations/extra.json"))

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: EvidenceArchiveReader.load(directory: fixture.writer.directory)
        )
        #expect(names(reverification, .fail).contains("archive.integrity"))
    }

    // MARK: - Tier B mismatch

    @Test("A stored outcome that its own observations do not re-derive is a mismatch")
    func flippedStoredOutcome() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let survived = observations(fixture, .survived)
        try fixture.writer.record(survived)
        let reference = try fixture.writer.seal()
        // The report claims a kill; the archived observations say the tests passed.
        let claimed = makeResult(point: fixture.point, outcome: .killedByAssertion)
        let report = makeReport(plan: fixture.plan, results: [claimed]).attachingEvidenceArchive(reference)

        let reverification = ReportReverifier.reverify(
            report: report, plan: fixture.plan, evidence: EvidenceArchiveReader.load(directory: fixture.writer.directory)
        )

        let check = try #require(reverification.checks.first { $0.name == "tierB.outcome" && $0.status == .fail })
        #expect(check.detail.contains("killedByAssertion"))
        #expect(check.detail.contains("survived"))
        #expect(check.mutationIDs == [fixture.point.id.rawValue])
        #expect(reverification.tierB?.mismatchedCount == 1)
    }

    // MARK: - Absent / old

    @Test("Without an archive nothing changes: Tier B is not performed")
    func absentArchive() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let report = makeReport(plan: fixture.plan, results: [try result(fixture, observations: observations(fixture, .survived))])

        let tierA = ReportReverifier.reverify(report: report, plan: fixture.plan)
        let withNone = ReportReverifier.reverify(report: report, plan: fixture.plan, evidence: nil)

        #expect(!tierA.tierBPerformed)
        #expect(tierA.checks == withNone.checks)
        #expect(!tierA.checks.contains { $0.name.hasPrefix("tierB") || $0.name.hasPrefix("archive") })
        let command = VerifyRunCommand.evaluate(report: report, plan: fixture.plan, root: fixture.dir)
        #expect(!command.tierBPerformed)
        #expect(command.tierB == nil)
    }

    @Test("A report that records an archive which cannot be found is not verifiable, never a pass")
    func referencedButMissing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, _) = try archivedRun(fixture)
        try FileManager.default.removeItem(at: fixture.writer.directory)

        let located = try EvidenceArchiveLocator.resolve(for: report, explicit: nil, root: fixture.dir, json: false)
        #expect(located == nil)
        let reverification = ReportReverifier.reverify(report: report, plan: fixture.plan, evidence: located)
        #expect(names(reverification, .notVerifiable).contains("archive.present"))
        #expect(!reverification.tierBPerformed)
    }

    @Test("Results without archived observations are not verifiable and not counted as verified")
    func unarchivedResultIsNotVerifiable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let second = try makeAnchoredPoint(file: "Sources/Other.swift")
        let plan = makePlan(mutations: [fixture.point, second])
        let archived = observations(fixture, .survived)
        try fixture.writer.record(archived)
        let reference = try fixture.writer.seal()
        let report = makeReport(plan: plan, results: [
            try result(fixture, observations: archived),
            makeResult(point: second, outcome: .survived)
        ]).attachingEvidenceArchive(reference)

        let reverification = ReportReverifier.reverify(
            report: report, plan: plan, evidence: EvidenceArchiveReader.load(directory: fixture.writer.directory)
        )
        #expect(reverification.tierB?.reverifiedCount == 1)
        #expect(reverification.tierB?.notVerifiableCount == 1)
        let check = try #require(reverification.checks.first { $0.name == "tierB.outcome" && $0.status == .notVerifiable })
        #expect(check.mutationIDs == [second.id.rawValue])
    }

    @Test("A report written before archives existed decodes with no archive and re-verifies as before")
    func oldReport() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let report = makeReport(plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .survived)])
        var json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        #expect(json["evidenceArchive"] == nil)
        json.removeValue(forKey: "evidenceArchive")
        let decoded = try RunReport.decode(from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.evidenceArchive == nil)
        #expect(!ReportReverifier.reverify(report: decoded, plan: fixture.plan).tierBPerformed)
    }

    @Test("The archive reference survives an encode/decode round trip of the report")
    func referenceRoundTrips() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (report, _) = try archivedRun(fixture)
        let decoded = try RunReport.decode(from: report.encoded())
        #expect(decoded.evidenceArchive == report.evidenceArchive)
    }
}
