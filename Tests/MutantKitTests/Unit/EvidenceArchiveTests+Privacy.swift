import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// The archive holds full observations, so it is owner-only on disk.
extension EvidenceArchiveTests {
    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test("The evidence directories are 0700 and every archive file is 0600")
    func archiveIsOwnerOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let evidenceRoot = fixture.dir.appendingPathComponent("evidence")
        // An earlier run left the root world-readable.
        try FileManager.default.createDirectory(
            at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        _ = try archivedRun(fixture)

        let directory = fixture.writer.directory
        let observations = directory.appendingPathComponent(EvidenceArchiveCodec.observationsDirectoryName)
        for url in [evidenceRoot, directory, observations] {
            #expect(try permissions(url) == 0o700, "\(url.lastPathComponent)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: observations, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for url in files + [directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName)] {
            #expect(try permissions(url) == 0o600, "\(url.lastPathComponent)")
        }
    }
}
