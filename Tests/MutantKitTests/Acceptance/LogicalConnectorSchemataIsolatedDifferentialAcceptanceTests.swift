import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The real gate before `LogicalConnectorReplacementSchemataLowerer` can be
/// promoted (`SchemataLowererRegistry.builtIn`): the exact same
/// `MutationPoint`s, discovered once from one fixture, run to completion
/// under both `MutationRunner` (isolated) and `SchemataMutationRunner`
/// (schemata, invoked directly — the lowerer is not registered), and must
/// agree on every mutation's outcome, scorability, and failing tests.
///
/// Modeled directly on `RORSchemataIsolatedDifferentialAcceptanceTests`,
/// which this promotion sequence is following one operator at a time.
/// Covers `&&`/`||` over plain identifiers, `self.` member access, and a
/// short-circuit-relevant boundary (the `eitherTrue`/`bothTrue` cases below
/// are each only killed by a test that would pass under the *other*
/// connector too, unless chosen at the one input where `&&` and `||`
/// disagree).
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: logical-connector isolated vs schemata differential (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct LogicalConnectorSchemataIsolatedDifferentialAcceptanceTests {
    private static let relativePath = "Sources/LogicalConnectorDifferentialFixtureLib/Fixture.swift"

    private static let defaultVerificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: Configuration().execution.retestKilledMutants,
        confirmCrashKills: Configuration().execution.confirmCrashKills,
        confirmTimedOutMutants: Configuration().execution.confirmTimedOutMutants
    )

    /// `bothRequired`/`eitherSufficient` are each tested at the one input
    /// where `&&` and `||` disagree (`true, false`), so a single assertion
    /// kills the mutant on its own connector without needing a second test.
    /// `S.bothFieldsSet` covers `self.`-qualified member-access operands,
    /// the other operand shape ROR's own fixture exercises.
    private static let librarySource = """
    public enum LogicalConnectorFixture {
        public static func bothRequired(_ a: Bool, _ b: Bool) -> Bool {
            a && b
        }

        public static func eitherSufficient(_ a: Bool, _ b: Bool) -> Bool {
            a || b
        }

        public struct S {
            public let ready: Bool
            public let armed: Bool
            public init(ready: Bool, armed: Bool) {
                self.ready = ready
                self.armed = armed
            }
            public func bothFieldsSet() -> Bool {
                self.ready && self.armed
            }
        }
    }

    """

    private static let testSource = """
    import XCTest
    import LogicalConnectorDifferentialFixtureLib

    final class LogicalConnectorDifferentialFixtureLibTests: XCTestCase {
        func testBothRequired() {
            XCTAssertFalse(LogicalConnectorFixture.bothRequired(true, false))
        }

        func testEitherSufficient() {
            XCTAssertTrue(LogicalConnectorFixture.eitherSufficient(true, false))
        }

        func testBothFieldsSet() {
            let s = LogicalConnectorFixture.S(ready: true, armed: false)
            XCTAssertFalse(s.bothFieldsSet())
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-logical-connector-differential-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/LogicalConnectorDifferentialFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/LogicalConnectorDifferentialFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "LogicalConnectorDifferentialFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "LogicalConnectorDifferentialFixtureLib"),
                .testTarget(name: "LogicalConnectorDifferentialFixtureLibTests", dependencies: ["LogicalConnectorDifferentialFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(
            to: testSourcesDirectory.appendingPathComponent("LogicalConnectorDifferentialFixtureLibTests.swift")
        )
        return directory
    }

    private func runIsolated(
        projectDirectory: URL, points: [MutationPoint], scratchRoot: URL, configuration: Configuration = Configuration()
    ) async throws -> [MutationResult] {
        let plan = MutationPlan(
            planID: "plan-logical-connector-differential-isolated", createdAt: Date(), projectRoot: projectDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: configuration.configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [LogicalConnectorReplacementOperator.descriptor]
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: projectDirectory,
            build: adapter, test: adapter, workspaces: workspaces
        )
        let report = try await runner.run()
        #expect(report.results.count == points.count)
        return report.results
    }

    private static func nonOverlappingGroups(_ points: [MutationPoint]) -> [[MutationPoint]] {
        var groups: [[(range: ByteRange, point: MutationPoint)]] = []
        for point in points.sorted(by: { $0.utf8Range.start < $1.utf8Range.start }) {
            if let index = groups.firstIndex(where: { group in
                group.allSatisfy { $0.range.end <= point.utf8Range.start || point.utf8Range.end <= $0.range.start }
            }) {
                groups[index].append((point.utf8Range, point))
            } else {
                groups.append([(point.utf8Range, point)])
            }
        }
        return groups.map { $0.map(\.point) }
    }

    private func runSchemata(
        projectDirectory: URL, points: [MutationPoint], scratchRoot: URL,
        configuration: Configuration = Configuration(),
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = defaultVerificationPolicy
    ) async throws -> [MutationResult] {
        // Invoked directly, never through `SchemataLowererRegistry`: this
        // lowerer is deliberately not registered there yet.
        let lowerer = LogicalConnectorReplacementSchemataLowerer()
        let programs = try Self.nonOverlappingGroups(points).enumerated().map { index, group -> SchemataProgram in
            let chunk = SchemataChunk(
                chunkID: "logical-connector-differential-fixture-chunk-\(index)", points: group,
                projectIdentity: "LogicalConnectorDifferentialFixtureLib.xcodeproj",
                target: "LogicalConnectorDifferentialFixtureLib", module: "LogicalConnectorDifferentialFixtureLib",
                product: "LogicalConnectorDifferentialFixtureLib"
            )
            return try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)])
        }
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-logical-connector-differential-schemata", workUnitID: "plan-logical-connector-differential-schemata",
            programs: programs, points: pointsByID, originalSources: [Self.relativePath: Data(Self.librarySource.utf8)],
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 180),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: policy
        )
        let outcome = try await runner.run()
        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass under schemata too")
        #expect(outcome.results.count == points.count)
        return outcome.results
    }

    private func discoverPoints() throws -> [MutationPoint] {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: LogicalConnectorReplacementOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 3, "expected one candidate each from bothRequired's &&, eitherSufficient's ||, and bothFieldsSet's &&, got \(points.count)")
        return points
    }

    private func scratchDirectories() throws -> (isolated: URL, schemata: URL) {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-logical-connector-differential-isolated-\(UUID().uuidString)")
        let schemata = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-logical-connector-differential-schemata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: schemata, withIntermediateDirectories: true)
        return (isolated, schemata)
    }

    @Test("The same MutationID, outcome, scorability, and failing tests come from both backends, for &&/|| over identifiers and self. member access")
    func isolatedAndSchemataAgree() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try discoverPoints()
        let scratch = try scratchDirectories()
        defer {
            try? FileManager.default.removeItem(at: scratch.isolated)
            try? FileManager.default.removeItem(at: scratch.schemata)
        }

        // Sequential, not concurrent — same reasoning as ROR's own
        // differential test: two independent build/test pipelines against
        // the same toolchain caches at once is contention this comparison
        // does not need to also debug.
        let isolatedResults = try await runIsolated(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.isolated)
        let schemataResults = try await runSchemata(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.schemata)

        let isolatedByID = Dictionary(uniqueKeysWithValues: isolatedResults.map { ($0.point.id, $0) })
        let schemataByID = Dictionary(uniqueKeysWithValues: schemataResults.map { ($0.point.id, $0) })

        #expect(Set(isolatedByID.keys) == Set(schemataByID.keys), "both backends must classify the exact same set of MutationIDs")

        var disagreements: [String] = []
        for point in points {
            let isolated = try #require(isolatedByID[point.id], "isolated backend produced no result for \(point.id.rawValue)")
            let schemata = try #require(schemataByID[point.id], "schemata backend produced no result for \(point.id.rawValue)")
            let label = "\(point.enclosingDeclaration.path.last ?? "?") \(point.originalText)->\(point.replacementText) (\(point.id.rawValue))"

            if isolated.outcome != schemata.outcome {
                disagreements.append(
                    "\(label): outcome isolated=\(isolated.outcome.rawValue) schemata=\(schemata.outcome.rawValue) — " +
                        "isolated diagnosis: \(isolated.diagnosis); schemata diagnosis: \(schemata.diagnosis)"
                )
            }
            #expect(
                isolated.outcome.isScorable == schemata.outcome.isScorable,
                "\(label): both backends must agree on whether this result counts toward a score"
            )
            #expect(
                isolated.evidence?.sourceDiff == schemata.evidence?.sourceDiff,
                "\(label): the logical source-level diff must be identical regardless of which backend applied it"
            )

            if isolated.outcome == .killedByAssertion {
                let isolatedFailing = Set(isolated.testSummary?.failingTests ?? [])
                let schemataFailing = Set(schemata.testSummary?.failingTests ?? [])
                #expect(
                    isolatedFailing == schemataFailing,
                    "\(label): both backends must report the same failing test(s): isolated=\(isolatedFailing) schemata=\(schemataFailing)"
                )
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.joined(separator: "\n"))")
    }

    @Test("Both backends kill every mutant — every fixture site is deliberately covered at its disagreeing input")
    func everyMutantKilledByBothBackends() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try discoverPoints()
        let scratch = try scratchDirectories()
        defer {
            try? FileManager.default.removeItem(at: scratch.isolated)
            try? FileManager.default.removeItem(at: scratch.schemata)
        }

        let isolatedResults = try await runIsolated(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.isolated)
        let schemataResults = try await runSchemata(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.schemata)

        for result in isolatedResults {
            #expect(result.outcome == .killedByAssertion, "isolated: \(result.point.originalText)->\(result.point.replacementText): \(result.diagnosis)")
        }
        for result in schemataResults {
            #expect(result.outcome == .killedByAssertion, "schemata: \(result.point.originalText)->\(result.point.replacementText): \(result.diagnosis)")
        }
    }
}
