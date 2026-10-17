import Foundation
import MutationModel
import Testing

/// Phase 3 coverage acceptance for a SwiftPM package with TWO test targets.
///
/// Xcode 27 / Swift 6.4 links each test target into its own `.xctest` bundle
/// (see `docs/schemata-support-matrix.md`, "SwiftPM packages with more than one
/// test target on Xcode 27"). Coverage therefore has to be merged across
/// bundles: if only one bundle's profile were read, the other target's mutants
/// would be wrongly reported `noCoverage` (a dropped mutant), and if profiles
/// were treated as "covered by default" the uncovered function would escape
/// `noCoverage`.
///
/// Fixture (written by the test, no checked-in copy):
/// - `a()` covered only by `TargetATests`
/// - `b()` covered only by `TargetBTests`
/// - `both()` covered by both targets
/// - `c()` covered by neither
@Suite("Acceptance: multi-test-bundle SwiftPM coverage", .enabled(if: Acceptance.isEnabled))
struct MultiTestBundleCoverageAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 2
      measureCoverage: true
      selectCoveringTests: true
    reports: [console, json]
    """

    private static let manifest = """
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "Multi",
        platforms: [.macOS(.v14)],
        products: [.library(name: "Multi", targets: ["Multi"])],
        targets: [
            .target(name: "Multi"),
            .testTarget(name: "TargetATests", dependencies: ["Multi"]),
            .testTarget(name: "TargetBTests", dependencies: ["Multi"]),
        ]
    )
    """

    private static let library = """
    public enum Multi {
        public static func a(_ x: Int) -> Bool {
            x >= 10
        }

        public static func b(_ x: Int) -> Bool {
            x >= 20
        }

        public static func both(_ x: Int) -> Bool {
            x >= 30
        }

        public static func c(_ x: Int) -> Bool {
            x >= 40
        }
    }
    """

    private static let testsA = """
    import XCTest
    @testable import Multi

    final class TargetATests: XCTestCase {
        func testA() {
            XCTAssertTrue(Multi.a(10))
            XCTAssertFalse(Multi.a(9))
        }

        func testBothFromA() {
            XCTAssertTrue(Multi.both(30))
            XCTAssertFalse(Multi.both(29))
        }
    }
    """

    private static let testsB = """
    import XCTest
    @testable import Multi

    final class TargetBTests: XCTestCase {
        func testB() {
            XCTAssertTrue(Multi.b(20))
            XCTAssertFalse(Multi.b(19))
        }

        func testBothFromB() {
            XCTAssertTrue(Multi.both(30))
            XCTAssertFalse(Multi.both(29))
        }
    }
    """

    private static func stage() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mutantkit-multibundle-\(UUID().uuidString)")
        let files: [(String, String)] = [
            ("Package.swift", manifest),
            ("Sources/Multi/Multi.swift", library),
            ("Tests/TargetATests/TargetATests.swift", testsA),
            ("Tests/TargetBTests/TargetBTests.swift", testsB),
            ("mutantkit.yml", configuration)
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    /// The report is decoded into memory, so the staged directory is removed
    /// before the result is handed to the tests.
    private static let sharedRun = Result { () -> AcceptanceRun in
        let directory = try stage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        guard plan.exitCode == 0 else {
            throw AcceptanceError.commandFailed(command: "plan", exitCode: plan.exitCode, output: plan.output)
        }
        let execution = try Acceptance.run(["run", "--plan", "plan.json", "--report", "json"], in: directory)
        let reportURL = directory.appendingPathComponent(".mutantkit/report.json")
        guard let data = try? Data(contentsOf: reportURL) else {
            throw AcceptanceError.commandFailed(command: "run", exitCode: execution.exitCode, output: execution.output)
        }
        return AcceptanceRun(
            report: try MutationPlan.decoder().decode(RunReport.self, from: data),
            planOutput: plan.output,
            runOutput: execution.output,
            exitCode: execution.exitCode,
            directory: directory
        )
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    private func name(_ result: MutationResult) -> String {
        result.point.enclosingDeclaration.path.last ?? "?"
    }

    @Test("Coverage from both test bundles is merged; only the uncovered function is noCoverage")
    func coverageIsMergedAcrossBundles() throws {
        let run = try self.run()
        let noCoverage = Set(run.report.results.filter { $0.outcome == .noCoverage }.map(name))
        #expect(noCoverage == ["c(_:)"], "\(run.runOutput)")

        let covered = Set(run.report.results.filter { $0.outcome != .noCoverage }.map(name))
        #expect(covered == ["a(_:)", "b(_:)", "both(_:)"], "\(run.runOutput)")
    }

    @Test("Covered mutants from each bundle are planned, built, and killed")
    func coveredMutantsAreNotDropped() throws {
        let run = try self.run()
        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.discovered == integrity.planned)
        #expect(integrity.classified == integrity.discovered)
        #expect(integrity.reported == integrity.discovered)

        for declaration in ["a(_:)", "b(_:)", "both(_:)"] {
            let results = run.report.results.filter { name($0) == declaration }
            #expect(!results.isEmpty, "\(declaration) has no results")
            #expect(
                results.contains { $0.outcome == .killedByAssertion || $0.outcome == .killedByCrash },
                "\(declaration) has no killed mutant: \(results.map(\.outcome))"
            )
            #expect(!results.contains { $0.outcome == .survived }, "\(declaration): \(results.map(\.outcome))")
        }
    }

    @Test("The uncovered mutant carries a source diff but was never built")
    func uncoveredMutantIsNotBuilt() throws {
        let run = try self.run()
        let uncovered = run.report.results.filter { $0.outcome == .noCoverage }
        #expect(!uncovered.isEmpty)
        for result in uncovered {
            #expect(result.evidence?.provesSourceApplication == true)
            #expect(result.evidence?.buildProductHash == nil)
            #expect(result.evidence?.applicationEvidence == nil)
        }
        let score = try #require(run.report.score)
        #expect(score.noCoverage == uncovered.count)
        #expect(score.survived == 0)
    }

    /// Observable selection: a mutant in `a()` is covered only by TargetATests,
    /// so its test run must be narrowed to tests of that bundle.
    @Test("Per-mutant selection picks tests from the covering bundle")
    func selectionFollowsBundle() throws {
        let run = try self.run()
        var checked = 0
        for result in run.report.results where result.outcome != .noCoverage {
            let command = result.evidence?.testCommand.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
                ?? "(no test command) \(result.diagnosis)"
            let mentionsA = command.contains("TargetATests")
            let mentionsB = command.contains("TargetBTests")
            switch name(result) {
            case "a(_:)": #expect(mentionsA && !mentionsB, "a(_:): \(command)")
            case "b(_:)": #expect(mentionsB && !mentionsA, "b(_:): \(command)")
            case "both(_:)": #expect(mentionsA && mentionsB, "both(_:): \(command)")
            default: continue
            }
            checked += 1
        }
        #expect(checked > 0)
    }
}
