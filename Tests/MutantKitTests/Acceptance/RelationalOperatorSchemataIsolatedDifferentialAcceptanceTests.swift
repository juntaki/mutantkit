import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The real gate before `RelationalOperatorReplacementSchemataLowerer` can be
/// promoted (`SchemataLowererRegistry.builtIn`): the exact same
/// `MutationPoint`s, discovered once from one fixture, run to completion
/// under both `MutationRunner` (isolated) and `SchemataMutationRunner`
/// (schemata, invoked directly — the lowerer is not registered), and must
/// agree on every mutation's outcome, scorability, and failing tests.
///
/// Covers the operand shapes issue #3 and the lowerer's own eligibility
/// rules both care about: `Int` (the ordinary case), `Decimal` (the real
/// regression — `Comparable`'s default `>=`/`>` implementations both
/// dispatch through `<`, the exact shape that broke `MachOCodeHash` v1),
/// a generic `Comparable`-constrained function, and a custom type with its
/// own `<` overload. Every mutant here is schemata-eligible by design; the
/// lowerer's own unit tests already cover ineligible shapes (side effects,
/// `await`/`try` operands, result-builder bodies) falling back to isolated.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: relational-operator isolated vs schemata differential (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct RORSchemataIsolatedDifferentialAcceptanceTests {
    private static let relativePath = "Sources/RelationalDifferentialFixtureLib/Fixture.swift"

    /// Matches `Configuration()`'s own default `execution` flags exactly —
    /// see `SchemataIsolatedDifferentialAcceptanceTests`'s identical
    /// property for why this must track the isolated runner's own policy.
    private static let defaultVerificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: Configuration().execution.retestKilledMutants,
        confirmCrashKills: Configuration().execution.confirmCrashKills,
        confirmTimedOutMutants: Configuration().execution.confirmTimedOutMutants
    )

    /// Each function's single boundary-value call kills every candidate on
    /// its own `>=`: at the boundary, `>=` is true while both `>` and `<`
    /// are false, so one assertion distinguishes the original from either
    /// mutant without needing a second, non-boundary test.
    private static let librarySource = """
    import Foundation

    public enum RelationalFixture {
        public static func decimalAtLeastTen(_ value: Decimal) -> Bool {
            value >= 10
        }

        public static func intAtLeastTen(_ value: Int) -> Bool {
            value >= 10
        }

        public static func genericAtLeast<T: Comparable>(_ value: T, _ threshold: T) -> Bool {
            value >= threshold
        }

        public struct Meters: Comparable {
            public let value: Double
            public init(_ value: Double) { self.value = value }
            public static func < (lhs: Meters, rhs: Meters) -> Bool { lhs.value < rhs.value }
        }

        public static func customAtLeastTenMeters(_ value: Meters) -> Bool {
            value >= Meters(10)
        }

        // The real shape found via Expansion against swift-numerics: an old
        // lowerer version forced both operands into one shared generic type
        // parameter, which failed to compile for two different (but
        // directly comparable, via `BinaryInteger`'s own heterogeneous
        // comparison operator) integer types — never for `Int` alone.
        public static func mixedWidthAtLeast(_ a: Int, _ b: UInt32) -> Bool {
            a >= b
        }
    }

    """

    private static let testSource = """
    import XCTest
    import RelationalDifferentialFixtureLib

    final class RelationalDifferentialFixtureLibTests: XCTestCase {
        func testDecimalBoundary() {
            XCTAssertTrue(RelationalFixture.decimalAtLeastTen(10))
        }

        func testIntBoundary() {
            XCTAssertTrue(RelationalFixture.intAtLeastTen(10))
        }

        func testGenericBoundary() {
            XCTAssertTrue(RelationalFixture.genericAtLeast(10, 10))
        }

        func testCustomComparableBoundary() {
            XCTAssertTrue(RelationalFixture.customAtLeastTenMeters(RelationalFixture.Meters(10)))
        }

        func testMixedWidthBoundary() {
            XCTAssertTrue(RelationalFixture.mixedWidthAtLeast(10, 10))
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-relational-differential-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/RelationalDifferentialFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/RelationalDifferentialFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "RelationalDifferentialFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "RelationalDifferentialFixtureLib"),
                .testTarget(name: "RelationalDifferentialFixtureLibTests", dependencies: ["RelationalDifferentialFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(
            to: testSourcesDirectory.appendingPathComponent("RelationalDifferentialFixtureLibTests.swift")
        )
        return directory
    }

    private func runIsolated(
        projectDirectory: URL, points: [MutationPoint], scratchRoot: URL, configuration: Configuration = Configuration()
    ) async throws -> [MutationResult] {
        let plan = MutationPlan(
            planID: "plan-relational-differential-isolated", createdAt: Date(), projectRoot: projectDirectory.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: configuration.configurationHash,
            sourceFileHashes: [Self.relativePath: ContentHash.of(Self.librarySource)],
            mutations: points, skipped: [], operators: [RelationalOperatorReplacementOperator.descriptor]
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

    /// Greedily partitions `points` into groups with no two overlapping
    /// `utf8Range`s within a group — mirroring what real chunk planning
    /// does before embedding, and required here because
    /// `RelationalOperatorReplacementOperator` genuinely produces two
    /// candidates (boundary and negation) anchored at the *same* operator
    /// token: both replace the identical byte span, so a chunk cannot embed
    /// them simultaneously any more than production chunking could.
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
        // lowerer is deliberately not registered there (the scoring gate
        // this whole validation branch exists to eventually open), the
        // same way its own unit/acceptance suites already exercise it.
        let lowerer = RelationalOperatorReplacementSchemataLowerer()
        let programs = try Self.nonOverlappingGroups(points).enumerated().map { index, group -> SchemataProgram in
            let chunk = SchemataChunk(
                chunkID: "relational-differential-fixture-chunk-\(index)", points: group,
                projectIdentity: "RelationalDifferentialFixtureLib.xcodeproj",
                target: "RelationalDifferentialFixtureLib", module: "RelationalDifferentialFixtureLib",
                product: "RelationalDifferentialFixtureLib"
            )
            return try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)])
        }
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-relational-differential-schemata", workUnitID: "plan-relational-differential-schemata",
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
            Self.librarySource, operatorID: RelationalOperatorReplacementOperator.descriptor.id, relativePath: Self.relativePath
        )
        // Two candidates (boundary `>`, negation `<`) per `>=` call site
        // across the five functions (10), plus two more from `Meters`'s own
        // `<` operator implementation (`<` -> `<=`/`>`) — a real relational
        // operator inside the fixture too, not just a call site using one.
        #expect(points.count == 12, "expected 10 candidates from the 5 >= call sites plus 2 from Meters.<, got \(points.count)")
        return points
    }

    private func scratchDirectories() throws -> (isolated: URL, schemata: URL) {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-relational-differential-isolated-\(UUID().uuidString)")
        let schemata = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-relational-differential-schemata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: schemata, withIntermediateDirectories: true)
        return (isolated, schemata)
    }

    @Test("The same MutationID, outcome, scorability, and failing tests come from both backends, for Int/Decimal/generic/custom Comparable")
    func isolatedAndSchemataAgree() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try discoverPoints()
        let scratch = try scratchDirectories()
        defer {
            try? FileManager.default.removeItem(at: scratch.isolated)
            try? FileManager.default.removeItem(at: scratch.schemata)
        }

        // Sequential, not concurrent — see
        // `SchemataIsolatedDifferentialAcceptanceTests`'s identical
        // comment: two independent `swift build`/`swift test` pipelines
        // against the same toolchain caches at once is exactly the kind of
        // resource contention this comparison does not need to also debug.
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

    /// The exact regression case, isolated from the rest of the fixture:
    /// `Decimal`'s `>=` compiled through `Comparable`'s default
    /// implementation is what `MachOCodeHash` v1 could not distinguish from
    /// baseline (issue #3). Both backends must agree it is killed, by name,
    /// not merely "some result was produced".
    @Test("Both backends kill the Decimal >= boundary mutants — the real issue #3 shape")
    func decimalBoundaryMutantsAreKilledByBothBackends() async throws {
        let projectDirectory = try stagePackage()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let points = try discoverPoints().filter { $0.enclosingDeclaration.path.last == "decimalAtLeastTen(_:)" }
        #expect(points.count == 2)

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
