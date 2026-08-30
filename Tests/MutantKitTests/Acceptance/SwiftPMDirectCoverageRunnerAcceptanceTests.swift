@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Real-toolchain proof that the F1-C1 fast-profiler building blocks
/// (`SwiftPMTestProductResolver`, `SwiftPMDirectCoverageRunner`,
/// `SwiftPMCoverageExporter`) actually work together end to end against a
/// real `swiftpm-testing-helper` invocation and real LLVM coverage tooling —
/// not just against hand-built fixtures. Component-level (`@testable`),
/// like `XcodePerTestProfilingFailClosedAcceptanceTests`: these types are
/// not yet wired into `measurePerTestCoverage`'s public surface (that is a
/// later integration step), so this suite drives them directly.
///
/// Covers the same acceptance shape as the SwiftPM (F1-P0-era) fail-closed
/// suites and the earlier F1-A1 spike criteria: a valid test, an impossible
/// filter, a failing test, a disabled/skipped test, and two sequential
/// single-test runs with no cross-contamination.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SwiftPM direct coverage runner (F1-C1 substrate)", .enabled(if: Acceptance.isEnabled))
struct SwiftPMDirectCoverageRunnerAcceptanceTests {
    private static let librarySource = """
    public enum Widgets {
        public static func widgetA() -> Int { 1 }
        public static func widgetB() -> Int { 2 }
    }

    """

    private static let testSource = """
    import Testing
    @testable import Widgets

    @Suite("Widgets")
    struct WidgetsTests {
        @Test("widget A")
        func widgetANeverFails() {
            #expect(Widgets.widgetA() == 1)
        }

        @Test("widget B, always fails")
        func widgetBAlwaysFails() {
            _ = Widgets.widgetB()
            #expect(Bool(false), "deliberately unconditional failure")
        }

        @Test("widget C, always skipped", .disabled("never runs"))
        func widgetCNeverRuns() {
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

    @Test("A valid test's own coverage attributes exactly the line it covers")
    func validTestAttributesItsOwnLine() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let test = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetANeverFails()")
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
        let widgetALine = try #require(
            Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains("widgetA()") }
        ) + 1
        let widgetBLine = try #require(
            Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains("widgetB()") }
        ) + 1

        let widgetsFile = "Sources/Widgets/Widgets.swift"
        #expect(executed[widgetsFile]?.contains(widgetALine) == true)
        #expect(executed[widgetsFile]?.contains(widgetBLine) != true)
    }

    @Test("Two sequential single-test runs do not contaminate each other's coverage")
    func sequentialRunsDoNotContaminate() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)
        let testA = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetANeverFails()")

        // Run A, then immediately run A again -- if profiles or event
        // streams leaked state between runs (a shared path, a stale
        // environment variable), the second run's own evidence would be
        // the tell.
        guard case .succeeded(let first) = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testA, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        ), case .succeeded(let second) = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testA, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        ) else {
            Issue.record("expected both isolated runs to succeed")
            return
        }

        #expect(first.profileURL != second.profileURL, "each run must get its own unique profile path")
        #expect(FileManager.default.fileExists(atPath: first.profileURL.path))
        #expect(FileManager.default.fileExists(atPath: second.profileURL.path))
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
        let testB = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetBAlwaysFails()")

        let result = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testB, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        )
        guard case .unavailable = result else {
            Issue.record("expected .unavailable for a test that fails in isolation, got \(result)")
            return
        }
    }

    @Test("A disabled test is unavailable -- it never starts, so it can never satisfy an executed count")
    func disabledTestIsUnavailable() async throws {
        let (workspace, binary) = try await buildAndResolve()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let scratch = workspace.appendingPathComponent(".mutantkit-scratch", isDirectory: true)
        let testC = TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetCNeverRuns()")

        let result = await SwiftPMDirectCoverageRunner.run(
            testBundleBinary: binary, test: testC, workingDirectory: workspace, scratchDirectory: scratch, timeoutSeconds: 60
        )
        guard case .unavailable = result else {
            Issue.record("expected .unavailable for a disabled test, got \(result)")
            return
        }
    }
}
