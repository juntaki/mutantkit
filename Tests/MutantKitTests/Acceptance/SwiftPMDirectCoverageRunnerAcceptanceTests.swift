@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Real-toolchain proof that the fast-profiler substrate
/// (`SwiftPMTestProductResolver`, `SwiftPMDirectCoverageRunner`,
/// `SwiftPMCoverageExporter`) actually work together end to end against a
/// real `swiftpm-testing-helper` invocation and real LLVM coverage tooling —
/// not just against hand-built fixtures. Component-level (`@testable`),
/// like `XcodePerTestProfilingFailClosedAcceptanceTests`: these types are
/// not yet wired into `measurePerTestCoverage`'s public surface (that is a
/// later integration step), so this suite drives them directly.
///
/// Four widgets, one behavior each, matching the earlier direct-invocation
/// feasibility spike's own criteria: `widgetAPasses`/`widgetBPasses` (valid, disjoint coverage —
/// used to prove no cross-contamination between isolated runs, not merely
/// "each run got its own file path"), `widgetCAlwaysFails` (the serial
/// oracle's own all-or-nothing contract), `widgetDSkipped` (`.disabled`).
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SwiftPM direct coverage runner", .enabled(if: Acceptance.isEnabled))
struct SwiftPMDirectCoverageRunnerAcceptanceTests {
    private static let librarySource = """
    public enum Widgets {
        public static func widgetA() -> Int { 1 }
        public static func widgetB() -> Int { 2 }
        public static func widgetC() -> Int { 3 }
        public static func widgetD() -> Int { 4 }
    }

    """

