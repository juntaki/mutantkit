@testable import CLI
import Foundation
import XCTest

/// `worktreeContentState(excludingProjectRelativePaths:)` lets a run key its `mutantkit.yml` as the
/// parsed configuration instead of as bytes. Only the named file may drop out of the digest.
final class RunContextProbeExcludedPathsTests: XCTestCase {
    private let config = Set([ConfigurationLoader.fileName])

    func testEditingAnExcludedFileDoesNotChangeTheDigestButEditingSourceDoes() async throws {
        let repo = try GitFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try GitFixture.write("version: 1\nexecution:\n  workers: 1\n", at: repo.appendingPathComponent(ConfigurationLoader.fileName))
        try GitFixture.write("let x = 1\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "baseline"], in: repo)

        let before = try await RunContextProbe.worktreeContentState(in: repo, excludingProjectRelativePaths: config)
        let beforeWhole = try await RunContextProbe.worktreeContentState(in: repo)

        try GitFixture.write("version: 1\nexecution:\n  workers: 4\n", at: repo.appendingPathComponent(ConfigurationLoader.fileName))
        let afterConfig = try await RunContextProbe.worktreeContentState(in: repo, excludingProjectRelativePaths: config)
        XCTAssertEqual(before, afterConfig, "a config edit must not move a digest that excludes the config file")
        let afterConfigWhole = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(beforeWhole, afterConfigWhole, "without the exclusion the edit still counts")

        try GitFixture.write("let x = 2\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        let afterSource = try await RunContextProbe.worktreeContentState(in: repo, excludingProjectRelativePaths: config)
        XCTAssertNotEqual(before, afterSource, "source changes still invalidate")
    }

    func testOnlyTheProjectRootsFileIsExcluded() async throws {
        let repo = try GitFixture.makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let project = repo.appendingPathComponent("App")
        try GitFixture.write("a\n", at: project.appendingPathComponent(ConfigurationLoader.fileName))
        try GitFixture.write("a\n", at: project.appendingPathComponent("Fixtures/\(ConfigurationLoader.fileName)"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "baseline"], in: repo)

        let before = try await RunContextProbe.worktreeContentState(in: project, excludingProjectRelativePaths: config)

        try GitFixture.write("b\n", at: project.appendingPathComponent(ConfigurationLoader.fileName))
        let afterRootConfig = try await RunContextProbe.worktreeContentState(in: project, excludingProjectRelativePaths: config)
        XCTAssertEqual(before, afterRootConfig, "the project's own config is excluded when nested in a repository")

        try GitFixture.write("b\n", at: project.appendingPathComponent("Fixtures/\(ConfigurationLoader.fileName)"))
        let afterNestedSameName = try await RunContextProbe.worktreeContentState(in: project, excludingProjectRelativePaths: config)
        XCTAssertNotEqual(before, afterNestedSameName, "a same-named file deeper in the project is content, not the config")
    }
}
