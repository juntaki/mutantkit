import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0006 Stage 3: the confirmation-inclusive twin of
/// `SchemataIsolatedDifferentialAcceptanceTests` — with
/// `retestKilledMutants: true`, both backends must run a confirmation and
/// reach the exact same `MutationVerdictVerifier.confirmKill` diagnosis,
/// not merely agree on the outcome enum.
///
/// A single mutation point and a single test method, deliberately separate
/// from `SchemataIsolatedDifferentialAcceptanceTests`'s own two-mutation
/// fixture: `--parallel` (needed so `confirmKill` has per-test xunit counts
/// to compare) spawns one worker process per test method once there is more
/// than one, and each worker independently initializes the schemata runtime
/// and writes its own STARTUP to the same shared transcript path — breaking
/// the "exactly one STARTUP" chain invariant `verifySchemataChain` requires.
/// A one-test fixture sidesteps that: `--parallel` with a single test
/// method never actually parallelizes anything, so schemata's
/// single-process transcript assumption still holds. (`--parallel` with
/// real concurrency is a genuine, pre-existing limitation of schemata's
/// runtime evidence collection — flagged in ADR-0006 as a known limitation,
/// not something this suite works around by design choice.)
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: isolated vs schemata differential with confirmation (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct SchemataConfirmationDifferentialAcceptanceTests {
    private static let relativePath = "Sources/ConfirmationDifferentialFixtureLib/Widget.swift"

    private static let librarySource = """
    public func shouldPass() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import ConfirmationDifferentialFixtureLib

    final class ConfirmationDifferentialFixtureLibTests: XCTestCase {
        func testShouldPass() {
            XCTAssertTrue(shouldPass())
        }
    }

    """

    /// `retestKilledMutants: true` is what makes this suite actually
    /// exercise a confirmation on both backends — `confirmKill`'s diagnosis
    /// text is produced by the one shared `MutationVerdictVerifier` both
    /// runners call into, so an identical "Confirmed by a second run..."
    /// string on both sides is itself proof the two backends ran the same
    /// shared decision logic, not two independently-reimplemented ones.
    private static let confirmationEnabledPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: true, confirmCrashKills: true, confirmTimedOutMutants: false
    )

    /// `swift test` only writes per-test xunit counts in `--parallel` mode
    /// (`TestSettings.parallel`'s own doc comment) — without it,
    /// `confirmKill` cannot compare the two runs' failing-test sets and
    /// sinks every retest to `.flaky` rather than exercising the
    /// comparison this suite exists to prove.
    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.tests.parallel = true
        configuration.execution.retestKilledMutants = true
        return configuration
    }

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-differential-confirm-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/ConfirmationDifferentialFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/ConfirmationDifferentialFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "ConfirmationDifferentialFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "ConfirmationDifferentialFixtureLib"),
                .testTarget(name: "ConfirmationDifferentialFixtureLibTests", dependencies: ["ConfirmationDifferentialFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8)
            .write(to: testSourcesDirectory.appendingPathComponent("ConfirmationDifferentialFixtureLibTests.swift"))
        return directory
    }

    private func runIsolated(projectDirectory: URL, points: [MutationPoint], scratchRoot: URL) async throws -> [MutationResult] {
        let plan = MutationPlan(
            planID: "plan-differential-confirm-isolated", createdAt: Date(), projectRoot: projectDirectory.path,
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
        return report.results
    }

    private func runSchemata(projectDirectory: URL, points: [MutationPoint], scratchRoot: URL) async throws -> [MutationResult] {
        let chunk = SchemataChunk(
            chunkID: "differential-confirm-fixture-chunk", points: points,
            projectIdentity: "ConfirmationDifferentialFixtureLib.xcodeproj",
            target: "ConfirmationDifferentialFixtureLib", module: "ConfirmationDifferentialFixtureLib",
            product: "ConfirmationDifferentialFixtureLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let adapter = SwiftPackageMacOSAdapter(configuration: Self.configuration())
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let originalSources = [Self.relativePath: Data(Self.librarySource.utf8)]
        let runner = SchemataMutationRunner(
            planID: "plan-differential-confirm-schemata", workUnitID: "plan-differential-confirm-schemata",
            programs: [program], points: pointsByID, originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 120),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: Self.confirmationEnabledPolicy
        )
        let outcome = try await runner.run()
        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass under schemata too")
        #expect(outcome.results.count == 1)
        return outcome.results
    }

    @Test("With retestKilledMutants enabled, both backends run a confirmation and reach the identical shared confirmKill diagnosis")
    func isolatedAndSchemataAgreeWithConfirmation() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let isolatedScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-differential-confirm-isolated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolatedScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedScratch) }

        let schemataScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-differential-confirm-schemata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: schemataScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: schemataScratch) }

        let isolatedResults = try await runIsolated(projectDirectory: projectDirectory, points: points, scratchRoot: isolatedScratch)
        let schemataResults = try await runSchemata(projectDirectory: projectDirectory, points: points, scratchRoot: schemataScratch)

        let isolated = try #require(isolatedResults.first)
        let schemata = try #require(schemataResults.first)

        #expect(
            isolated.outcome == .killedByAssertion,
            "the isolated backend must classify the mutation killedByAssertion: \(isolated.diagnosis)"
        )
        #expect(
            schemata.outcome == .killedByAssertion,
            "the schemata backend must classify the mutation killedByAssertion: \(schemata.diagnosis)"
        )

        // The proof this suite exists for: both backends reach the exact
        // same confirmation diagnosis, produced by the one shared
        // `MutationVerdictVerifier.confirmKill` both runners call into —
        // never two independently-derived confirmation verdicts that
        // merely happen to agree on the outcome enum.
        let confirmedText = "Confirmed by a second run of the identical mutant, failing the same test(s)."
        #expect(isolated.diagnosis.contains(confirmedText), "isolated diagnosis must show a real confirmation: \(isolated.diagnosis)")
        #expect(schemata.diagnosis.contains(confirmedText), "schemata diagnosis must show a real confirmation: \(schemata.diagnosis)")
    }
}
