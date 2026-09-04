import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Real, end-to-end (not mocked) regression coverage for the original bug:
/// with `Configuration.execution.retestKilledMutants: true` on the isolated
/// SwiftPM macOS backend, a confirmation retest of a mutant that appeared
/// killed used to run `swift test --skip-build` against a bare
/// products-only clone (`WorkspaceManager.cloneProducts`'s flat shape) — no
/// `Package.swift`, no real target source tree. SwiftPM could not resolve a
/// package graph from that at all, the retest failed before it ever ran a
/// single test, and `MutationVerdictVerifier` correctly (but only because
/// it fails safe) sank the confirmation to `.flaky` instead of crediting an
/// unconfirmable kill. Root-caused in `Research/product-completeness-2026-08
/// /F7-A-E-FREEZE-RELEASE-GATE.md`.
///
/// This suite reproduces that exact scenario against a real toolchain — a
/// real `swift build --build-tests` and a real `swift test --skip-build`
/// confirmation retest — through the actual production stack
/// (`WorkspaceManager`, `SwiftPackageMacOSAdapter`, `MutationRunner`,
/// `MutationConfirmationCoordinator`), and asserts the mutant is now
/// genuinely confirmed rather than falling to `.flaky`.
///
/// Deliberately at the unit level, not gated behind `MUTANTKIT_ACCEPTANCE`
/// (unlike its differential sibling, `SchemataConfirmationDifferentialAcceptanceTests`,
/// which proves the identical fix from the schemata-vs-isolated comparison
/// angle and stays acceptance-gated because *its* own point is the
/// cross-backend diagnosis comparison, not speed): a regression here is a
/// real, fast-toolchain-only bug with no simulator/xcodebuild involved, so
/// there is no reason to require a slow acceptance run to catch it in CI.
/// `.subprocessExclusive` because this spawns real `swift build`/`swift
/// test` subprocesses — see `SubprocessTestGate`'s own doc comment for why
/// that matters on a contended CI runner.
@Suite("SwiftPackageMacOSAdapter: retestKilledMutants confirmation genuinely confirms a real kill", .subprocessExclusive)
struct SwiftPackageMacOSConfirmationRetestRegressionTests {
    private static let relativePath = "Sources/ConfirmRegressionFixtureLib/Widget.swift"

    private static let librarySource = """
    public func shouldPass() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import ConfirmRegressionFixtureLib

    final class ConfirmRegressionFixtureLibTests: XCTestCase {
        func testShouldPass() {
            XCTAssertTrue(shouldPass())
        }
    }

    """

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.tests.parallel = true
        configuration.execution.retestKilledMutants = true
        return configuration
    }

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-confirm-regression-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/ConfirmRegressionFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/ConfirmRegressionFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "ConfirmRegressionFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "ConfirmRegressionFixtureLib"),
                .testTarget(name: "ConfirmRegressionFixtureLibTests", dependencies: ["ConfirmRegressionFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8)
            .write(to: testSourcesDirectory.appendingPathComponent("ConfirmRegressionFixtureLibTests.swift"))
        return directory
    }

    @Test("A real assertion kill is genuinely confirmed, not sunk to .flaky")
    func realAssertionKillIsGenuinelyConfirmed() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-confirm-regression-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let plan = MutationPlan(
            planID: "plan-confirm-regression", createdAt: Date(), projectRoot: projectDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: Self.configuration().configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [BoolLiteralInversionOperator.descriptor]
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: Self.configuration())
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: Self.configuration(), projectRoot: projectDirectory,
            build: adapter, test: adapter, workspaces: workspaces
        )
        let report = try await runner.run()

        #expect(report.results.count == 1)
        let result = try #require(report.results.first)

        #expect(
            result.outcome == .killedByAssertion,
            "expected a genuine confirmed kill, not a fall-through to .flaky: \(result.diagnosis)"
        )
        #expect(
            result.diagnosis.contains("Confirmed by a second run of the identical mutant, failing the same test(s)."),
            "expected the real confirmation diagnosis, proving the retest actually ran and reproduced the kill: \(result.diagnosis)"
        )
        #expect(
            !result.diagnosis.contains("Could not find Package.swift"),
            "the original bug's own failure signature must never appear again: \(result.diagnosis)"
        )
    }
}
