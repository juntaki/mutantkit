import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// EXPERIMENTAL (Research/safe-mutant-mixing-2026-09/DESIGN.md).
///
/// The differential-testing evidence the design doc's "conflict graph has no
/// false negative" claim rests on, against a *real* per-test coverage map —
/// not the hand-built one `MutantConflictGraphTests` uses for fast, everyday
/// iteration. This suite runs the actual `SwiftPackageMacOSAdapter` build +
/// `measurePerTestCoverage` pass (plain `swift build`/`swift test`, no
/// Xcode/simulator involved) against a small fixture engineered to have one
/// real conflict (a helper function two tests both cover) and one real,
/// non-obvious safe pair (two callers of that same helper whose own tests
/// never overlap) — then proves the planner gets both right using coverage
/// data no test in this suite hand-wrote.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1
/// swift test --filter MutantMixingRealFixtureAcceptanceTests`. Fast: one
/// small SwiftPM package, no simulator.
@Suite("Acceptance: mutant mixing conflict graph against a real per-test coverage map", .enabled(if: Acceptance.isEnabled))
struct MutantMixingRealFixtureAcceptanceTests {
    // Identical in content to `MutantConflictGraphTests.calcSource` on
    // purpose: this suite exists to confirm that fixture's hand-built
    // `PerTestCoverageMap` matches what a real measurement actually
    // produces, so the same source has to be measured, not merely
    // resembled.
    private static let librarySource = """
    public enum Calc {
        public static func add(_ x: Int, _ y: Int) -> Int {
            x + y
        }

        public static func subtract(_ x: Int, _ y: Int) -> Int {
            x - y
        }

        public static func helper(_ x: Int) -> Int {
            x + 1
        }

        public static func addUsingHelper(_ x: Int, _ y: Int) -> Int {
            helper(x) + y
        }

        public static func subtractUsingHelper(_ x: Int, _ y: Int) -> Int {
            helper(x) - y
        }
    }

    """

    private static let testSource = """
    import XCTest
    @testable import Calc

    final class CalcTests: XCTestCase {
        func testAdd() {
            XCTAssertEqual(Calc.add(2, 3), 5)
        }

        func testSubtract() {
            XCTAssertEqual(Calc.subtract(5, 3), 2)
        }

        func testAddUsingHelper() {
            XCTAssertEqual(Calc.addUsingHelper(2, 3), 6)
        }

        func testSubtractUsingHelper() {
            XCTAssertEqual(Calc.subtractUsingHelper(5, 3), 3)
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-mixing-fixture-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/Calc")
        let testsDirectory = directory.appendingPathComponent("Tests/CalcTests")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testsDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "Calc",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "Calc"),
                .testTarget(name: "CalcTests", dependencies: ["Calc"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: sourcesDirectory.appendingPathComponent("Calc.swift"))
        try Data(Self.testSource.utf8).write(to: testsDirectory.appendingPathComponent("CalcTests.swift"))
        return directory
    }

    private func line(containing needle: String) throws -> Int {
        try #require(Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains(needle) }) + 1
    }

    @Test("Real measured coverage: the planner's conflict graph has no false negative, and mixes the safe pair")
    func realCoverageProducesTheExpectedSafeAndUnsafePairs() async throws {
        let workspace = try stagePackage()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)
        let coverage = try #require(
            await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120),
            "expected a non-empty real per-test coverage map from a real build+test pass"
        )

        let points = try discover(Self.librarySource, path: "Sources/Calc/Calc.swift", using: Operators.arithmetic)
        #expect(points.count == 5, "fixture is expected to yield exactly 5 arithmetic mutation points")

        let plan = MutantMixingPlanner.plan(points: points, coverage: coverage)

        // Sanity: real measurement actually attributed every one of these
        // lines to something, or the rest of this test is checking nothing.
        #expect(plan.unmixable.isEmpty, "every mutated line in this fixture is exercised by some test")
        #expect(plan.accountedForCount == points.count)

        // (a) No false negative, checked against the *real* map: for every
        // pair of mutants the planner placed in the same batch, their real
        // covering-test sets — looked up independently of the planner's own
        // bookkeeping — must be disjoint.
        let testsByID = Dictionary(
            uniqueKeysWithValues: points.map { ($0.id, coverage.testsCovering(file: $0.file, line: $0.line) ?? []) }
        )
        for batch in plan.batches {
            for i in batch.indices {
                for j in batch.indices where j > i {
                    let a = testsByID[batch[i]] ?? []
                    let b = testsByID[batch[j]] ?? []
                    #expect(
                        a.isDisjoint(with: b),
                        "\(batch[i]) and \(batch[j]) share a real covering test but were batched together"
                    )
                }
            }
        }

        // The one real conflict a shared helper produces: `helper`'s line is
        // covered by both `*UsingHelper` tests, so it must never share a
        // batch with either of the mutants those tests also cover.
        let helperLine = try line(containing: "x + 1")
        let addUsingHelperLine = try line(containing: "helper(x) + y")
        let subtractUsingHelperLine = try line(containing: "helper(x) - y")

        let helperID = try #require(points.first { $0.line == helperLine }).id
        let addUsingHelperID = try #require(points.first { $0.line == addUsingHelperLine }).id
        let subtractUsingHelperID = try #require(points.first { $0.line == subtractUsingHelperLine }).id

        let helperTests = try #require(coverage.testsCovering(file: "Sources/Calc/Calc.swift", line: helperLine))
        #expect(
            Set(helperTests.map(\.qualifiedName)) == ["CalcTests/testAddUsingHelper", "CalcTests/testSubtractUsingHelper"],
            "the real measurement is expected to show both callers reaching the shared helper's line"
        )

        let helperBatch = try #require(plan.batches.first { $0.contains(helperID) })
        #expect(!helperBatch.contains(addUsingHelperID))
        #expect(!helperBatch.contains(subtractUsingHelperID))

        // The non-obvious safe pair: real coverage shows these two tests
        // never overlap, so the two functions that both call the shared
        // helper — but are covered by different tests themselves — are
        // still batched together.
        let addUsingHelperBatch = try #require(plan.batches.first { $0.contains(addUsingHelperID) })
        #expect(addUsingHelperBatch.contains(subtractUsingHelperID))

        #expect(plan.batches.count == 2, "5 real mutants, 1 real conflict, should color into exactly 2 batches")
    }
}
