@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("BenchmarkManifest")
struct BenchmarkManifestTests {
    private static let validJSON = """
    {
      "schemaVersion": 1,
      "projects": [
        {
          "id": "example",
          "repositoryURL": "https://example.com/example.git",
          "commitSHA": "2f77f2fccb6e84fecff338c37b199e33e7dfd119",
          "projectKind": "swiftPackage",
          "scheme": null,
          "destination": null,
          "configuration": null,
          "expectedSwiftFileCount": null,
          "tags": ["small"]
        }
      ]
    }
    """

    @Test("A well-formed manifest decodes")
    func decodesValidManifest() throws {
        let manifest = try BenchmarkManifest.decode(from: Data(Self.validJSON.utf8))
        #expect(manifest.projects.count == 1)
        #expect(manifest.projects[0].id == "example")
    }

    @Test("A short commit prefix is rejected — commits must be pinned to a full SHA")
    func rejectsShortCommitSHA() throws {
        let json = Self.validJSON.replacingOccurrences(of: "2f77f2fccb6e84fecff338c37b199e33e7dfd119", with: "2f77f2f")
        #expect(throws: BenchmarkManifestError.self) {
            _ = try BenchmarkManifest.decode(from: Data(json.utf8))
        }
    }

    @Test("A branch name in commitSHA is rejected")
    func rejectsBranchNameAsCommitSHA() throws {
        let json = Self.validJSON.replacingOccurrences(of: "2f77f2fccb6e84fecff338c37b199e33e7dfd119", with: "main")
        #expect(throws: BenchmarkManifestError.self) {
            _ = try BenchmarkManifest.decode(from: Data(json.utf8))
        }
    }

    @Test("Two projects sharing an id are rejected")
    func rejectsDuplicateProjectID() throws {
        let manifest = BenchmarkManifest(
            schemaVersion: 1,
            projects: [
                BenchmarkProject(id: "dup", repositoryURL: "https://example.com/a.git", commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage),
                BenchmarkProject(id: "dup", repositoryURL: "https://example.com/b.git", commitSHA: String(repeating: "b", count: 40), projectKind: .swiftPackage)
            ]
        )
        #expect(throws: BenchmarkManifestError.duplicateProjectID("dup")) {
            try BenchmarkManifest.validate(manifest)
        }
    }

    @Test("The real corpus manifest at Benchmarks/manifest.json decodes and validates")
    func realManifestDecodes() throws {
        // Walks up from this test file's own location to find the repo
        // root's Benchmarks/manifest.json — resilient to swift test's own
        // working directory, which varies by invocation.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Benchmarks/manifest.json").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else {
                Issue.record("could not locate Benchmarks/manifest.json above \(#filePath)")
                return
            }
            directory = parent
        }
        let manifest = try BenchmarkManifest.load(from: directory.appendingPathComponent("Benchmarks/manifest.json"))
        #expect(manifest.projects.count >= 10, "the initial corpus must have at least 10 projects")
        #expect(Set(manifest.projects.map(\.id)).count == manifest.projects.count, "no duplicate ids")
        #expect(
            manifest.toolchainRequirements.contains { $0.toolName == "muter" },
            "Muter's own swift-tools-version requirement must be recorded, not only stated in a report"
        )
    }

    @Test("A manifest with no toolchainRequirements key decodes with an empty array, not an error")
    func toolchainRequirementsDefaultsToEmpty() throws {
        let manifest = try BenchmarkManifest.decode(from: Data(Self.validJSON.utf8))
        #expect(manifest.toolchainRequirements.isEmpty)
    }

    @Test("A recorded toolchain requirement round-trips through Codable")
    func toolchainRequirementRoundTrips() throws {
        let manifest = BenchmarkManifest(
            schemaVersion: 1,
            projects: [
                BenchmarkProject(
                    id: "p", repositoryURL: "https://example.com/a.git",
                    commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
                )
            ],
            toolchainRequirements: [
                BenchmarkToolchainRequirement(
                    toolName: "muter", swiftToolsVersion: "5.9", minimumPlatform: "macOS 12", source: "Package.swift"
                )
            ]
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BenchmarkManifest.self, from: data)
        #expect(decoded.toolchainRequirements == manifest.toolchainRequirements)
    }
}
