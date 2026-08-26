import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The proof `SchemataSwiftPMRuntimeAcceptanceTests` never provides: that
/// `MutantKitSchemataRuntime` can be linked into a real SwiftPM project
/// *without* that project declaring any dependency on MutantKit at all —
/// no `.package(path:)`, no `MutantKitSchemataRuntime` product usage, no
/// `Package.swift` edit whatsoever. Every other schemata acceptance test
/// stages its own throwaway manifest with the dependency baked directly
/// in; that is not a viable path for a real user's existing project (this
/// tool cannot rewrite someone else's `Package.swift` to add a dependency
/// on MutantKit's own repo). This suite proves the actual mechanism a real
/// integration must use instead: `-Xlinker -L<dir> -Xlinker
/// -lMutantKitSchemataRuntime` appended to the command line, the SwiftPM
/// analogue of the Xcode path's `OTHER_LDFLAGS`/`LIBRARY_SEARCH_PATHS`
/// build-setting overrides (`SchemataXcodeRuntimeAcceptanceTests`) — same
/// "no manifest edit" discipline, proven the same way: a real build
/// against a project that has no idea MutantKit exists.
///
/// Off by default like every other acceptance suite (a real `swift build
/// --build-tests` plus subprocess runs): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SwiftPM linker injection", .enabled(if: Acceptance.isEnabled))
struct SchemataSwiftPMLinkerInjectionAcceptanceTests {
    private static let fixtureSource = """
    func isEnabled() -> Bool {
        true
    }

    if isEnabled() {
        print("ORIGINAL")
    } else {
        print("MUTATED")
    }

    """

