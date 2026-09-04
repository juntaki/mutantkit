import AppleBuildAdapters
@testable import CLI
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Real, end-to-end regression coverage for the adversarial-review finding
/// (NO_GO PRIMARY BLOCKER) on top of the fix
/// `SwiftPackageMacOSConfirmationRetestRegressionTests` already covers:
/// `PrioritizingTestAdapter` — the wrapper `RunCommand.resolveTestAdapter`
/// installs whenever `execution.selectCoveringTests` and `execution
/// .earlyAbortSelectedTests` are both `true` — declared conformance only to
/// `TestSelecting & TestAdapterWrapping & Sendable`, never
/// `PackageManifestConfirmationRetesting` itself. Before the fix this
/// wrapper's fix was found in, `test as? any PackageManifestConfirmationRetesting`
/// inside `MutationConfirmationCoordinator.confirmKill` only ever inspected
/// the *wrapper's own* declared conformances — Swift's dynamic cast on an
/// existential never looks inside a value a wrapper stores — so it failed
/// even when the wrapped `SwiftPackageMacOSAdapter` genuinely conformed,
/// silently reproducing the exact original bug
/// (`Research/product-completeness-2026-08/F7-A-E-FREEZE-RELEASE-GATE.md`)
/// for every mutant in this real, default-off, but real and reachable
/// configuration combination: safely (`.flaky`, never an over-claimed kill)
/// but silently and completely untested.
///
/// This suite proves the fix — `TestAdapterWrapping`/
/// `packageManifestConfirmationRetesting(for:)`, see `Adapters.swift` —
/// closes that gap: with `selectCoveringTests`, `earlyAbortSelectedTests`,
/// and `retestKilledMutants` all `true` together (resolved through the real
/// `RunCommand.resolveTestAdapter`, not a hand-built wrapper), a real
/// assertion kill is still genuinely confirmed through the wrapper, not
/// silently sunk to `.flaky`.
///
/// `.subprocessExclusive` for the same reason as its sibling suite: this
/// spawns real `swift build`/`swift test` subprocesses.
@Suite(
    "SwiftPackageMacOSAdapter: retestKilledMutants confirmation genuinely confirms a real kill through PrioritizingTestAdapter",
    .subprocessExclusive
)
struct PrioritizingWrapperConfirmationRetestRegressionTests {
    private static let relativePath = "Sources/ConfirmRegressionWrapperFixtureLib/Widget.swift"

    private static let librarySource = """
    public func shouldPass() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import ConfirmRegressionWrapperFixtureLib

    final class ConfirmRegressionWrapperFixtureLibTests: XCTestCase {
        func testShouldPass() {
            XCTAssertTrue(shouldPass())
        }
    }

    """

    /// The exact combination the review flagged as reachable and untested:
    /// `selectCoveringTests`/`earlyAbortSelectedTests`/`retestKilledMutants`
    /// all `true`, with no `testBatchSize` — `PrioritizingTestAdapter
    /// .wouldWrap`'s per-invocation-wrapping branch, not wave-based
    /// batching (see that method's own doc comment). `measureCoverage: true`
    /// because `ConfigurationValidation` requires it whenever
    /// `selectCoveringTests` is on.
    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.tests.parallel = true
        configuration.execution.retestKilledMutants = true
        configuration.execution.measureCoverage = true
        configuration.execution.selectCoveringTests = true
        configuration.execution.earlyAbortSelectedTests = true
        return configuration
    }

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-confirm-regression-wrapper-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/ConfirmRegressionWrapperFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/ConfirmRegressionWrapperFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "ConfirmRegressionWrapperFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "ConfirmRegressionWrapperFixtureLib"),
                .testTarget(name: "ConfirmRegressionWrapperFixtureLibTests", dependencies: ["ConfirmRegressionWrapperFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8)
            .write(to: testSourcesDirectory.appendingPathComponent("ConfirmRegressionWrapperFixtureLibTests.swift"))
        return directory
    }

    @Test("A real assertion kill is genuinely confirmed through PrioritizingTestAdapter, not sunk to .flaky")
    func realAssertionKillIsGenuinelyConfirmedThroughWrapper() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-confirm-regression-wrapper-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let configuration = Self.configuration()
        let plan = MutationPlan(
            planID: "plan-confirm-regression-wrapper", createdAt: Date(), projectRoot: projectDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: configuration.configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [BoolLiteralInversionOperator.descriptor]
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)

        // The real production dispatch, not a hand-built wrapper: this is
        // exactly what `RunCommand.runAfterSimulatorPoolProvisioned` calls
        // before constructing `MutationRunner` for a real `mutantkit run`.
        let priorityStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("priority-\(UUID().uuidString).json")
        let (testAdapter, _) = RunCommand.resolveTestAdapter(
            configuration, base: adapter, priorityStoreURL: priorityStoreURL
        )
        #expect(
            testAdapter is PrioritizingTestAdapter,
            "sanity check: this configuration must actually wrap, or this test is not exercising the regression at all"
        )

        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: projectDirectory,
            build: adapter, test: testAdapter, workspaces: workspaces
        )
        let report = try await runner.run()

        #expect(report.results.count == 1)
        let result = try #require(report.results.first)

        #expect(
            result.outcome == .killedByAssertion,
            "expected a genuine confirmed kill through the wrapper, not a fall-through to .flaky: \(result.diagnosis)"
        )
        #expect(
            result.diagnosis.contains("Confirmed by a second run of the identical mutant, failing the same test(s)."),
            "expected the real confirmation diagnosis, proving the retest actually ran and reproduced the kill: \(result.diagnosis)"
        )
        #expect(
            !result.diagnosis.contains("Could not find Package.swift"),
            "the original bug's own failure signature must never appear again, wrapped or not: \(result.diagnosis)"
        )
    }
}
