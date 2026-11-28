@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

@Suite("ProjectContainerLocator: one deterministic answer per directory")
struct ProjectContainerLocatorTests {
    private func makeDirectory(_ entries: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(entry), withIntermediateDirectories: true
            )
        }
        return directory
    }

    @Test("A single candidate is returned; absence is nil")
    func singleAndAbsent() throws {
        let directory = try makeDirectory(["App.xcodeproj"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ProjectContainerLocator.project(in: directory)?.lastPathComponent == "App.xcodeproj")
        #expect(try ProjectContainerLocator.workspace(in: directory) == nil)
    }

    @Test("Two workspaces or two projects are ambiguous, in sorted order, never first-wins")
    func ambiguous() throws {
        let directory = try makeDirectory(["B.xcworkspace", "A.xcworkspace", "X.xcodeproj", "Y.xcodeproj"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ProjectContainerLocator.Failure.ambiguous(
            pathExtension: "xcworkspace", directory: directory.path, candidates: ["A.xcworkspace", "B.xcworkspace"]
        )) { try ProjectContainerLocator.workspace(in: directory) }
        #expect(throws: ProjectContainerLocator.Failure.self) { try ProjectContainerLocator.project(in: directory) }
    }

    @Test("An unreadable directory is an error, not an empty one")
    func unreadable() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        #expect(throws: ProjectContainerLocator.Failure.self) { try ProjectContainerLocator.workspace(in: missing) }
    }

    @Test("Detection and explicit-kind classification report the same ambiguity")
    func detectionAndClassificationAgree() async throws {
        let directory = try makeDirectory(["A.xcodeproj", "B.xcodeproj"])
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: ProjectContainerLocator.Failure.self) {
            try await ProjectDetector.detect(in: directory)
        }
        var configuration = Configuration()
        configuration.project.kind = .xcodeProject
        await #expect(throws: ProjectContainerLocator.Failure.self) {
            try await AppleAdapterFactory.detection(configuration: configuration, in: directory)
        }
    }
}

@Suite("ProjectContainerLocator: only real containers are candidates")
struct ProjectContainerLocatorCandidateTests {
    @Test("A plain file or AppleDouble shadow with the extension does not make a directory ambiguous")
    func strayFilesIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("._App.xcodeproj"), withIntermediateDirectories: true
        )
        try Data().write(to: directory.appendingPathComponent("Other.xcodeproj.xcodeproj"))
        #expect(try ProjectContainerLocator.project(in: directory)?.lastPathComponent == "App.xcodeproj")
    }
}
