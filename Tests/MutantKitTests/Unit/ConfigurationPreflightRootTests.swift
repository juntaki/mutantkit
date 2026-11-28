import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// The shared preflight validates `project.derivedDataPath` against the root
/// the command was given, not the process's current directory.
@Suite("Configuration preflight project root")
struct ConfigurationPreflightRootTests {
    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-PreflightRoot-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a derivedDataPath symlinked out of --project-root is rejected even though the cwd is unrelated")
    func symlinkEscapeInExplicitRootIsRejected() throws {
        let root = try makeDirectory("root")
        let outside = try makeDirectory("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("ExternalDD"), withDestinationURL: outside
        )
        var configuration = Configuration()
        configuration.project.derivedDataPath = "ExternalDD/build"

        #expect(throws: ExitCode.self) {
            try ConfigurationPreflight.run(configuration, projectRoot: root)
        }
    }

    @Test("an ordinary derivedDataPath under --project-root passes (control for the symlink-escape case)")
    func cleanExplicitRootIsAccepted() throws {
        let root = try makeDirectory("clean")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration()
        configuration.project.derivedDataPath = "ExternalDD/build"

        try ConfigurationPreflight.run(configuration, projectRoot: root)
    }
}
