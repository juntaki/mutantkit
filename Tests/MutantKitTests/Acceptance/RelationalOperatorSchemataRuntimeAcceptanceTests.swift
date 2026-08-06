import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The same real end-to-end proof `SchemataSwiftPMRuntimeAcceptanceTests`
/// runs for `bool-literal-inversion` (real `swift build`, real linked
/// runtime, two real subprocess runs, a real STARTUP/HIT transcript), but
/// for `RelationalOperatorReplacementSchemataLowerer` — and additionally
/// proving the one property that lowering exists specifically to guarantee:
/// each operand is evaluated **exactly once**, in both the inactive
/// (original-operator) and active (mutant-operator) runs. `isActive`/
/// `readAndCountLHS`/`readAndCountRHS` write their own eval-count line to
/// stdout, checked below.
///
/// This lowerer is deliberately never registered in
/// `SchemataLowererRegistry.builtIn` — invoked directly here, the same way
/// this suite invokes it, never through the production planner/registry
/// path. Off by default, same as every other acceptance suite:
/// `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: relational-operator schemata runtime", .enabled(if: Acceptance.isEnabled))
struct RelationalOperatorSchemataRuntimeAcceptanceTests {
    /// `lhsCount`/`rhsCount` increment on every real read — if the lowering
    /// ever evaluated `lhs`/`rhs` a second time (the exact hazard the
    /// closure-with-local-lets shape exists to avoid), either counter would
    /// read `2`, not `1`, regardless of which branch actually ran.
    private static let runID = RunID()

    /// `lhs()`/`rhs()` are themselves function calls — not eligible
    /// operands under this lowerer's own restriction. The fixture instead
    /// compares two *safe* operands (`x`/`y`, plain identifiers) that are
    /// each assigned from a counting call exactly once, ahead of the
    /// comparison — this is what actually exercises "the lowering itself
    /// never re-evaluates its operand," since the safe operands `x`/`y` are
    /// what the lowering embeds and duplicates into local `let`s.
    private static let realFixtureSource = """
    var lhsCount = 0
    var rhsCount = 0

    // Top-level statements in a `swift-tools-version:6.0` executable
    // target default to `@MainActor` isolation, but a plain top-level
    // `func` does not — a separate `countedLHS()`/`countedRHS()` function
    // mutating these globals would be rejected as a cross-actor mutation.
    // Immediately-invoked top-level closures stay in the same (default
    // main-actor) isolation as the rest of this file.
    let x: Int = { lhsCount += 1; return 3 }()
    let y: Int = { rhsCount += 1; return 5 }()

    if x < y {
        print("ORIGINAL")
    } else {
        print("MUTATED")
    }
    print("lhsCount=\\(lhsCount)")
    print("rhsCount=\\(rhsCount)")

    """

    private func stageSpikePackage() throws -> (directory: URL, token: SchemataSelectorToken) {
        let points = try discover(Self.realFixtureSource, path: "main.swift", using: Operators.relational)
        // The fixture's one `<` comparison yields two real candidates
        // (boundary `<=` and negation `>=`) from the real, unmodified
        // isolated operator — the negation form is selected here since it
        // is guaranteed to flip the branch taken (`3 < 5` is true;
        // `3 >= 5` is false), making ORIGINAL-vs-MUTATED unambiguous from
        // stdout alone.
        let point = try #require(
            points.first { $0.replacementText == ">=" }, "expected a negation (>=) candidate in the fixture"
        )

        let chunk = SchemataChunk(
            chunkID: "relational-spike-chunk", points: [point],
            projectIdentity: "RelationalSchemataRuntimeSpike.xcodeproj",
            target: "RelationalSchemataRuntimeSpike", module: "RelationalSchemataRuntimeSpike", product: "RelationalSchemataRuntimeSpike"
        )
        let program = try RelationalOperatorReplacementSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "main.swift", contents: Self.realFixtureSource)]
        )
        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-relational-schemata-runtime-spike-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/RelationalSchemataRuntimeSpike")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        let dependencyIdentity = Acceptance.packageRoot.lastPathComponent
        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "RelationalSchemataRuntimeSpike",
            platforms: [.macOS(.v14)],
            dependencies: [.package(path: "\(Acceptance.packageRoot.path)")],
            targets: [
                .executableTarget(
                    name: "RelationalSchemataRuntimeSpike",
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

    private func runSpikeExecutable(
        at directory: URL, environment: [String: String]
    ) throws -> (output: String, processID: Int32) {
        let binary = directory.appendingPathComponent(".build/debug/RelationalSchemataRuntimeSpike")
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

    @Test("Inactive: real `<` (ORIGINAL). Active with token: real `>=` (MUTATED). Each operand evaluated once, real evidence recorded.")
    func runtimeActivatesOnlyTheRequestedTokenAndEvaluatesOperandsExactlyOnce() throws {
        let (directory, token) = try stageSpikePackage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try buildSpikePackage(at: directory)

        let unmutated = try runSpikeExecutable(at: directory, environment: [:])
        #expect(unmutated.output.contains("ORIGINAL"), "no requested token must behave exactly like the real, unmutated `<`")
        #expect(!unmutated.output.contains("MUTATED"))
        #expect(unmutated.output.contains("lhsCount=1"), "the left operand must be evaluated exactly once, not zero or twice")
        #expect(unmutated.output.contains("rhsCount=1"), "the right operand must be evaluated exactly once, not zero or twice")

        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }

        let mutated = try runSpikeExecutable(at: directory, environment: [
            SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
            SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
            SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: Self.runID)
        ])
        #expect(mutated.output.contains("MUTATED"), "the requested token must activate the real, embedded `>=` mutant")
        #expect(!mutated.output.contains("ORIGINAL"))
        #expect(mutated.output.contains("lhsCount=1"), "activating the mutant must not change the evaluation count of either operand")
        #expect(mutated.output.contains("rhsCount=1"))

        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
        let startup = try #require(Self.matchingStartup(in: transcript, token: token, runID: Self.runID))
        #expect(startup.processID == mutated.processID, "the PID reported by the real startup event must match the real process")
        let hit = try #require(Self.matchingHit(in: transcript, startup: startup, token: token))
        #expect(hit.token == token, "a real startup event and hit from the real process must report the requested token")
    }

    private static func matchingStartup(
        in transcript: RuntimeTranscript, token: SchemataSelectorToken, runID: RunID
    ) -> RuntimeStartupEvent? {
        transcript.records.compactMap { record -> RuntimeStartupEvent? in
            guard case let .startup(event) = record, event.token == token, event.runID == runID else { return nil }
            return event
        }.first
    }

    private static func matchingHit(
        in transcript: RuntimeTranscript, startup: RuntimeStartupEvent, token: SchemataSelectorToken
    ) -> RuntimeHitEvent? {
        transcript.records.compactMap { record -> RuntimeHitEvent? in
            guard case let .hit(event) = record, event.token == token,
                  event.runID == startup.runID, event.processID == startup.processID
            else { return nil }
            return event
        }.first
    }
}