    private static let testSource = """
    import Testing
    @testable import Widgets

    @Suite("Widgets")
    struct WidgetsTests {
        @Test("widget A passes")
        func widgetAPasses() {
            #expect(Widgets.widgetA() == 1)
        }

        @Test("widget B passes")
        func widgetBPasses() {
            #expect(Widgets.widgetB() == 2)
        }

        @Test("widget C always fails")
        func widgetCAlwaysFails() {
            _ = Widgets.widgetC()
            #expect(Bool(false), "deliberately unconditional failure")
        }

        @Test("widget D always skipped", .disabled("never runs"))
        func widgetDSkipped() {
            #expect(Bool(false), "must never execute")
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-direct-coverage-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/Widgets")
        let testsDirectory = directory.appendingPathComponent("Tests/WidgetsTests")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testsDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "Widgets",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "Widgets"),
                .testTarget(name: "WidgetsTests", dependencies: ["Widgets"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource.utf8).write(to: sourcesDirectory.appendingPathComponent("Widgets.swift"))
        try Data(Self.testSource.utf8).write(to: testsDirectory.appendingPathComponent("WidgetsTests.swift"))
        return directory
    }

    /// Builds once for the whole suite's own tests (coverage-instrumented,
    /// tests built) and resolves the one product every scenario below runs
    /// against.
    private func buildAndResolve() async throws -> (workspace: URL, binary: URL) {
        let workspace = try stagePackage()
        let arguments = ["swift", "build", "--build-tests", "--enable-code-coverage"]
        let result = try await ProcessSupervisor.run(
            executable: ToolPaths.xcrun, arguments: arguments, workingDirectory: workspace, timeoutSeconds: 120
        )
        try #require(result.succeeded, "build failed: \(String(decoding: result.standardError, as: UTF8.self))")

        let productsDirectory = workspace.appendingPathComponent(".build/debug", isDirectory: true)
        let binary = try #require(
            SwiftPMTestProductResolver.resolve(productsDirectory: productsDirectory),
            "expected to resolve exactly one .xctest bundle's binary"
        )
        return (workspace, binary)
    }

    private func lineNumber(containing needle: String) throws -> Int {
        try #require(Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains(needle) }) + 1
    }

    @Test("A valid test's own coverage attributes exactly the line it covers")
    func validTestAttributesItsOwnLine() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let test = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetAPasses()")
        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)

        guard case .succeeded(let outcome) = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: test, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        ) else {
            Issue.record("expected the isolated run of \(test) to succeed")
            return
        }

        guard case .exported(let json) = await SwiftPMCoverageExporter.export(
            profileURL: outcome.profileURL, testBundleBinary: binary, scratchDirectory: scratch
        ) else {
            Issue.record("expected coverage export to succeed")
            return
        }

        let executed = try #require(SourceCoverageReader.parse(json, projectRoot: workspace))
        let widgetALine = try lineNumber(containing: "widgetA()")
        let widgetBLine = try lineNumber(containing: "widgetB()")

        let widgetsFile = "Sources/Widgets/Widgets.swift"
        #expect(executed[widgetsFile]?.contains(widgetALine) == true)
        #expect(executed[widgetsFile]?.contains(widgetBLine) != true)
    }

    @Test("Two sequential isolated runs of disjoint tests produce disjoint coverage -- no contamination")
    func sequentialRunsProduceDisjointCoverage() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)
        let testA = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetAPasses()")
        let testB = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetBPasses()")

        guard case .succeeded(let outcomeA) = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testA, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        ), case .succeeded(let outcomeB) = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testB, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        ) else {
            Issue.record("expected both isolated runs to succeed")
            return
        }

        guard case .exported(let jsonA) = await SwiftPMCoverageExporter.export(
            profileURL: outcomeA.profileURL, testBundleBinary: binary, scratchDirectory: scratch
        ), case .exported(let jsonB) = await SwiftPMCoverageExporter.export(
            profileURL: outcomeB.profileURL, testBundleBinary: binary, scratchDirectory: scratch
        ) else {
            Issue.record("expected both coverage exports to succeed")
            return
        }

        let executedA = try #require(SourceCoverageReader.parse(jsonA, projectRoot: workspace))
        let executedB = try #require(SourceCoverageReader.parse(jsonB, projectRoot: workspace))
        let widgetALine = try lineNumber(containing: "widgetA()")
        let widgetBLine = try lineNumber(containing: "widgetB()")
        let widgetsFile = "Sources/Widgets/Widgets.swift"

        // The actual proof: A's own export covers A's line and not B's;
        // B's own export covers B's line and not A's. Distinct profile
        // paths (already implied by each run succeeding independently)
        // prove nothing about coverage *content* on their own -- this is
        // the check that would catch a shared, leaking, or default-named
        // profile.
        #expect(executedA[widgetsFile]?.contains(widgetALine) == true)
        #expect(executedA[widgetsFile]?.contains(widgetBLine) != true)
        #expect(executedB[widgetsFile]?.contains(widgetBLine) == true)
        #expect(executedB[widgetsFile]?.contains(widgetALine) != true)
    }

    @Test("An impossible filter (a test that does not exist) is unavailable, not a false empty success")
    func impossibleFilterIsUnavailable() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)
        let nonexistent = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/thisTestDoesNotExist()")

        let result = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: nonexistent, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        )
        guard case .unavailable = result else {
            Issue.record("expected .unavailable for a test that does not exist, got \(result)")
            return
        }
    }

    @Test("A test that fails in isolation is unavailable, matching the serial oracle's own all-or-nothing contract")
    func failingTestIsUnavailable() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)
        let testC = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetCAlwaysFails()")

        let result = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testC, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        )
        guard case .unavailable = result else {
            Issue.record("expected .unavailable for a test that fails in isolation, got \(result)")
            return
        }
    }

    @Test("A disabled test is unavailable -- it emits testSkipped, never testStarted/testEnded")
    func disabledTestIsUnavailable() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)
        let testD = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetDSkipped()")

        let result = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testD, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        )
        guard case .unavailable = result else {
            Issue.record("expected .unavailable for a disabled test, got \(result)")
            return
        }
    }
}
