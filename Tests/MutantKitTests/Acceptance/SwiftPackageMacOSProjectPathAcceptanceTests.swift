import Foundation
import MutationModel
import Testing

/// Regression for #77, through the real CLI: `project.path` was honored by
/// plan-time discovery but ignored by the real `swift build`/`swift test`
/// invocations, which ran at the sandbox root — where no `Package.swift`
/// exists — instead of joining `project.path` onto it. The bug was a wiring
/// bug (plan right, sandbox build wrong), so this drives plan → sandbox →
/// adapter → build/test → verdict end to end rather than assembling a runner.
///
/// Stages the shape that needs `project.path` in the first place: an outer
/// directory holding two sibling packages, one depending on the other via
/// `.package(path:)`. The sibling is only reachable if the sandbox clones the
/// outer directory and builds the inner package at its resolved location.
@Suite(
    "Acceptance: Swift package project.path with a local sibling dependency",
    .enabled(if: Acceptance.isEnabled),
    .subprocessExclusive
)
struct SwiftPackageMacOSProjectPathAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
      path: Package
    sources:
      include: [Package/Sources/**]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 1
    reports: [console, json]
    """

    private static let siblingManifest = """
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "PathScopeFixtureSibling",
        platforms: [.macOS(.v14)],
        products: [.library(name: "PathScopeFixtureSibling", targets: ["PathScopeFixtureSibling"])],
        targets: [.target(name: "PathScopeFixtureSibling")]
    )
    """

    private static let packageManifest = """
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
        name: "PathScopeFixtureLib",
        platforms: [.macOS(.v14)],
        dependencies: [.package(path: "../Sibling")],
        targets: [
            .target(
                name: "PathScopeFixtureLib",
                dependencies: [.product(name: "PathScopeFixtureSibling", package: "Sibling")]
            ),
            .testTarget(name: "PathScopeFixtureLibTests", dependencies: ["PathScopeFixtureLib"])
        ]
    )
    """

    private static let librarySource = """
    import PathScopeFixtureSibling

    public func shouldPass() -> Bool {
        siblingIsTrue() && true
    }

    """

    private static let testSource = """
    import XCTest
    import PathScopeFixtureLib

    final class PathScopeFixtureLibTests: XCTestCase {
        func testShouldPass() {
            XCTAssertTrue(shouldPass())
        }
    }

    """

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Outer directory (the CLI's working directory) holding `Package/` — the
    /// package under test, at `project.path` — and `Sibling/`, which it
    /// depends on.
    private static func stage() throws -> URL {
        let outer = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-acceptance-ProjectPath-\(UUID().uuidString)")
        try write(configuration, to: outer.appendingPathComponent("mutantkit.yml"))
        try write(siblingManifest, to: outer.appendingPathComponent("Sibling/Package.swift"))
        try write(
            "public func siblingIsTrue() -> Bool { true }\n",
            to: outer.appendingPathComponent("Sibling/Sources/PathScopeFixtureSibling/Sibling.swift")
        )
        try write(packageManifest, to: outer.appendingPathComponent("Package/Package.swift"))
        try write(
            librarySource,
            to: outer.appendingPathComponent("Package/Sources/PathScopeFixtureLib/Widget.swift")
        )
        try write(
            testSource,
            to: outer.appendingPathComponent("Package/Tests/PathScopeFixtureLibTests/PathScopeFixtureLibTests.swift")
        )
        return outer
    }

    /// One run, shared by every assertion about it — see
    /// `SwiftPackageMacOSAcceptanceTests.sharedRun` for why.
    private static let sharedRun = Result<AcceptanceRun, any Error> {
        let directory = try stage()

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

    @Test("The package at project.path builds and tests in the sandbox, so its mutants get real outcomes")
    func mutantsGetRealOutcomes() throws {
        let run = try Self.sharedRun.get()

        #expect(run.report.baseline.passed, "\(run.baselineEvidence)\n\(run.runOutput)")
        #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")
        #expect(!run.report.results.isEmpty, "plan found candidates but the run produced no results:\n\(run.runOutput)")

        let infrastructureFailures = run.report.results.filter { $0.outcome == .infrastructureFailure }
        #expect(
            infrastructureFailures.isEmpty,
            "building at the unscoped sandbox root is the bug: \(infrastructureFailures.map(\.diagnosis))"
        )
        #expect(!run.report.results.contains { $0.diagnosis.contains("no product hash") })
        #expect(
            run.report.results.contains { $0.outcome == .killedByAssertion },
            "inverting the `true` literal must fail testShouldPass: \(run.report.results.map(\.outcome))"
        )
    }
}
