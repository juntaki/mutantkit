@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Real-toolchain, end-to-end proof that the fast per-test coverage path
/// (`SwiftPackageMacOSAdapter.measurePerTestCoverageFast`) is wired
/// correctly into the public `measurePerTestCoverage`, and is safe: its own
/// map must never disagree with the serial reference profiler's, a mixed
/// XCTest + Swift Testing package must fall back to the serial path
/// entirely rather than attempt a partial speedup, and the fast path must
/// never shell out to the `swift test` frontend itself.
///
/// Drives both paths through the one public `measurePerTestCoverage` entry
/// point real callers use (`MUTANTKIT_DISABLE_FAST_PROFILING=1` forces the
/// serial path for the parity comparison) — not private implementation
/// details, the exact decision `MutationRunner` would make.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: fast per-test coverage path integration", .enabled(if: Acceptance.isEnabled), .serialized)
struct SwiftPMFastProfilingIntegrationAcceptanceTests {
    private static let librarySource = """
    public enum Widgets {
        public static func widgetA() -> Int { 1 }
        public static func widgetB() -> Int { 2 }
        public static func widgetC() -> Int { 3 }
    }

    """

    private static let swiftTestingOnlySource = """
    import Testing
    @testable import Widgets

    @Suite("Widgets")
    struct WidgetsTests {
        @Test func widgetA() { #expect(Widgets.widgetA() == 1) }
        @Test func widgetB() { #expect(Widgets.widgetB() == 2) }
        @Test func widgetC() { #expect(Widgets.widgetC() == 3) }
    }

    """

    private static let mixedFrameworkSource = """
    import Testing
    import XCTest
    @testable import Widgets

    @Suite("Widgets")
    struct WidgetsTests {
        @Test func widgetA() { #expect(Widgets.widgetA() == 1) }
        @Test func widgetB() { #expect(Widgets.widgetB() == 2) }
    }

    final class WidgetsXCTests: XCTestCase {
        func testWidgetC() { XCTAssertEqual(Widgets.widgetC(), 3) }
    }

    """

    private func stagePackage(testSource: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-fast-integration-\(UUID().uuidString)")
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
        try Data(testSource.utf8).write(to: testsDirectory.appendingPathComponent("WidgetsTests.swift"))
        return directory
    }

    private func measure(in workspace: URL, disableFastPath: Bool) async throws -> PerTestCoverageMap {
        if disableFastPath {
            setenv("MUTANTKIT_DISABLE_FAST_PROFILING", "1", 1)
        }
        defer { if disableFastPath { unsetenv("MUTANTKIT_DISABLE_FAST_PROFILING") } }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)
        return try #require(
            await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120),
            "expected a non-empty per-test coverage map (disableFastPath: \(disableFastPath))"
        )
    }

    @Test("A pure Swift Testing package: the fast path's own map exactly matches the serial oracle's")
    func fastMapMatchesSerialMapExactly() async throws {
        let workspace = try stagePackage(testSource: Self.swiftTestingOnlySource)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fastMap = try await measure(in: workspace, disableFastPath: false)
        #expect(fastMap.source == "swiftpm-direct-per-test", "expected this run to actually take the fast path, not silently fall back")

        let serialMap = try await measure(in: workspace, disableFastPath: true)
        #expect(serialMap.source == "swiftpm-codecov-per-test")

        #expect(fastMap.coveringTests == serialMap.coveringTests)
    }

    @Test("A mixed XCTest + Swift Testing package falls back to the serial path entirely, and is still correct")
    func mixedFrameworkPackageFallsBackAndIsCorrect() async throws {
        let workspace = try stagePackage(testSource: Self.mixedFrameworkSource)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let map = try await measure(in: workspace, disableFastPath: false)
        #expect(map.source == "swiftpm-codecov-per-test", "a mixed package must fall back to serial, not attempt a partial fast run")

        let widgetALine = try #require(
            Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains("widgetA()") }
        ) + 1
        let widgetCLine = try #require(
            Self.librarySource.components(separatedBy: "\n").firstIndex { $0.contains("widgetC()") }
        ) + 1
        let widgetsFile = "Sources/Widgets/Widgets.swift"

        let widgetATests = try #require(map.testsCovering(file: widgetsFile, line: widgetALine))
        let widgetCTests = try #require(map.testsCovering(file: widgetsFile, line: widgetCLine))
        #expect(widgetATests.contains { $0.qualifiedName.contains("widgetA") })
        #expect(widgetCTests.contains { $0.qualifiedName == "WidgetsXCTests/testWidgetC" })
    }

    @Test("The fast path never shells out to the swift test frontend -- structural proof, not an inferred claim")
    func fastPathNeverInvokesSwiftTestFrontend() async throws {
        let workspace = try stagePackage(testSource: Self.swiftTestingOnlySource)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)

        actor InvocationRecorder {
            private(set) var arguments: [[String]] = []
            func record(_ args: [String]) { arguments.append(args) }
        }
        let recorder = InvocationRecorder()
        let spy: ProcessRunner = { executable, arguments, workingDirectory, timeoutSeconds in
            await recorder.record(arguments)
            return try await ProcessSupervisor.run(
                executable: executable, arguments: arguments, workingDirectory: workingDirectory, timeoutSeconds: timeoutSeconds
            )
        }

        let attempt = await adapter.measurePerTestCoverageFast(artifact: artifact, in: workspace, timeoutSeconds: 120, processRunner: spy)
        guard case .complete = attempt else {
            Issue.record("expected the fast path to succeed for a pure Swift Testing package, got \(attempt)")
            return
        }

        let allArguments = await recorder.arguments
        #expect(!allArguments.isEmpty, "expected the spy to have recorded at least the helper/llvm-profdata/llvm-cov invocations")
        // The actual structural proof: not one recorded invocation is a
        // `swift test` frontend call. Every real invocation this spy sees
        // is either `xcrun xcode-select -p`, `xcrun llvm-profdata ...`,
        // `xcrun llvm-cov ...`, or the direct `swiftpm-testing-helper`
        // binary itself -- none of which pass "test" as a bare argument
        // the way `xcrun swift test ...`/`xcrun swift test list` do.
        for arguments in allArguments {
            #expect(!arguments.contains("test"), "the fast path invoked something that looks like a swift test frontend call: \(arguments)")
        }
    }
}
