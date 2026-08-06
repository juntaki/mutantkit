import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The end-to-end proof S2 exists to provide: a real `swift build` of a real
/// SwiftPM package, linking the real `MutantKitSchemataRuntimeC` (not a
/// compile-only stub — see `BoolLiteralSchemataCompileViabilityAcceptanceTests`
/// for that faster, narrower suite), run as two real subprocesses — one with
/// no requested token (must behave exactly like the original, unmutated
/// program) and one requesting the embedded mutation's own token (must
/// behave like the mutant, and leave a real transcript
/// `SchemataEvidenceCollector.readTranscript` can decode into the raw
/// STARTUP/HIT records `MutationVerdictVerifier.verifySchemataChain` needs).
///
/// This is the mechanism the whole schemata initiative bets on: source
/// generation (S1), a real linkable runtime (this suite), and evidence
/// collection, proven together against one real toolchain invocation rather
/// than assumed from unit-level reasoning about each piece separately.
///
/// Off by default like every other acceptance suite (two real `swift build`
/// + two subprocess runs): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: SwiftPM schemata runtime", .enabled(if: Acceptance.isEnabled))
struct SchemataSwiftPMRuntimeAcceptanceTests {
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

    private static let runID = RunID()

    /// Stages a throwaway executable package with a path dependency on this
    /// repo, its one source file lowered by the real `BoolLiteralSchemataLowerer`
    /// — proving S1's output and S2's runtime together, not S2 in isolation
    /// against a hand-written fixture that might not match what the real
    /// lowerer actually emits.
    private func stageSpikePackage() throws -> (directory: URL, token: SchemataSelectorToken) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.fixtureSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "main.swift"
        )
        let point = try #require(points.first, "expected one bool-literal candidate in the fixture")

        let chunk = SchemataChunk(
            chunkID: "spike-chunk", points: [point],
            projectIdentity: "SchemataRuntimeSpike.xcodeproj",
            target: "SchemataRuntimeSpike", module: "SchemataRuntimeSpike", product: "SchemataRuntimeSpike"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "main.swift", contents: Self.fixtureSource)]
        )
        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-schemata-runtime-spike-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/SchemataRuntimeSpike")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        // A local path dependency's package *identity* (what `package:`
        // below must name) is derived from its checkout directory name,
        // not its manifest's `name:` field — `mutantkit-private` here, even
        // though `Package.swift` declares `name: "MutantKit"`.
        let dependencyIdentity = Acceptance.packageRoot.lastPathComponent
        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "SchemataRuntimeSpike",
            platforms: [.macOS(.v14)],
            dependencies: [.package(path: "\(Acceptance.packageRoot.path)")],
            targets: [
                .executableTarget(
                    name: "SchemataRuntimeSpike",
                    dependencies: [.product(name: "MutantKitSchemataRuntime", package: "\(dependencyIdentity)")]
                )
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for source in program.loweredSources {
            try Data(source.contents.utf8).write(to: sourcesDirectory.appendingPathComponent(source.relativePath))
        }

        return (directory, token)
    }

    private func buildSpikePackage(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "build"]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "swift build failed:\n\(output)")
    }

    /// Runs the built executable once, with `environment` merged over the
    /// launching process's own environment, and returns its stdout and the
    /// PID it actually ran under (needed to bind evidence to *this* run,
    /// not just any process that happened to write to the same evidence
    /// path).
    private func runSpikeExecutable(
        at directory: URL, environment: [String: String]
    ) throws -> (output: String, processID: Int32) {
        let binary = directory.appendingPathComponent(".build/debug/SchemataRuntimeSpike")
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

    @Test("The mutation is inactive with no requested token, active with the embedded token, and leaves provable evidence")
    func runtimeActivatesOnlyTheRequestedToken() throws {
        let (directory, token) = try stageSpikePackage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try buildSpikePackage(at: directory)

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
        #expect(startup.processID == mutated.processID, "the PID reported by the real startup event must match the real process")
        let hit = try #require(Self.matchingHit(in: transcript, startup: startup, token: token))
        #expect(hit.token == token, "a real startup event and hit from the real process must report the requested token")
    }

    /// The one real STARTUP event this run's own token/runID produced — a
    /// direct, test-only filter over the raw transcript, not a call to any
    /// production API: deciding which candidate is real is
    /// `MutationVerdictVerifier.verifySchemataChain`'s job alone in
    /// production (ADR-0006 Stage 2); this suite only needs to confirm the
    /// real runtime actually wrote the record shape that job depends on.
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

    /// A run nonce is meant to be unique per run — this proves the
    /// collector actually enforces that, rather than merely documenting it:
    /// two independent processes append to the identical, shared startup
    /// and evidence files (as if neither were ever cleaned up between
    /// runs), each under its *own* nonce. Collecting evidence for either
    /// run's nonce must only ever credit that run's own lines, never the
    /// other's — even though both wrote to the same files, and even though
    /// nothing here relies on the two processes' real PIDs being distinct
    /// (though they still are, checked below as a sanity property of the
    /// setup, not of the collector itself).
    @Test("A stale startup/evidence file from a different run's nonce is never credited to a fresh run")
    func staleEvidenceFromAnotherRunsNonceIsNotCredited() throws {
        let (directory, token) = try stageSpikePackage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try buildSpikePackage(at: directory)

        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }

        let firstRunID = RunID()
        let secondRunID = RunID()

        let first = try runSpikeExecutable(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
            SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
            SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: firstRunID)
        ])
        #expect(first.output.contains("MUTATED"))

        // A second, independent run reusing the identical transcript path —
        // as if a stale file from an earlier run was never cleaned up. Its
        // own hit is real, but a filter for the *first* run's ID must not
        // pick up the second run's records.
        let second = try runSpikeExecutable(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
            SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
            SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: secondRunID)
        ])
        #expect(second.output.contains("MUTATED"))
        #expect(first.processID != second.processID, "the two runs must be genuinely distinct processes for this to test anything")

        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)

        let startupForFirstRun = try #require(Self.matchingStartup(in: transcript, token: token, runID: firstRunID))
        #expect(startupForFirstRun.processID == first.processID, "the first run's own records still prove its own activation")

        let startupForSecondRun = try #require(Self.matchingStartup(in: transcript, token: token, runID: secondRunID))
        #expect(startupForSecondRun.processID == second.processID, "the second run's own records still prove its own activation too")
    }

    // MARK: - Multi-file chunk

    private static let multiFileMainSource = """
    func isEnabled() -> Bool {
        true
    }

    print(isEnabled() ? "A-ORIGINAL" : "A-MUTATED")
    print(isFeatureFlagged() ? "B-ORIGINAL" : "B-MUTATED")

    """

    private static let multiFileHelperSource = """
    func isFeatureFlagged() -> Bool {
        true
    }

    """

    /// A P0 found by re-review: `BoolLiteralSchemataLowerer` originally
    /// prepended its runtime declaration to *every* touched file — a chunk
    /// spanning more than one file declared `__mutantkitIsActive` more than
    /// once in the same module, an "invalid redeclaration" compile error
    /// that broke the whole chunk's build, not just one mutant. A second
    /// draft fixed that by emitting the declaration into its own generated
    /// file — which a later review found does not work against a real,
    /// pre-existing Xcode project (writing a new file to disk does not add
    /// it to a `.pbxproj`'s Compile Sources phase). The current design
    /// prepends into whichever *existing* file in the chunk sorts first by
    /// path (see `BoolLiteralSchemataLowerer.sharedDeclarationPreamble`), so no new
    /// file is ever created. This proves both properties at once with a
    /// real two-file chunk and a real `swift build`: no redeclaration, and
    /// no new file.
    @Test("A chunk spanning two files compiles, links, and both mutations activate independently")
    func multiFileChunkCompilesLinksAndActivatesIndependently() throws {
        let mainPoints = try CoreOperatorExpansionTestSupport.discover(
            Self.multiFileMainSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "main.swift"
        )
        let helperPoints = try CoreOperatorExpansionTestSupport.discover(
            Self.multiFileHelperSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Helper.swift"
        )
        let mainPoint = try #require(mainPoints.first)
        let helperPoint = try #require(helperPoints.first)

        let chunk = SchemataChunk(
            chunkID: "multi-file-spike-chunk", points: [mainPoint, helperPoint],
            projectIdentity: "SchemataRuntimeSpike.xcodeproj",
            target: "SchemataRuntimeSpike", module: "SchemataRuntimeSpike", product: "SchemataRuntimeSpike"
        )
        let program = try BoolLiteralSchemataLowerer().lower(chunk, sources: [
            SchemataSourceFile(relativePath: "main.swift", contents: Self.multiFileMainSource),
            SchemataSourceFile(relativePath: "Helper.swift", contents: Self.multiFileHelperSource)
        ])

        // No new file is created, and the declaration appears exactly
        // once — in "Helper.swift", the lexicographically-first of the
        // chunk's two existing files.
        #expect(program.loweredSources.count == 2, "no new file — only main.swift and Helper.swift, unchanged in count")
        let declarationCopies = program.loweredSources.filter { $0.contents.contains(BoolLiteralSchemataLowerer.sharedDeclarationPreamble) }
        #expect(declarationCopies.count == 1, "the declaration itself must appear in exactly one file")
        #expect(
            declarationCopies.first?.relativePath == "Helper.swift",
            "the declaration must land in the chunk's lexicographically-first existing file"
        )

        let mainEntry = try #require(program.entries.first { $0.mutationID == mainPoint.id })
        let helperEntry = try #require(program.entries.first { $0.mutationID == helperPoint.id })
        let mainToken = try #require(mainEntry.selectorToken)
        let helperToken = try #require(helperEntry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-schemata-multifile-spike-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/SchemataRuntimeSpike")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dependencyIdentity = Acceptance.packageRoot.lastPathComponent
        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "SchemataRuntimeSpike",
            platforms: [.macOS(.v14)],
            dependencies: [.package(path: "\(Acceptance.packageRoot.path)")],
            targets: [
                .executableTarget(
                    name: "SchemataRuntimeSpike",
                    dependencies: [.product(name: "MutantKitSchemataRuntime", package: "\(dependencyIdentity)")]
                )
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for source in program.loweredSources {
            try Data(source.contents.utf8).write(to: sourcesDirectory.appendingPathComponent(source.relativePath))
        }

        // A real `swift build` — this is exactly where "invalid
        // redeclaration of '__mutantkitIsActive'" would have surfaced
        // before the fix, since it only manifests once the compiler
        // actually sees both files in the same module.
        try buildSpikePackage(at: directory)

        let mainActive = try runSpikeExecutable(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: mainToken)
        ])
        #expect(mainActive.output.contains("A-MUTATED"), "requesting main.swift's token must activate only that mutation")
        #expect(mainActive.output.contains("B-ORIGINAL"), "Helper.swift's mutation must stay inactive")

        let helperActive = try runSpikeExecutable(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: helperToken)
        ])
        #expect(helperActive.output.contains("A-ORIGINAL"), "main.swift's mutation must stay inactive")
        #expect(helperActive.output.contains("B-MUTATED"), "requesting Helper.swift's token must activate only that mutation")
    }
}
