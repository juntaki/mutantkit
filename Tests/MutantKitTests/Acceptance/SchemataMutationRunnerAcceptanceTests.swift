import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The first point Stage 0 (SwiftPM linker injection), Stage 1
/// (`SwiftPackageMacOSAdapter`'s schemata conformance), and Stage 2
/// (`SchemataMutationRunner`'s orchestration loop) are all proven together,
/// against a genuinely MutantKit-unaware `Package.swift` — not a throwaway
/// manifest declaring `MutantKitSchemataRuntime` as a dependency.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SchemataMutationRunner", .enabled(if: Acceptance.isEnabled))
struct SchemataMutationRunnerAcceptanceTests {
    private static let relativePath = "Sources/SchemataRunnerFixtureLib/Widget.swift"

    /// Two bool-literal candidates in one file, one chunk: `killedFlag()` is
    /// asserted on directly (flipping it fails the assertion — a real kill),
    /// `survivedFlag()` is called but never asserted on (flipping it changes
    /// nothing the suite checks — a real survivor). Both are genuinely
    /// exercised, so this also proves the difference between "hit and
    /// changed the verdict" and "hit and didn't" rather than only "hit vs.
    /// never reached."
    private static let librarySource = """
    public func killedFlag() -> Bool {
        true
    }

    public func survivedFlag() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import SchemataRunnerFixtureLib

    final class SchemataRunnerFixtureLibTests: XCTestCase {
        func testKilledFlag() {
            XCTAssertTrue(killedFlag())
        }

        func testSurvivedFlagIsCalled() {
            _ = survivedFlag()
            XCTAssertTrue(true)
        }
    }

    """

    private func stageUnawarePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-schemata-runner-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/SchemataRunnerFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/SchemataRunnerFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "SchemataRunnerFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "SchemataRunnerFixtureLib"),
                .testTarget(name: "SchemataRunnerFixtureLibTests", dependencies: ["SchemataRunnerFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("SchemataRunnerFixtureLibTests.swift"))
        return directory
    }

    private func lowerFixture() throws -> (points: [MutationPoint], program: SchemataProgram) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 2, "expected exactly one candidate per function")

        let chunk = SchemataChunk(
            chunkID: "schemata-runner-fixture-chunk", points: points,
            projectIdentity: "SchemataRunnerFixtureLib.xcodeproj",
            target: "SchemataRunnerFixtureLib", module: "SchemataRunnerFixtureLib", product: "SchemataRunnerFixtureLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        return (points, program)
    }

    @Test("Baseline passes, one build per chunk, and each embedded mutant's verdict matches the real test outcome")
    func fullRunProducesCorrectVerdicts() async throws {
        let projectDirectory = try stageUnawarePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-schemata-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let (points, program) = try lowerFixture()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let originalSources = [Self.relativePath: Data(Self.librarySource.utf8)]

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-schemata-acceptance", workUnitID: "plan-schemata-acceptance",
            programs: [program], points: pointsByID, originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 120),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: .permissive
        )

        let outcome = try await runner.run()

        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass")
        #expect(outcome.results.count == 2)

        let killedPoint = try #require(points.first { $0.enclosingDeclaration.description.contains("killedFlag") })
        let survivedPoint = try #require(points.first { $0.enclosingDeclaration.description.contains("survivedFlag") })

        let killedResult = try #require(outcome.results.first { $0.point.id == killedPoint.id })
        #expect(killedResult.outcome == .killedByAssertion, "flipping killedFlag() must fail its own assertion: \(killedResult.diagnosis)")

        let survivedResult = try #require(outcome.results.first { $0.point.id == survivedPoint.id })
        #expect(survivedResult.outcome == .survived, "flipping survivedFlag() must not be caught by any assertion: \(survivedResult.diagnosis)")

        for result in outcome.results {
            guard case let .schemata(observation) = result.evidence?.applicationEvidence else {
                Issue.record("expected a schemata observation for \(result.point.id.rawValue), got \(String(describing: result.evidence?.applicationEvidence))")
                continue
            }
            // The verifier already credited this result's real outcome
            // above (`.killedByAssertion`/`.survived`), which is only
            // reachable once `MutationVerdictVerifier.verifySchemataChain`
            // itself proved a unique STARTUP -> HIT chain — this
            // additionally confirms the raw transcript really contains a
            // HIT record, not just that the outcome happened to look right.
            let hasHit = observation.transcript.records.contains { record in
                if case .hit = record { true } else { false }
            }
            #expect(hasHit, "both mutated sites are genuinely exercised by the suite: \(result.diagnosis)")
        }

        // Sandbox cleanup: nothing should be left behind in the scratch root.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)
        #expect(leftovers.isEmpty, "every sandbox must be destroyed after use, found: \(leftovers)")
    }
}
