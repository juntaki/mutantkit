import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0006 Stage 3: proves schemata confirmation end to end against a real
/// toolchain — policy decision -> a second, genuinely independent process
/// -> its own fresh RunID/transcript -> `MutationVerdictVerifier`'s
/// independent chain validation -> the final scored outcome. Not a unit
/// test standing in for this: `SchemataConfirmationVerifierTests` already
/// pins the verifier's own rules directly; this suite is the one place
/// that proves `SchemataMutationRunner` actually wires a real confirming
/// process together correctly.
///
/// Not a crash-confirmation suite: a genuine SwiftPM crash (a real signal,
/// not `fatalError`/`XCTFail`, both of which this toolchain's `swift test`
/// coordinator catches and reports as an ordinary `exitCode == 1` failure —
/// proven empirically, not assumed) never reaches the outer `swift test`
/// process's own exit status as a signal, so `.crashed` is structurally
/// unobservable through this adapter's `terminatingSignal` classification
/// for a SwiftPM in-process worker crash. No existing acceptance test in
/// this repository, isolated or schemata, exercises `.crashed` via real
/// SwiftPM either — this is a pre-existing toolchain-level gap, not
/// something introduced or left by this suite. Assertion-kill confirmation
/// is used instead, which is both reliably reproducible and is itself one
/// of Stage 3's required real-toolchain acceptance scenarios.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: schemata confirmation (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct SchemataConfirmationAcceptanceTests {
    private static let relativePath = "Sources/ConfirmationFixtureLib/Widget.swift"

    /// `shouldPass()` starting `true` means the baseline assertion never
    /// fails — the unmutated suite passes cleanly. Flipping it to `false`
    /// makes `XCTAssertTrue` fail as an ordinary, cleanly-reported test
    /// assertion (not a process-level trap), so the xunit report parses
    /// cleanly and `confirmKill` can compare the confirming run's own
    /// failing-test set against the primary run's.
    private static let librarySource = """
    public func shouldPass() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import ConfirmationFixtureLib

    final class ConfirmationFixtureLibTests: XCTestCase {
        func testShouldPass() {
            XCTAssertTrue(shouldPass())
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-schemata-confirm-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/ConfirmationFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/ConfirmationFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "ConfirmationFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "ConfirmationFixtureLib"),
                .testTarget(name: "ConfirmationFixtureLibTests", dependencies: ["ConfirmationFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("ConfirmationFixtureLibTests.swift"))
        return directory
    }

    private func lowerFixture() throws -> (points: [MutationPoint], program: SchemataProgram) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let chunk = SchemataChunk(
            chunkID: "schemata-confirm-fixture-chunk", points: points,
            projectIdentity: "ConfirmationFixtureLib.xcodeproj",
            target: "ConfirmationFixtureLib", module: "ConfirmationFixtureLib", product: "ConfirmationFixtureLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        return (points, program)
    }

    @Test("A killed mutant is confirmed by a genuinely independent second process before being credited as killedByAssertion")
    func killIsConfirmedByARealIndependentProcess() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-schemata-confirm-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let (points, program) = try lowerFixture()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let originalSources = [Self.relativePath: Data(Self.librarySource.utf8)]

        // `--parallel` is what makes `swift test` write the per-test xunit
        // counts `confirmKill` needs to compare the two runs' failing-test
        // sets — serially it reports none (`TestSettings.parallel`'s own
        // doc comment), which would sink every confirmation as unprovable
        // rather than actually exercising the comparison.
        var configuration = Configuration()
        configuration.tests.parallel = true
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: true, confirmCrashKills: false, confirmTimedOutMutants: false
        )
        let runner = SchemataMutationRunner(
            planID: "plan-schemata-confirm", workUnitID: "plan-schemata-confirm",
            programs: [program], points: pointsByID, originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeoutSeconds: 120,
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: policy
        )

        let outcome = try await runner.run()

        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass")
        #expect(outcome.results.count == 1)
        let result = try #require(outcome.results.first)
        // `killedByAssertion` surviving `retestKilledMutants: true` is only
        // reachable when `confirmKill` finds a second, genuinely
        // independent run (its own fresh RunID/transcript/process — refused
        // otherwise by `schemataConfirmationChainProblem`, pinned directly
        // by `SchemataConfirmationVerifierTests`) that failed the exact same
        // test(s) as the primary run — this outcome alone is the real,
        // end-to-end proof a second independent process ran and was
        // credited, not a placeholder standing in for inspecting it.
        #expect(result.outcome == .killedByAssertion, "flipping shouldPass() must fail the assertion, confirmed: \(result.diagnosis)")
        #expect(
            result.diagnosis.contains("Confirmed by a second run of the identical mutant"),
            "the diagnosis itself must name the confirmation, not just the primary failure: \(result.diagnosis)"
        )

        guard case .schemata = result.evidence?.applicationEvidence else {
            Issue.record("expected a schemata observation, got \(String(describing: result.evidence?.applicationEvidence))")
            return
        }

        // Sandbox cleanup: nothing should be left behind in the scratch root.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)
        #expect(leftovers.isEmpty, "every sandbox must be destroyed after use, found: \(leftovers)")
    }
}
