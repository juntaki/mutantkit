import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0006 Stage 3's actual gate: the two backends must agree. The exact
/// same `MutationPoint`s, discovered once from one fixture, are run to
/// completion under both `MutationRunner` (isolated: one full rebuild per
/// mutant) and `SchemataMutationRunner` (schemata: every mutation embedded
/// into one shared build) — never assumed to agree because their unit
/// suites separately pass.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: isolated vs schemata differential (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct SchemataIsolatedDifferentialAcceptanceTests {
    private static let relativePath = "Sources/DifferentialFixtureLib/Widget.swift"
    /// Matches `Configuration()`'s own default `execution` flags exactly —
    /// the isolated `MutationRunner` below is constructed with a plain
    /// `Configuration()`, so the schemata runner must be handed the
    /// identical policy for this comparison to mean anything: two backends
    /// "agreeing" while running under different confirmation policies
    /// would prove nothing.
    private static let defaultVerificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: Configuration().execution.retestKilledMutants,
        confirmCrashKills: Configuration().execution.confirmCrashKills,
        confirmTimedOutMutants: Configuration().execution.confirmTimedOutMutants
    )

    /// The identical fixture shape `SchemataMutationRunnerAcceptanceTests`
    /// uses — a real kill and a real survivor, both genuinely exercised —
    /// reused deliberately so a divergence between the two backends can
    /// only come from the backends themselves, not from two different
    /// fixtures happening to behave differently.
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
    import DifferentialFixtureLib

    final class DifferentialFixtureLibTests: XCTestCase {
        func testKilledFlag() {
            XCTAssertTrue(killedFlag())
        }

        func testSurvivedFlagIsCalled() {
            _ = survivedFlag()
            XCTAssertTrue(true)
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-differential-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/DifferentialFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/DifferentialFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "DifferentialFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "DifferentialFixtureLib"),
                .testTarget(name: "DifferentialFixtureLibTests", dependencies: ["DifferentialFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("DifferentialFixtureLibTests.swift"))
        return directory
    }

    private func runIsolated(
        projectDirectory: URL, points: [MutationPoint], scratchRoot: URL, configuration: Configuration = Configuration()
    ) async throws -> [MutationResult] {
        let plan = MutationPlan(
            planID: "plan-differential-isolated", createdAt: Date(), projectRoot: projectDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: configuration.configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [BoolLiteralInversionOperator.descriptor]
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: projectDirectory,
            build: adapter, test: adapter, workspaces: workspaces
        )
        let report = try await runner.run()
        #expect(report.results.count == 2)
        return report.results
    }

    private func runSchemata(
        projectDirectory: URL, points: [MutationPoint], scratchRoot: URL,
        configuration: Configuration = Configuration(),
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = defaultVerificationPolicy
    ) async throws -> [MutationResult] {
        let chunk = SchemataChunk(
            chunkID: "differential-fixture-chunk", points: points,
            projectIdentity: "DifferentialFixtureLib.xcodeproj",
            target: "DifferentialFixtureLib", module: "DifferentialFixtureLib", product: "DifferentialFixtureLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-differential-schemata", workUnitID: "plan-differential-schemata",
            programs: [program], points: pointsByID, originalSources: [Self.relativePath: Data(Self.librarySource.utf8)],
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 120),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: policy
        )
        let outcome = try await runner.run()
        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass under schemata too")
        #expect(outcome.results.count == 2)
        return outcome.results
    }

    private func discoverPoints() throws -> [MutationPoint] {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 2, "expected exactly one candidate per function")
        return points
    }

    private func scratchDirectories() throws -> (isolated: URL, schemata: URL) {
        let isolated = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-differential-isolated-\(UUID().uuidString)")
        let schemata = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-differential-schemata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: schemata, withIntermediateDirectories: true)
        return (isolated, schemata)
    }

    @Test("The same MutationID, outcome, scorability, and failing tests are produced by both backends")
    func isolatedAndSchemataAgree() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try discoverPoints()
        let scratch = try scratchDirectories()
        defer {
            try? FileManager.default.removeItem(at: scratch.isolated)
            try? FileManager.default.removeItem(at: scratch.schemata)
        }

        // Sequential, not concurrent: both runners copy the identical
        // project directory into their own sandboxes, but running two
        // independent `swift build`/`swift test` pipelines against the
        // same machine's toolchain caches at once is exactly the kind of
        // resource contention this differential comparison does not need
        // to also debug.
        let isolatedResults = try await runIsolated(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.isolated)
        let schemataResults = try await runSchemata(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.schemata)

        let isolatedByID = Dictionary(uniqueKeysWithValues: isolatedResults.map { ($0.point.id, $0) })
        let schemataByID = Dictionary(uniqueKeysWithValues: schemataResults.map { ($0.point.id, $0) })

        #expect(Set(isolatedByID.keys) == Set(schemataByID.keys), "both backends must classify the exact same set of MutationIDs")

        for point in points {
            let isolated = try #require(isolatedByID[point.id], "isolated backend produced no result for \(point.id.rawValue)")
            let schemata = try #require(schemataByID[point.id], "schemata backend produced no result for \(point.id.rawValue)")

            let outcomeMessage = """
            \(point.id.rawValue): isolated=\(isolated.outcome.rawValue) schemata=\(schemata.outcome.rawValue) — \
            isolated diagnosis: \(isolated.diagnosis); schemata diagnosis: \(schemata.diagnosis)
            """
            #expect(isolated.outcome == schemata.outcome, "\(outcomeMessage)")
            #expect(
                isolated.outcome.isScorable == schemata.outcome.isScorable,
                "\(point.id.rawValue): both backends must agree on whether this result counts toward a score"
            )
            #expect(
                isolated.evidence?.sourceDiff == schemata.evidence?.sourceDiff,
                "\(point.id.rawValue): the logical source-level diff must be identical regardless of which backend applied it"
            )

            if isolated.outcome == .killedByAssertion {
                let isolatedFailing = Set(isolated.testSummary?.failingTests ?? [])
                let schemataFailing = Set(schemata.testSummary?.failingTests ?? [])
                #expect(
                    isolatedFailing == schemataFailing,
                    "\(point.id.rawValue): both backends must report the same failing test(s): isolated=\(isolatedFailing) schemata=\(schemataFailing)"
                )
            }
        }
    }
}
