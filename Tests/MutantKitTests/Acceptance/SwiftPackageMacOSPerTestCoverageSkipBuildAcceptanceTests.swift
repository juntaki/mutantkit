import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Regression coverage for the `skipBuild` parameter `SwiftPackageMacOSAdapter
/// .runTests` gained so `measurePerTestCoverage`'s per-test loop can pass
/// `--skip-build --enable-code-coverage` together from its second iteration
/// on, instead of paying for SwiftPM's build-graph check on every one of
/// what can be hundreds of per-test invocations.
///
/// The risk that change carries is not "it doesn't build" — `swift build`
/// already fails loudly — it is "coverage silently gets attributed to the
/// wrong test", because `selectCoveringTests` uses exactly this map to
/// narrow which tests a mutant's build gets tested against. A too-narrow
/// selection from cross-test contamination would mean a mutant is never
/// tested against the one test that actually kills it — a false survivor,
/// the single failure class this whole tool exists to prevent. So this
/// suite's assertion is deliberately about *attribution*, not merely "did a
/// map come back non-empty": two functions, each covered by exactly one of
/// two `XCTestCase` methods, must stay attributed to the right one now that
/// most of the loop's invocations skip the build step.
///
/// Deliberately plain `XCTestCase`, not Swift Testing — not to route around
/// a filter bug (P12-B fixed that), but so the SwiftPM/XCTest report path
/// independently guarantees this same coverage-freshness contract:
/// `SwiftPackageMacOSSwiftTestingSelectionAcceptanceTests` already exercises
/// `measurePerTestCoverage` end to end through Swift Testing's own report
/// path (and, since this loop now passes `skipBuild: true` from its second
/// iteration on, already exercises that flag combination there too) — this
/// suite covers the other framework `measurePerTestCoverage` supports,
/// rather than duplicating the same one.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SwiftPackageMacOSAdapter per-test coverage skip-build", .enabled(if: Acceptance.isEnabled))
struct SwiftPackageMacOSPerTestCoverageSkipBuildAcceptanceTests {
    private static let librarySource = """
    public enum Calc {
        public static func double(_ x: Int) -> Int {
            x * 2
        }

        public static func triple(_ x: Int) -> Int {
            x * 3
        }
    }

    """

    private static let testSource = """
    import XCTest
    @testable import Calc

    final class CalcTests: XCTestCase {
        func testDouble() {
            XCTAssertEqual(Calc.double(4), 8)
        }

        func testTriple() {
            XCTAssertEqual(Calc.triple(4), 12)
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-skipbuild-coverage-\(UUID().uuidString)")
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

    @Test("Per-test coverage attribution stays correct once later invocations skip the build")
    func attributionStaysCorrectAcrossSkippedBuilds() async throws {
        let workspace = try stagePackage()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)

        let map = try #require(
            await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120),
            "expected a non-empty per-test coverage map from a real build+test pass"
        )

        let doubleLine = try #require(
            Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains("x * 2") }
        ) + 1
        let tripleLine = try #require(
            Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains("x * 3") }
        ) + 1

        let calcFile = "Sources/Calc/Calc.swift"
        let doubleTests = try #require(
            map.testsCovering(file: calcFile, line: doubleLine),
            "expected `Calc.double`'s line to be attributed to a covering test"
        )
        let tripleTests = try #require(
            map.testsCovering(file: calcFile, line: tripleLine),
            "expected `Calc.triple`'s line to be attributed to a covering test"
        )

        let doubleNames = Set(doubleTests.map(\.qualifiedName))
        let tripleNames = Set(tripleTests.map(\.qualifiedName))

        #expect(doubleNames.contains("CalcTests/testDouble"))
        #expect(!doubleNames.contains("CalcTests/testTriple"))
        #expect(tripleNames.contains("CalcTests/testTriple"))
        #expect(!tripleNames.contains("CalcTests/testDouble"))
    }
}
