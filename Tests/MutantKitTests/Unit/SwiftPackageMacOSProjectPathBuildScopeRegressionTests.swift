import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Real, end-to-end regression coverage for #77: `configuration.project.path`
/// was honored by plan-time discovery (`SwiftPMLiveSourceResolution`) but
/// ignored by the actual sandboxed `swift build`/`swift test` invocations in
/// `SwiftPackageMacOSAdapter`, which always ran at the sandbox root — the
/// raw clone of `--project-root`, not `project.path` joined onto it.
///
/// `project.path` exists specifically for a package that is not itself at
/// `--project-root` (a monorepo umbrella one level up from the real
/// package), most plausibly so that package's own local `.package(path:)`
/// siblings — which live outside the package directory itself, but inside
/// the umbrella — get cloned into the sandbox alongside it
/// (`WorkspaceManager.createSandbox` clones `--project-root`'s entire
/// contents verbatim, siblings included). Before this fix, pointing
/// `--project-root` at the umbrella so a sibling dependency would resolve,
/// with `project.path` set to the real package's subdirectory, ran `swift
/// build` at the umbrella root — which has no `Package.swift` of its own —
/// instead of at the package. This suite reproduces that exact monorepo
/// shape (an outer directory containing two sibling packages, one
/// `.package(path:)`-depending on the other) against a real toolchain and
/// asserts the mutation build now runs, and finds the package, in the
/// resolved location.
///
/// Deliberately at the unit level, not gated behind `MUTANTKIT_ACCEPTANCE`:
/// a real, fast, toolchain-only bug with no simulator/xcodebuild involved.
/// `.subprocessExclusive` because this spawns real `swift build`/`swift
/// test` subprocesses — see `SubprocessTestGate`'s own doc comment.
@Suite("SwiftPackageMacOSAdapter: project.path is honored by the real build/test, not just planning", .subprocessExclusive)
struct SwiftPackageMacOSProjectPathBuildScopeRegressionTests {
    private static let relativePath = "Package/Sources/PathScopeFixtureLib/Widget.swift"

    private static let librarySource = """
    import PathScopeFixtureSibling

    public func shouldPass() -> Bool {
        siblingIsTrue()
    }

    """

    private static let testSource = """
    import XCTest
    import PathScopeFixtureLib

    final class PathScopeFixtureLibTests: XCTestCase {
        func testShouldPass() {
            XCTAssertTrue(shouldPass())
        }
    }

    """

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.tests.parallel = true
        configuration.project.path = "Package"
        return configuration
    }

    /// Stages the monorepo shape #77 needs: an outer directory (what
    /// `--project-root` points at) containing the real package under
    /// `project.path` ("Package") alongside a sibling it depends on via
    /// `.package(path: "../Sibling")` — reachable only because
    /// `WorkspaceManager` clones the whole outer directory, not just
    /// "Package" alone.
    private func stagePackage() throws -> URL {
        let outer = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-path-scope-regression-\(UUID().uuidString)")
        let packageDirectory = outer.appendingPathComponent("Package")
        let siblingDirectory = outer.appendingPathComponent("Sibling")
        let librarySourcesDirectory = packageDirectory.appendingPathComponent("Sources/PathScopeFixtureLib")
        let testSourcesDirectory = packageDirectory.appendingPathComponent("Tests/PathScopeFixtureLibTests")
        let siblingSourcesDirectory = siblingDirectory.appendingPathComponent("Sources/PathScopeFixtureSibling")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingSourcesDirectory, withIntermediateDirectories: true)

        let siblingManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "PathScopeFixtureSibling",
            platforms: [.macOS(.v14)],
            targets: [.target(name: "PathScopeFixtureSibling")]
        )
        """
        try Data(siblingManifest.utf8).write(to: siblingDirectory.appendingPathComponent("Package.swift"))
        try Data("public func siblingIsTrue() -> Bool { true }\n".utf8)
            .write(to: siblingSourcesDirectory.appendingPathComponent("Sibling.swift"))

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "PathScopeFixtureLib",
            platforms: [.macOS(.v14)],
            dependencies: [.package(path: "../Sibling")],
            targets: [
                .target(name: "PathScopeFixtureLib", dependencies: ["PathScopeFixtureSibling"]),
                .testTarget(name: "PathScopeFixtureLibTests", dependencies: ["PathScopeFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: packageDirectory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: outer.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8)
            .write(to: testSourcesDirectory.appendingPathComponent("PathScopeFixtureLibTests.swift"))
        return outer
    }

    @Test("A mutant at a project.path-scoped package with a local sibling dependency gets a real outcome, not infrastructureFailure")
    func mutantAtScopedPackageGetsRealOutcome() async throws {
        let outerDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: outerDirectory) }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-path-scope-regression-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let plan = MutationPlan(
            planID: "plan-path-scope-regression", createdAt: Date(), projectRoot: outerDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: Self.configuration().configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [BoolLiteralInversionOperator.descriptor]
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: Self.configuration())
        let workspaces = try WorkspaceManager(projectRoot: outerDirectory, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: Self.configuration(), projectRoot: outerDirectory,
            build: adapter, test: adapter, workspaces: workspaces
        )
        let report = try await runner.run()

        #expect(report.results.count == 1)
        let result = try #require(report.results.first)

        #expect(
            result.outcome == .killedByAssertion,
            "expected a genuine kill, not infrastructureFailure from building at the wrong (unscoped) location: \(result.diagnosis)"
        )
        #expect(
            !result.diagnosis.contains("no product hash"),
            "the original bug's own failure signature must never appear again: \(result.diagnosis)"
        )
    }
}
