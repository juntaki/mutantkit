import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Regression for #77: `project.path` was honored by plan-time discovery but
/// ignored by the real `swift build`/`swift test` invocations, which always
/// ran at the sandbox root instead of joining `project.path` onto it. Stages
/// the shape that needs `project.path` in the first place — an outer
/// directory with two sibling packages, one depending on the other via
/// `.package(path:)` — and asserts a mutant build now runs, and finds the
/// package, at the resolved location.
///
/// Not gated behind `MUTANTKIT_ACCEPTANCE`: fast, toolchain-only, no
/// simulator involved. `.subprocessExclusive` because this spawns real
/// `swift build`/`swift test` subprocesses.
@Suite("SwiftPackageMacOSAdapter: project.path is honored by the real build/test, not just planning", .subprocessExclusive)
struct SwiftPackageMacOSProjectPathBuildScopeRegressionTests {
    private static let relativePath = "Package/Sources/PathScopeFixtureLib/Widget.swift"

    private static let librarySource = """
    import PathScopeFixtureSibling

    public func shouldPass() -> Bool {
        siblingIsTrue() && true
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

    /// Outer directory (`--project-root`) containing the real package under
    /// `project.path` ("Package") plus a sibling it depends on via
    /// `.package(path: "../Sibling")`.
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
