import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Proves `XcodeBuildAdapter`'s own `SchemataBuildable`/`SchemataTestable`/
/// `resolveSchemataBuildReceipt` conformance directly — not the hand-rolled
/// `xcodebuild`/`.xctestrun` calls `SchemataXcodeRuntimeAcceptanceTests`
/// uses to prove the injection *mechanism* in isolation. This is the first
/// point the actual adapter methods run for real against a generated Xcode
/// project, mirroring what `SwiftPackageMacOSSchemataAdapterAcceptanceTests`
/// already proves for the SwiftPM adapter.
///
/// A macOS unit test target, not iOS Simulator, on the same reasoning
/// `SchemataXcodeRuntimeAcceptanceTests` already documents: it isolates the
/// adapter-conformance question from simulator-specific concerns.
///
/// Off by default like every other acceptance suite (`xcodegen generate`
/// plus real `xcodebuild` invocations): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: XcodeBuildAdapter schemata conformance", .enabled(if: Acceptance.isEnabled))
struct XcodeSchemataAdapterAcceptanceTests {
    private static let librarySource = """
    public func isEnabled() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import AdapterConformanceXcodeLib

    final class AdapterConformanceXcodeLibTests: XCTestCase {
        func testIsEnabled() {
            XCTAssertTrue(isEnabled())
        }
    }

    """

    private struct StagedProject {
        let directory: URL
        let program: SchemataProgram
        let point: MutationPoint
        let token: SchemataSelectorToken
    }

    private func stageProject() throws -> StagedProject {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Sources/Widget.swift"
        )
        let point = try #require(points.first, "expected one bool-literal candidate in the fixture")