    /// Stages a throwaway executable package whose `Package.swift` is
    /// entirely ordinary — no awareness of MutantKit, no path dependency,
    /// nothing a real project wouldn't already have.
    private func stageUnawarePackage() throws -> (directory: URL, token: SchemataSelectorToken) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.fixtureSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "main.swift"
        )
        let point = try #require(points.first, "expected one bool-literal candidate in the fixture")

        let chunk = SchemataChunk(
            chunkID: "linker-injection-chunk", points: [point],
            projectIdentity: "LinkerInjectionSpike.xcodeproj",
            target: "LinkerInjectionSpike", module: "LinkerInjectionSpike", product: "LinkerInjectionSpike"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "main.swift", contents: Self.fixtureSource)]
        )
        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-linker-injection-spike-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/LinkerInjectionSpike")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "LinkerInjectionSpike",
            platforms: [.macOS(.v14)],
            targets: [
                .executableTarget(name: "LinkerInjectionSpike")
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for source in program.loweredSources {
            try Data(source.contents.utf8).write(to: sourcesDirectory.appendingPathComponent(source.relativePath))
        }

        return (directory, token)
    }

    /// Builds with the injected linker flags — the exact mechanism a real
    /// `SchemataBuildable` conformance will use. `--build-tests` even
    /// though this fixture has no test target: the point is proving the
    /// flags survive whatever product `swift build` produces, matching
    /// what a schemata build actually needs (a runnable binary, whether it
    /// is a plain executable here or a real test bundle in production).
    private func buildWithInjectedLinkerFlags(at directory: URL, libraryDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "build"] + SwiftPMLinkerInjector.extraArguments(libraryDirectory: libraryDirectory)
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "swift build with injected linker flags failed:\n\(output)")
    }

    private func runSpikeExecutable(
        at directory: URL, environment: [String: String]
    ) throws -> (output: String, processID: Int32) {
        let binary = directory.appendingPathComponent(".build/debug/LinkerInjectionSpike")
        let process = Process()
        process.executableURL = binary
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { mergedEnvironment[key] = value }
        process.environment = mergedEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let processID = process.processIdentifier
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (output, processID)
    }

    private static let runID = RunID()

    /// The one real STARTUP/HIT pair this run's own token/runID produced —
    /// a direct, test-only filter over the raw transcript, not a call to
    /// any production API: deciding which candidate is real is
    /// `MutationVerdictVerifier.verifySchemataChain`'s job alone in
    /// production (ADR-0006 Stage 2).
    private static func matchingStartup(in transcript: RuntimeTranscript, token: SchemataSelectorToken, runID: RunID) -> RuntimeStartupEvent? {
        transcript.records.compactMap { record -> RuntimeStartupEvent? in
            guard case let .startup(event) = record, event.token == token, event.runID == runID else { return nil }
            return event
        }.first
    }

    private static func matchingHit(in transcript: RuntimeTranscript, startup: RuntimeStartupEvent, token: SchemataSelectorToken) -> RuntimeHitEvent? {
        transcript.records.compactMap { record -> RuntimeHitEvent? in
            guard case let .hit(event) = record, event.token == token, event.runID == startup.runID, event.processID == startup.processID else {
                return nil
            }
            return event
        }.first
    }

    @Test("A real SwiftPM project links MutantKitSchemataRuntime via linker flags alone, with no Package.swift changes")
    func linksAndActivatesWithNoManifestChange() throws {
        let (directory, token) = try stageUnawarePackage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let located = try SchemataRuntimeLibraryLocator.locate(for: .macOS)
        try buildWithInjectedLinkerFlags(at: directory, libraryDirectory: located.libraryDirectory)

        let unmutated = try runSpikeExecutable(at: directory, environment: [:])
        #expect(unmutated.output.contains("ORIGINAL"), "no requested token must behave exactly like the original program")
        #expect(!unmutated.output.contains("MUTATED"))

        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }

        let mutated = try runSpikeExecutable(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
            SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
            SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: Self.runID)
        ])
        #expect(mutated.output.contains("MUTATED"), "the requested token must activate the embedded mutation")
        #expect(!mutated.output.contains("ORIGINAL"))

        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
        let startup = try #require(Self.matchingStartup(in: transcript, token: token, runID: Self.runID))
        #expect(startup.processID == mutated.processID)
        let hit = try #require(Self.matchingHit(in: transcript, startup: startup, token: token))
        #expect(hit.token == token, "linking via flags alone must produce exactly as strong a hit as a declared dependency")
    }

    // MARK: - Test-bundle link step (the shape Stage 2's orchestration actually needs)

    private static let libraryFixtureSource = """
    public func isEnabled() -> Bool {
        true
    }

    """

    private static let testFixtureSource = """
    import XCTest
    import LinkerInjectionLib

    final class LinkerInjectionLibTests: XCTestCase {
        func testIsEnabled() {
            XCTAssertTrue(isEnabled())
        }
    }

    """

    /// The real compilation unit `stageUnawareLibraryWithTests`'s `chunk`/
    /// `Widget.swift` lowers to — see `compilationUnitID`'s own doc comment
    /// above for why this is computed the same way, not asserted.
    private static let libraryCompilationUnitID = CompilationUnitID.derive(
        projectIdentity: "LinkerInjectionLib.xcodeproj", target: "LinkerInjectionLib", module: "LinkerInjectionLib",
        sourcePath: "Widget.swift", lowererID: BoolLiteralSchemataLowerer.lowererID,
        lowererVersion: BoolLiteralSchemataLowerer.lowererVersion
    )

    /// A plain executable's link step and an XCTest bundle's are not
    /// guaranteed to be the same step in SwiftPM's build graph — this
    /// fixture has a library target (carrying the lowered mutation) plus a
    /// real test target, so the assertion below is actually exercising the
    /// bundle link, not assuming it behaves like the executable case above.
    private func stageUnawareLibraryWithTests() throws -> (directory: URL, token: SchemataSelectorToken) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.libraryFixtureSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift"
        )
        let point = try #require(points.first, "expected one bool-literal candidate in the fixture")

        let chunk = SchemataChunk(
            chunkID: "linker-injection-lib-chunk", points: [point],
            projectIdentity: "LinkerInjectionLib.xcodeproj",
            target: "LinkerInjectionLib", module: "LinkerInjectionLib", product: "LinkerInjectionLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "Widget.swift", contents: Self.libraryFixtureSource)]
        )
        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-linker-injection-lib-spike-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/LinkerInjectionLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/LinkerInjectionLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "LinkerInjectionLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "LinkerInjectionLib"),
                .testTarget(name: "LinkerInjectionLibTests", dependencies: ["LinkerInjectionLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for source in program.loweredSources {
            try Data(source.contents.utf8).write(to: librarySourcesDirectory.appendingPathComponent(source.relativePath))
        }
        try Data(Self.testFixtureSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("LinkerInjectionLibTests.swift"))

        return (directory, token)
    }

    /// Builds the test bundle (`--build-tests`) with the injected linker
    /// flags — this is the step whose link behavior Stage 2's orchestration
    /// actually depends on, not the plain-executable case above.
    private func buildTestsWithInjectedLinkerFlags(at directory: URL, libraryDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "build", "--build-tests"] +
            SwiftPMLinkerInjector.extraArguments(libraryDirectory: libraryDirectory)
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "swift build --build-tests with injected linker flags failed:\n\(output)")
    }

    /// Runs the already-built test bundle via `swift test --skip-build`,
    /// with `environment` merged over the launching process's own — the
    /// same invocation shape `SwiftPackageMacOSAdapter.runMutant` already
    /// uses for isolated mode, just with schemata env vars added. Does not
    /// try to capture the real xctest-process PID from this call: per this
    /// session's own established finding, `swift test` launches
    /// `swiftpm-testing-helper` as a descendant that leaves this process's
    /// group, so the PID this method could report would not be the PID
    /// that actually ran the mutated code — the real PID has to come from
    /// the runtime's own startup event, matched below.
    private func runTestBundle(
        at directory: URL, environment: [String: String]
    ) throws -> (testsPassed: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "test", "--skip-build"]
        process.currentDirectoryURL = directory
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { mergedEnvironment[key] = value }
        process.environment = mergedEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus == 0, output)
    }

    @Test("A real XCTest bundle links MutantKitSchemataRuntime via linker flags on --build-tests, with no Package.swift changes")
    func testBundleLinksAndActivatesWithNoManifestChange() throws {
        let (directory, token) = try stageUnawareLibraryWithTests()
        defer { try? FileManager.default.removeItem(at: directory) }

        let located = try SchemataRuntimeLibraryLocator.locate(for: .macOS)
        try buildTestsWithInjectedLinkerFlags(at: directory, libraryDirectory: located.libraryDirectory)

        let unmutated = try runTestBundle(at: directory, environment: [:])
        #expect(unmutated.testsPassed, "no requested token must behave exactly like the original program:\n\(unmutated.output)")

        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }
        let runID = RunID()

        let mutated = try runTestBundle(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
            SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
            SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
        ])
        #expect(!mutated.testsPassed, "the requested token must activate the embedded mutation and flip the test's result:\n\(mutated.output)")

        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
        let startup = try #require(Self.matchingStartup(in: transcript, token: token, runID: runID))
        #expect(startup.compilationUnitID == Self.libraryCompilationUnitID)
        let hit = try #require(
            Self.matchingHit(in: transcript, startup: startup, token: token),
            "a real xctest process, whose PID this host never predicted, must still leave a startup event and a hit"
        )
        #expect(hit.compilationUnitID == Self.libraryCompilationUnitID)
    }
}
