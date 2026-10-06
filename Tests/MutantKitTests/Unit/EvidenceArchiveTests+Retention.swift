@testable import CLI
import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// `evidence.keep` and the aggregated archive-write-failure report.
extension EvidenceArchiveTests {
    private func makeArchive(_ root: URL, name: String, age: TimeInterval) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(EvidenceArchiveCodec.observationsDirectoryName), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: directory.path)
    }

    @Test("keep removes the oldest archives, never the run's own, and nothing that is not an archive")
    func pruneKeepsNewest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.dir.appendingPathComponent("pruned")
        try makeArchive(root, name: "run-old", age: 300)
        try makeArchive(root, name: "run-mid", age: 200)
        try makeArchive(root, name: "run-new", age: 100)
        // The run's own archive has the oldest timestamp but still counts as the newest.
        try makeArchive(root, name: "run-current", age: 900)
        // Not archives: a stray directory, a file with a valid name, an invalid name.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("run-file"))
        try makeArchive(root, name: "not.valid", age: 999)

        let outcome = EvidenceArchivePruner.prune(root: root, keep: 2, current: "run-current")

        #expect(outcome.removed == ["run-mid", "run-old"])
        #expect(outcome.failures.isEmpty)
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["run-current", "run-new", "notes", "run-file", "not.valid"])
    }

    @Test("Without keep, or with a keep larger than the archive count, nothing is removed")
    func pruneWithoutPressure() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.dir.appendingPathComponent("pruned")
        try makeArchive(root, name: "run-a", age: 10)
        try makeArchive(root, name: "run-b", age: 20)
        #expect(EvidenceArchivePruner.prune(root: root, keep: 5, current: "run-a").removed.isEmpty)
        #expect(EvidenceArchivePruner.prune(root: root, keep: 0, current: "run-a").removed.isEmpty)
    }

    @Test("Sealing with keep prunes older archives and still records the run's own")
    func sealAppliesKeep() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.dir.appendingPathComponent("evidence")
        try makeArchive(root, name: "run-old", age: 500)
        let observations = observations(fixture, .survived)
        try fixture.writer.record(observations)
        let report = makeReport(plan: fixture.plan, results: [try result(fixture, observations: observations)])

        let sealed = RunCommand.sealEvidenceArchive(fixture.writer, in: report, keep: 1)

        #expect(sealed.evidenceArchive?.runID == fixture.writer.runID)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("run-old").path))
        #expect(FileManager.default.fileExists(atPath: fixture.writer.directory.path))
    }

    @Test("Many failed archive writes are one operational issue with a count and one stderr warning")
    func writeFailuresAreAggregated() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let blocker = fixture.dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let writer = EvidenceArchiveWriter(
            evidenceRoot: blocker.appendingPathComponent("evidence"), runID: "run-x", plan: fixture.plan, policy: Self.policy
        )
        #expect(writer.noteWriteFailure("first"))
        #expect(!writer.noteWriteFailure("second"))
        #expect(!writer.noteWriteFailure("third"))
        let report = makeReport(plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .survived)])

        let sealed = RunCommand.sealEvidenceArchive(writer, in: report)

        let failed = sealed.operationalIssues.filter { $0.kind == .evidenceArchiveWriteFailed && $0.mutationID == nil }
        let aggregated = failed.filter { $0.diagnosis.contains("3 mutation(s); first: first") }
        #expect(aggregated.count == 1)
    }

    @Test("evidence.keep decodes, defaults to unlimited, and must be at least 1")
    func keepConfiguration() throws {
        let decoded = try JSONDecoder().decode(Configuration.self, from: Data(#"{"evidence":{"archive":true,"keep":3}}"#.utf8))
        #expect(decoded.evidence?.keep == 3)
        #expect(try JSONDecoder().decode(Configuration.self, from: Data(#"{"evidence":{"archive":true}}"#.utf8)).evidence?.keep == nil)
        var invalid = Configuration()
        invalid.evidence = EvidenceSettings(archive: true, keep: 0)
        #expect(ConfigurationValidator.validate(invalid).contains { $0.path == "evidence.keep" })
        invalid.evidence = EvidenceSettings(archive: true, keep: 1)
        #expect(!ConfigurationValidator.validate(invalid).contains { $0.path == "evidence.keep" })
    }
}