        let chunk = SchemataChunk(
            chunkID: "xcode-adapter-conformance-chunk", points: [point],
            projectIdentity: "AdapterConformanceXcodeLib.xcodeproj",
            target: "AdapterConformanceXcodeLib", module: "AdapterConformanceXcodeLib", product: "AdapterConformanceXcodeLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "Sources/Widget.swift", contents: Self.librarySource)]
        )
        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xcode-adapter-conformance-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources")
        let testSourcesDirectory = directory.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let projectManifest = """
        name: AdapterConformanceXcodeLib
        options:
          bundleIdPrefix: dev.mutantkit.spike
        targets:
          AdapterConformanceXcodeLib:
            type: framework
            platform: macOS
            sources: [Sources]
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
          AdapterConformanceXcodeLibTests:
            type: bundle.unit-test
            platform: macOS
            sources: [Tests]
            dependencies:
              - target: AdapterConformanceXcodeLib
                embed: true
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
        schemes:
          AdapterConformanceXcodeLib:
            build:
              targets:
                AdapterConformanceXcodeLib: all
                AdapterConformanceXcodeLibTests: [test]
            test:
              targets: [AdapterConformanceXcodeLibTests]
        """
        try Data(projectManifest.utf8).write(to: directory.appendingPathComponent("project.yml"))
        // Placeholder content — `buildSchemataChunk` itself overwrites this
        // with the real lowered source; proving the adapter does the write,
        // not test setup on its behalf (same discipline
        // `SwiftPackageMacOSSchemataAdapterAcceptanceTests` uses).
        let placeholder = "public func isEnabled() -> Bool { false }\n"
        try Data(placeholder.utf8).write(to: librarySourcesDirectory.appendingPathComponent("Widget.swift"))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("AdapterConformanceXcodeLibTests.swift"))

        try runXcodegen(in: directory)

        return StagedProject(directory: directory, program: program, point: point, token: token)
    }

    private func runXcodegen(in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcodegen", "generate"]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "xcodegen generate failed:\n\(output)")
    }

    private func makeAdapter(projectRoot: URL) -> XcodeBuildAdapter {
        XcodeBuildAdapter(configuration: Configuration(), kind: .xcodeProject, projectFile: nil, projectRoot: projectRoot)
    }

    @Test("buildSchemataChunk writes lowered sources and links the runtime; runSchemataToken activates the requested token")
    func adapterConformanceMethodsWorkEndToEnd() async throws {
        let staged = try stageProject()
        defer { try? FileManager.default.removeItem(at: staged.directory) }

        let adapter = makeAdapter(projectRoot: staged.directory)
        let artifact = try await adapter.buildSchemataChunk(loweredSources: staged.program.loweredSources, in: staged.directory)
        #expect(artifact.productHash != nil, "a real build must produce a hashable product")
        #expect(artifact.xctestrunPath != nil, "build-for-testing must produce an .xctestrun")

        let unmutated = try await adapter.runSchemataToken(artifact, in: staged.directory, timeoutSeconds: 120, environment: [:])
        #expect(unmutated.status == .passed, "no requested token must behave exactly like the original program: \(unmutated.diagnosis)")

        let runID = RunID()
        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }

        let mutated = try await adapter.runSchemataToken(
            artifact, in: staged.directory, timeoutSeconds: 120,
            environment: [
                SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: staged.token),
                SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
                SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
            ]
        )
        #expect(mutated.status == .failed, "the requested token must activate the embedded mutation and flip the test's result: \(mutated.diagnosis)")

        // ADR-0006 Finding 2/4's build-time half: a real per-image UUID,
        // extracted from the actual built bundle via the target's own real
        // build settings, not a placeholder or a name-matched guess.
        let entry = try #require(staged.program.entries.first)
        let lowererID = try #require(entry.lowererID)
        let lowererVersion = try #require(entry.lowererVersion)
        let sourceEmbeddingIDString = try #require(entry.sourceEmbeddingID)
        let sourceEmbeddingID = try #require(SHA256Digest(rawValue: sourceEmbeddingIDString))
        let buildTarget = BuildTargetIdentity(
            projectIdentity: entry.projectIdentity, targetName: entry.target, moduleName: entry.module
        )
        let compilationUnitID = CompilationUnitID.derive(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
            sourcePath: "Sources/Widget.swift", lowererID: lowererID, lowererVersion: lowererVersion
        )

        let request = SchemataCompilationUnitTargetRequest(
            compilationUnitID: compilationUnitID, sourceEmbeddingID: sourceEmbeddingID, buildTarget: buildTarget
        )
        let receiptContext = SchemataBuildReceiptContext(
            planID: "xcode-adapter-conformance-plan", workUnitID: "xcode-adapter-conformance-wu", chunkID: staged.program.chunkID,
            toolchainHash: SHA256Digest.of("toolchain"), buildArgumentsHash: SHA256Digest.of("args")
        )
        let receipt = try await adapter.resolveSchemataBuildReceipt(
            for: [request], artifact: artifact, in: staged.directory, context: receiptContext
        )
        #expect(!receipt.images.isEmpty, "a successful build-for-testing must produce at least one inspectable image")
        for image in receipt.images {
            #expect(!image.slices.isEmpty)
        }

        // ADR-0006 Stage 2: the real chain proof end to end — a real build
        // receipt plus a real transcript, fed straight into the same
        // verifier production uses, not a hand-rolled cross-check.
        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
        let observation = SchemataExecutionObservation(
            expectation: SchemataRunExpectation(
                mutationID: staged.point.id, compilationUnitID: compilationUnitID,
                sourceEmbeddingID: sourceEmbeddingID, selectorToken: staged.token, runID: runID
            ),
            buildReceipt: receipt, transcript: transcript
        )
        let ref = PlannedMutationRef.forPoint(
            staged.point, planID: "xcode-adapter-conformance-plan", workUnitID: "xcode-adapter-conformance-wu"
        )
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(MutationEvidence(
                sourceBeforeHash: SHA256Digest.of("before").rawValue, sourceAfterHash: SHA256Digest.of("after").rawValue,
                sourceDiff: "--- a\n+++ b\n", buildProductHash: artifact.productHash, applicationEvidence: .schemata(observation)
            )),
            build: BuildObservation(outcome: .succeeded(buildProductHash: artifact.productHash, command: nil)),
            test: SingleTestObservation(run: mutated, applicationEvidence: .schemata(observation))
        )
        let record = MutationVerdictVerifier.verify(observations, policy: .permissive)
        #expect(
            record.outcome == .killedByAssertion,
            "a real build receipt and a real transcript must verify the whole chain and credit the real failing run: \(record.outcome)"
        )
    }

    @Test("buildSchemataChunk refuses a lowered source whose relative path resolves outside the workspace")
    func buildSchemataChunkRejectsPathTraversal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xcode-adapter-conformance-traversal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = makeAdapter(projectRoot: directory)
        let malicious = SchemataSourceFile(relativePath: "../../etc/mutantkit-should-not-exist", contents: "nope")

        await #expect(throws: SchemataWriteError.self) {
            _ = try await adapter.buildSchemataChunk(loweredSources: [malicious], in: directory)
        }
    }
}
