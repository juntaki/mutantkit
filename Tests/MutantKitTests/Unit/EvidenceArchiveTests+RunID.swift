import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// A run ID names a single directory; it can never redirect discovery or writing.
extension EvidenceArchiveTests {
    @Test("Only single UUID-like components are valid run IDs")
    func runIDValidation() {
        for valid in ["run-a", UUID().uuidString.lowercased(), UUID().uuidString, "0"] {
            #expect(EvidenceArchiveCodec.isValidRunID(valid), "\(valid)")
        }
        for invalid in ["", "..", ".", "../x", "a/b", "a\\b", "a b", "a.b", "run\u{0}x", String(repeating: "a", count: 65)] {
            #expect(!EvidenceArchiveCodec.isValidRunID(invalid), "\(invalid)")
        }
    }

    @Test("A report whose run ID climbs out of the evidence root discovers nothing")
    func discoveryRefusesTraversal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.dir.appendingPathComponent("project")
        // <root>/.mutantkit/evidence/../escape == <root>/.mutantkit/escape
        let escape = root.appendingPathComponent(".mutantkit/escape")
        try FileManager.default.createDirectory(at: escape, withIntermediateDirectories: true)
        let reference = EvidenceArchiveReference(runID: "../escape", manifestHash: "x", entryCount: 0)
        let report = makeReport(plan: fixture.plan, results: [makeResult(point: fixture.point, outcome: .survived)])
            .attachingEvidenceArchive(reference)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(EvidenceArchiveCodec.relativeRoot), withIntermediateDirectories: true
        )
        #expect(EvidenceArchiveReader.discover(for: report, roots: [root]) == nil)
    }

    @Test("A writer given a traversing run ID writes inside its root under a fresh one")
    func writerRefusesTraversal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let root = fixture.dir.appendingPathComponent("evidence")
        let writer = EvidenceArchiveWriter(evidenceRoot: root, runID: "../escape", plan: fixture.plan, policy: Self.policy)
        #expect(writer.runID != "../escape")
        #expect(EvidenceArchiveCodec.isValidRunID(writer.runID))
        #expect(writer.directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test("A manifest naming a traversing run ID is not loaded")
    func readerRefusesTraversingManifestRunID() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manifest = EvidenceArchiveManifest(
            runID: "../escape", planID: fixture.plan.planID, workUnitID: fixture.plan.workUnitID, policy: Self.policy, entries: []
        )
        let directory = fixture.dir.appendingPathComponent("forged")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EvidenceArchiveCodec.encode(manifest).write(to: directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName))
        let loaded = EvidenceArchiveReader.load(directory: directory)
        #expect(loaded.manifest == nil)
        #expect(!loaded.problems.isEmpty)
    }
}
