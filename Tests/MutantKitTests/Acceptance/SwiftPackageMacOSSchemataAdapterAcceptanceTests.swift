import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Proves `SwiftPackageMacOSAdapter`'s own `SchemataBuildable`/
/// `SchemataTestable` conformance directly — not just the underlying
/// linker-injection mechanism `SchemataSwiftPMLinkerInjectionAcceptanceTests`
/// already proves by hand-rolling equivalent `Process()` calls. This is the
/// first point the actual adapter methods (`buildSchemataChunk`,
/// `runSchemataToken`) run for real, including the path-safety check
/// (`resolveSchemataWriteURL`) that guards writing lowered sources into the
/// workspace.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SwiftPackageMacOSAdapter schemata conformance", .enabled(if: Acceptance.isEnabled))
struct SwiftPackageMacOSSchemataAdapterAcceptanceTests {
    private static let librarySource = """
    public func isEnabled() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import AdapterConformanceLib

    final class AdapterConformanceLibTests: XCTestCase {
        func testIsEnabled() {
            XCTAssertTrue(isEnabled())
        }
    }

    """

    /// `SchemataSourceFile.relativePath` is project-root-relative — the
    /// same convention `MutationPoint.file`/`WorkspaceManager.resolveSourceURL`
    /// use everywhere else in this codebase — not module-relative. This
    /// fixture's one source file therefore has to be named by its full
    /// path from the sandbox root, matching what `buildSchemataChunk`'s
    /// own write logic (`workspace.appendingPathComponent(relativePath)`)
    /// actually expects.
    private static let libraryRelativePath = "Sources/AdapterConformanceLib/Widget.swift"

    private func stageUnawareLibraryWithTests() throws -> (directory: URL, program: SchemataProgram) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.libraryRelativePath
        )
        let point = try #require(points.first, "expected one bool-literal candidate in the fixture")

        let chunk = SchemataChunk(
            chunkID: "adapter-conformance-chunk", points: [point],
            projectIdentity: "AdapterConformanceLib.xcodeproj",
            target: "AdapterConformanceLib", module: "AdapterConformanceLib", product: "AdapterConformanceLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.libraryRelativePath, contents: Self.librarySource)]
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-adapter-conformance-spike-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/AdapterConformanceLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/AdapterConformanceLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "AdapterConformanceLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "AdapterConformanceLib"),
                .testTarget(name: "AdapterConformanceLibTests", dependencies: ["AdapterConformanceLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        // Deliberately do NOT write the lowered sources here — proving
        // `buildSchemataChunk` itself performs the write, not test setup
        // doing it on its behalf.
        try Data(Self.testFixtureSourceOriginal.utf8).write(to: directory.appendingPathComponent(Self.libraryRelativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("AdapterConformanceLibTests.swift"))

        return (directory, program)
    }

    /// The placeholder content the test target compiles against before
    /// `buildSchemataChunk` overwrites it with the real lowered source —
    /// any valid Swift that defines `isEnabled()` works, since it is never
    /// actually built as-is.
    private static let testFixtureSourceOriginal = "public func isEnabled() -> Bool { false }\n"

    @Test("buildSchemataChunk writes lowered sources and links the runtime; runSchemataToken activates the requested token")
    func adapterConformanceMethodsWorkEndToEnd() async throws {
        let (directory, program) = try stageUnawareLibraryWithTests()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildSchemataChunk(loweredSources: program.loweredSources, in: directory)
        #expect(artifact.productHash != nil, "a real build must produce a hashable product")

        let unmutated = try await adapter.runSchemataToken(
            artifact, in: directory, timeoutSeconds: 60, environment: [:], selectedTests: nil
        )
        #expect(unmutated.status == .passed, "no requested token must behave exactly like the original program: \(unmutated.diagnosis)")

        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }
        let runID = RunID()

        let mutated = try await adapter.runSchemataToken(
            artifact, in: directory, timeoutSeconds: 60,
            environment: [
                SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
                SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
                SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
            ],
            selectedTests: nil
        )
        #expect(mutated.status == .failed, "the requested token must activate the embedded mutation and flip the test's result: \(mutated.diagnosis)")

        // The real compilation unit `stageUnawareLibraryWithTests`'s
        // `chunk`/`Widget.swift` lowers to — computed the same way
        // `SchemataMutationRunner.runEntry` does in production.
        let compilationUnitID = CompilationUnitID.derive(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
            sourcePath: Self.libraryRelativePath, lowererID: entry.lowererID ?? "unknown", lowererVersion: entry.lowererVersion ?? 0
        )
        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
        let startup = try #require(transcript.records.compactMap { record -> RuntimeStartupEvent? in
            guard case let .startup(event) = record, event.token == token, event.runID == runID else { return nil }
            return event
        }.first, "the adapter's own runSchemataToken environment threading must produce a real startup event")
        #expect(startup.compilationUnitID == compilationUnitID)
        let hit = try #require(transcript.records.compactMap { record -> RuntimeHitEvent? in
            guard case let .hit(event) = record, event.token == token, event.runID == startup.runID, event.processID == startup.processID
            else { return nil }
            return event
        }.first, "and a real hit from that same process")
        #expect(hit.compilationUnitID == compilationUnitID)
    }

    @Test("buildSchemataChunk refuses a lowered source whose relative path resolves outside the workspace")
    func buildSchemataChunkRejectsPathTraversal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-adapter-conformance-traversal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let malicious = SchemataSourceFile(relativePath: "../../etc/mutantkit-should-not-exist", contents: "nope")

        await #expect(throws: SchemataWriteError.self) {
            _ = try await adapter.buildSchemataChunk(loweredSources: [malicious], in: directory)
        }
    }

    /// A `..`-style traversal is caught by the *first* prefix check alone
    /// — this proves the *second* one, after resolving symlinks, actually
    /// does something: an intermediate directory component that is itself
    /// a symlink pointing outside the sandbox, which the first check alone
    /// (a pure string comparison on the unresolved path) cannot detect.
    @Test("buildSchemataChunk refuses a lowered source reached through a symlinked intermediate directory")
    func buildSchemataChunkRejectsSymlinkEscape() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-adapter-conformance-symlink-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-adapter-conformance-symlink-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        // "Escape" is a symlink living inside the sandbox that resolves
        // outside it — the lowered source's own relative path never
        // contains ".." at all, only the intermediate directory does.
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Escape"), withDestinationURL: outside
        )

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let malicious = SchemataSourceFile(relativePath: "Escape/mutantkit-should-not-exist", contents: "nope")

        await #expect(throws: SchemataWriteError.self) {
            _ = try await adapter.buildSchemataChunk(loweredSources: [malicious], in: directory)
        }
        #expect(
            !FileManager.default.fileExists(atPath: outside.appendingPathComponent("mutantkit-should-not-exist").path),
            "the write must never have reached outside the sandbox"
        )
    }
}
