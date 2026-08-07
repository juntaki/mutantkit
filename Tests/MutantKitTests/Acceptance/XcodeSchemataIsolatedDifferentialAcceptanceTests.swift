import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The Xcode half of ADR-0006 Stage 3's gate — the same comparison
/// `SchemataIsolatedDifferentialAcceptanceTests` proves for SwiftPM, against
/// a real `xcodegen`-generated macOS framework + unit-test bundle instead of
/// a Swift package: the exact same `MutationPoint`s run to completion under
/// both `MutationRunner` (isolated) and `SchemataMutationRunner` (schemata)
/// must agree.
///
/// A macOS unit test target, not iOS Simulator, on the same reasoning every
/// other Xcode schemata acceptance suite in this file group already
/// documents: it isolates this comparison from simulator-specific concerns.
///
/// Off by default like every other acceptance suite (`xcodegen generate`
/// plus real `xcodebuild` invocations, twice): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: isolated vs schemata differential (Xcode)", .enabled(if: Acceptance.isEnabled))
struct XcodeSchemataIsolatedDifferentialAcceptanceTests {
    /// Matches `Configuration()`'s own default `execution` flags — see
    /// `SchemataIsolatedDifferentialAcceptanceTests`'s identical constant
    /// for why this must be shared, not independently re-derived.
    private static let defaultVerificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: Configuration().execution.retestKilledMutants,
        confirmCrashKills: Configuration().execution.confirmCrashKills,
        confirmTimedOutMutants: Configuration().execution.confirmTimedOutMutants
    )

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
    import XcodeDifferentialLib

    final class XcodeDifferentialLibTests: XCTestCase {
        func testKilledFlag() {
            XCTAssertTrue(killedFlag())
        }

        func testSurvivedFlagIsCalled() {
            _ = survivedFlag()
            XCTAssertTrue(true)
        }
    }

    """

    private static let relativePath = "Sources/Widget.swift"

    private func stageProject() throws -> (directory: URL, projectFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xcode-differential-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources")
        let testSourcesDirectory = directory.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let projectManifest = """
        name: XcodeDifferentialLib
        options:
          bundleIdPrefix: dev.mutantkit.spike
        targets:
          XcodeDifferentialLib:
            type: framework
            platform: macOS
            sources: [Sources]
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
          XcodeDifferentialLibTests:
            type: bundle.unit-test
            platform: macOS
            sources: [Tests]
            dependencies:
              - target: XcodeDifferentialLib
                embed: true
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
        schemes:
          XcodeDifferentialLib:
            build:
              targets:
                XcodeDifferentialLib: all
                XcodeDifferentialLibTests: [test]
            test:
              targets: [XcodeDifferentialLibTests]
        """
        try Data(projectManifest.utf8).write(to: directory.appendingPathComponent("project.yml"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("XcodeDifferentialLibTests.swift"))

        try runXcodegen(in: directory)

        return (directory, directory.appendingPathComponent("XcodeDifferentialLib.xcodeproj"))
    }

    private func runXcodegen(in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcodegen", "generate"]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "xcodegen generate failed:\n\(output)")
    }

    private func makeAdapter(projectRoot: URL, projectFile: URL) -> XcodeBuildAdapter {
        XcodeBuildAdapter(configuration: Configuration(), kind: .xcodeProject, projectFile: projectFile, projectRoot: projectRoot)
    }

    private func runIsolated(directory: URL, projectFile: URL, points: [MutationPoint], scratchRoot: URL) async throws -> [MutationResult] {
        let plan = MutationPlan(
            planID: "plan-xcode-differential-isolated", createdAt: Date(), projectRoot: directory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: Configuration().configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [BoolLiteralInversionOperator.descriptor]
        )
        let adapter = makeAdapter(projectRoot: directory, projectFile: projectFile)
        let workspaces = try WorkspaceManager(projectRoot: directory, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: Configuration(), projectRoot: directory, build: adapter, test: adapter, workspaces: workspaces
        )
        let report = try await runner.run()
        #expect(report.results.count == 2)
        return report.results
    }

    private func runSchemata(directory: URL, projectFile: URL, points: [MutationPoint], scratchRoot: URL) async throws -> [MutationResult] {
        let chunk = SchemataChunk(
            chunkID: "xcode-differential-chunk", points: points,
            projectIdentity: "XcodeDifferentialLib.xcodeproj",
            target: "XcodeDifferentialLib", module: "XcodeDifferentialLib", product: "XcodeDifferentialLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let adapter = makeAdapter(projectRoot: directory, projectFile: projectFile)
        let workspaces = try WorkspaceManager(projectRoot: directory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-xcode-differential-schemata", workUnitID: "plan-xcode-differential-schemata",
            programs: [program], points: pointsByID, originalSources: [Self.relativePath: Data(Self.librarySource.utf8)],
            build: adapter, test: adapter, workspaces: workspaces, timeoutSeconds: 180,
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: Self.defaultVerificationPolicy
        )
        let outcome = try await runner.run()
        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass under schemata too")
        #expect(outcome.results.count == 2)
        return outcome.results
    }

    @Test("The same MutationID, outcome, scorability, and failing tests are produced by both backends")
    func isolatedAndSchemataAgree() async throws {
        let (directory, projectFile) = try stageProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 2, "expected exactly one candidate per function")

        let isolatedScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xcode-differential-isolated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolatedScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedScratch) }

        let schemataScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xcode-differential-schemata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: schemataScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: schemataScratch) }

        // Sequential, not concurrent — see
        // SchemataIsolatedDifferentialAcceptanceTests's own note on why two
        // independent xcodebuild pipelines should not race each other on
        // the same machine.
        let isolatedResults = try await runIsolated(
            directory: directory, projectFile: projectFile, points: points, scratchRoot: isolatedScratch
        )
        let schemataResults = try await runSchemata(
            directory: directory, projectFile: projectFile, points: points, scratchRoot: schemataScratch
        )

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
