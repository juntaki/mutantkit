@testable import CLI
import Foundation
import MutationModel
import MutationPlanner
import Testing

/// A diff-scoped plan for a project that is not its repository's root.
///
/// `GitDiff.changedLines(since:in:)` runs `git diff` with the project root as
/// its working directory, and the planner matches the scope against paths
/// relative to that project root (`Sources/…`). Without `--relative`, git
/// prints paths relative to the *repository* root (`Packages/Library/Sources/…`)
/// whatever the working directory, so for a package in a subdirectory nothing
/// matched: `plan --diff-base` reported changed files and then planned zero
/// mutations, every one skipped as outside the diff. A run that tests nothing
/// and says it tested the change is the failure this pins.
@Suite("Regression: diff scope for a project below its repository root")
struct DiffScopeProjectBelowRepositoryRootRegressionTests {
    private static let projectPath = "Packages/Library"
    private static let libraryFile = "Sources/Library/Library.swift"
    private static let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    /// A repository holding a package in `Packages/Library` and a Swift file
    /// outside it, committed, so each test only writes its change.
    private static func makeRepository() throws -> (repo: URL, project: URL) {
        let repo = try GitFixture.makeRepository(named: "MutantKit-DiffScopeBelowRoot")
        let project = repo.appendingPathComponent(projectPath)
        try writeLibrary(enabled: true, in: project)
        try GitFixture.write("let unchanged = 1\n", at: project.appendingPathComponent("Sources/Library/Moved.swift"))
        try GitFixture.write("let elsewhere = 1\n", at: repo.appendingPathComponent("Tools/Elsewhere.swift"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-q", "-m", "baseline"], in: repo)
        return (repo, project)
    }

    private static func writeLibrary(enabled: Bool, in project: URL) throws {
        try GitFixture.write("struct Library {\n    var enabled = \(enabled)\n}\n", at: project.appendingPathComponent(libraryFile))
    }

    @Test("Changed lines are keyed by paths relative to the project root, not the repository root")
    func changedLinesAreKeyedByProjectRelativePaths() async throws {
        let (repo, project) = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        try Self.writeLibrary(enabled: false, in: project)

        let scope = try await GitDiff.changedLines(since: "HEAD", in: project)
        #expect(scope.changedLines == [Self.libraryFile: [2 ..< 3]])
    }

    /// The project root is the scope's boundary: a change elsewhere in the
    /// repository is not in it, rather than in it under a path that happens to
    /// resolve somewhere inside the project.
    @Test("A change outside the project root is not in the scope")
    func changeOutsideProjectRootIsExcluded() async throws {
        let (repo, project) = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        try GitFixture.write("let elsewhere = 2\n", at: repo.appendingPathComponent("Tools/Elsewhere.swift"))

        let scope = try await GitDiff.changedLines(since: "HEAD", in: project)
        #expect(scope.isEmpty)
    }

    @Test("A file renamed inside the project is keyed by its new project-relative path")
    func renamedFileIsKeyedByItsNewPath() async throws {
        let (repo, project) = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        try GitFixture.run(["mv", "Sources/Library/Moved.swift", "Sources/Library/Renamed.swift"], in: project)
        try GitFixture.write("let unchanged = 1\nlet added = 2\n", at: project.appendingPathComponent("Sources/Library/Renamed.swift"))

        let scope = try await GitDiff.changedLines(since: "HEAD", in: project)
        #expect(scope.changedLines == ["Sources/Library/Renamed.swift": [2 ..< 3]])
    }

    /// The symptom as a user saw it: the scope git produced, handed to the
    /// planner, has to select the changed code rather than skip all of it.
    @Test("A plan scoped to a change inside the project plans that change's mutants")
    func planSelectsTheChangedCode() async throws {
        let (repo, project) = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        try Self.writeLibrary(enabled: false, in: project)

        let plan = try await MutationPlanner().makePlan(
            configuration: Configuration(execution: ExecutionSettings(diffBase: "HEAD")),
            projectRoot: project,
            toolchain: Self.toolchain,
            diffScope: try await GitDiff.changedLines(since: "HEAD", in: project)
        )
        #expect(!plan.mutations.isEmpty)
        #expect(plan.mutations.allSatisfy { $0.file == Self.libraryFile })
    }
}
