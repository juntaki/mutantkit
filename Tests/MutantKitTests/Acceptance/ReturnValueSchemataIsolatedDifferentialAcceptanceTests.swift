import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The real gate before `ReturnValueReplacementSchemataLowerer` can be
/// promoted (`SchemataLowererRegistry.builtIn`): the exact same
/// `MutationPoint`s, discovered once from one fixture, run to completion
/// under both `MutationRunner` (isolated) and `SchemataMutationRunner`
/// (schemata, invoked directly — the lowerer is not registered), and must
/// agree on every mutation's outcome, scorability, and failing tests.
///
/// Modeled directly on `UnaryNotSchemataIsolatedDifferentialAcceptanceTests`,
/// which this promotion sequence is following one operator at a time.
/// Covers all three neutral-default literal kinds this operator ever
/// replaces here: an integer return (`42` -> `0`), a string return
/// (`"ready"` -> `""`), and an array return (`[1, 2, 3]` -> `[]`).
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: return-value isolated vs schemata differential (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct ReturnValueSchemataIsolatedDifferentialAcceptanceTests {
    private static let relativePath = "Sources/ReturnValueDifferentialFixtureLib/Fixture.swift"

    private static let defaultVerificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: Configuration().execution.retestKilledMutants,
        confirmCrashKills: Configuration().execution.confirmCrashKills,
        confirmTimedOutMutants: Configuration().execution.confirmTimedOutMutants
    )

    /// `code`/`label`/`flags` each assert on the exact literal value, so
    /// replacing it with the operator's neutral default (`0`/`""`/`[]`)
    /// kills the mutant on a single assertion.
    private static let librarySource = """
    public enum ReturnValueFixture {
        public static func code() -> Int {
            return 42
        }

        public static func label() -> String {
            return "ready"
        }

        public struct S {
            public init() {}
            public func flags() -> [Int] {
                return [1, 2, 3]
            }
        }
    }

    """

    private static let testSource = """
    import XCTest
    import ReturnValueDifferentialFixtureLib

    final class ReturnValueDifferentialFixtureLibTests: XCTestCase {
        func testCode() {
            XCTAssertEqual(ReturnValueFixture.code(), 42)
        }

        func testLabel() {
            XCTAssertEqual(ReturnValueFixture.label(), "ready")
        }

        func testFlags() {
            XCTAssertEqual(ReturnValueFixture.S().flags(), [1, 2, 3])
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-return-value-differential-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/ReturnValueDifferentialFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/ReturnValueDifferentialFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "ReturnValueDifferentialFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "ReturnValueDifferentialFixtureLib"),
                .testTarget(name: "ReturnValueDifferentialFixtureLibTests", dependencies: ["ReturnValueDifferentialFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(
            to: testSourcesDirectory.appendingPathComponent("ReturnValueDifferentialFixtureLibTests.swift")
        )
        return directory
    }

    private func runIsolated(
        projectDirectory: URL, points: [MutationPoint], scratchRoot: URL, configuration: Configuration = Configuration()
    ) async throws -> [MutationResult] {
        let plan = MutationPlan(
            planID: "plan-return-value-differential-isolated", createdAt: Date(), projectRoot: projectDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: configuration.configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [ReturnValueReplacementOperator.descriptor]
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
        let lowerer = ReturnValueReplacementSchemataLowerer()
        let programs = try Self.nonOverlappingGroups(points).enumerated().map { index, group -> SchemataProgram in
            let chunk = SchemataChunk(
                chunkID: "return-value-differential-fixture-chunk-\(index)", points: group,
                projectIdentity: "ReturnValueDifferentialFixtureLib.xcodeproj",
                target: "ReturnValueDifferentialFixtureLib", module: "ReturnValueDifferentialFixtureLib",
                product: "ReturnValueDifferentialFixtureLib"
            )
            return try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)])
        }
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-return-value-differential-schemata", workUnitID: "plan-return-value-differential-schemata",
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
            Self.librarySource, operatorID: ReturnValueReplacementOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 3, "expected one candidate each from code/label/flags's literal returns, got \(points.count)")
        return points
    }

    private func scratchDirectories() throws -> (isolated: URL, schemata: URL) {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-return-value-differential-isolated-\(UUID().uuidString)")
        let schemata = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-return-value-differential-schemata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: schemata, withIntermediateDirectories: true)
        return (isolated, schemata)
    }

    @Test("Both backends agree on outcome, scorability, and failing tests, for Int/String/array literal returns")
    func isolatedAndSchemataAgree() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try discoverPoints()
        let scratch = try scratchDirectories()
        defer {
            try? FileManager.default.removeItem(at: scratch.isolated)
            try? FileManager.default.removeItem(at: scratch.schemata)
        }

        // Sequential, not concurrent — same reasoning as every other
        // differential test in this promotion sequence: two independent
        // build/test pipelines against the same toolchain caches at once is
        // contention this comparison does not need to also debug.
        let isolatedResults = try await runIsolated(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.isolated)
        let schemataResults = try await runSchemata(projectDirectory: projectDirectory, points: points, scratchRoot: scratch.schemata)

        let isolatedByID = Dictionary(uniqueKeysWithValues: isolatedResults.map { ($0.point.id, $0) })
        let schemataByID = Dictionary(uniqueKeysWithValues: schemataResults.map { ($0.point.id, $0) })

        #expect(Set(isolatedByID.keys) == Set(schemataByID.keys), "both backends must classify the exact same set of MutationIDs")

        var disagreements: [String] = []
        for point in points {
            let isolated = try #require(isolatedByID[point.id], "isolated backend produced no result for \(point.id.rawValue)")
            let schemata = try #require(schemataByID[point.id], "schemata backend produced no result for \(point.id.rawValue)")
            let label =
                "\(point.enclosingDeclaration.path.last ?? "?") \(point.originalText)->\(point.replacementText) (\(point.id.rawValue))"

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

    @Test("Both backends kill every mutant — every fixture site is deliberately covered")
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
            let detail = "isolated: \(result.point.originalText)->\(result.point.replacementText): \(result.diagnosis)"
            #expect(result.outcome == .killedByAssertion, "\(detail)")
        }
        for result in schemataResults {
            let detail = "schemata: \(result.point.originalText)->\(result.point.replacementText): \(result.diagnosis)"
            #expect(result.outcome == .killedByAssertion, "\(detail)")
        }
    }
}
