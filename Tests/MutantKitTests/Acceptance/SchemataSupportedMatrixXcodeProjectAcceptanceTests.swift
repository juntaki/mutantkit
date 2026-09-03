import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The supported-matrix acceptance suite for an `.xcodeproj` built
/// against a real iOS-Simulator destination — see
/// `SchemataSupportedMatrixSwiftPMMacOSAcceptanceTests`'s own doc comment
/// for why `Fixtures/SchemataMatrixXcodeProject` is fully covered
/// (every candidate killed) rather than reusing `Fixtures/XcodeProject`,
/// which deliberately leaves some candidates uncovered.
///
/// Beyond the shared "zero fallback" bar every matrix row must clear, this
/// suite also proves the iOS-Simulator-specific evidence chain: a real
/// STARTUP event, a real HIT event, and that the schemata build receipt's
/// own image UUID matches the runtime's own reported UUID — the same
/// proof `MutationVerdictVerifier.verifySchemataChain` requires in
/// production before it will ever trust a schemata verdict.
@Suite("Schemata supported matrix: Xcode project + iOS Simulator", .enabled(if: Acceptance.simulatorEnabled))
struct SchemataSupportedMatrixXcodeProjectAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: MatrixWidget
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [MatrixWidgetTests]
        operators:
          profile: default
        execution:
          strategy: schemata
          workers: 1
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SchemataMatrixXcodeProject", configuration: try configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Xcode project + iOS Simulator: fully covered fixture activates schemata for every candidate, zero fallback")
    func fullyActivatesNoFallback() throws {
        let run = try self.run()
        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "the baseline must reflect a genuinely passing suite")

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.degradationReason == nil, "a whole-run degradation means schemata never really activated")
        #expect(strategy.effectiveCount == integrity.planned, "every planned mutation must go through the real schemata backend")
        #expect(
            strategy.fallbackCount == 0,
            "this fixture is fully covered on purpose — any fallback here is a real gap, not expected uncoverage"
        )
        #expect((strategy.fallbackReasonCounts ?? [:]).isEmpty)
        #expect((strategy.plannerFallbackReasonCounts ?? [:]).isEmpty)

        let operationalIssueKinds = Set(run.report.operationalIssues.map(\.kind))
        #expect(!operationalIssueKinds.contains(.schemataChunkBuildFailed))
        #expect(!operationalIssueKinds.contains(.schemataChunkReceiptUnavailable))
    }

    @Test("The bundled/override iOS-Simulator archive this run actually linked resolves with the expected provenance")
    func runtimeProvenanceIsOverride() throws {
        let located = try SchemataRuntimeLibraryLocator.locate(for: .iOSSimulator)
        #expect(located.provenance == .override)
    }

    // MARK: - Direct STARTUP/HIT/receipt-UUID evidence (iOS Simulator)

    /// Everything above proves this indirectly (a schemata verdict can only
    /// ever be trusted, never fall back, if `MutationVerdictVerifier
    /// .verifySchemataChain` found a matching receipt image UUID for a real
    /// STARTUP/HIT pair — `zero fallback` above already implies this held
    /// for every candidate). This test proves it *directly*, against a real
    /// iOS-Simulator destination specifically: `XcodeSchemataAdapterAcceptanceTests`
    /// already does this for macOS; nothing did it for iOS Simulator before
    /// this suite.
    private static let evidenceLibrarySource = "public func isEnabled() -> Bool {\n    true\n}\n"

    private struct StagedEvidenceProject {
        let directory: URL
        let program: SchemataProgram
        let entry: SchemataPlanEntry
        let token: SchemataSelectorToken
    }

    private func stageEvidenceProject() throws -> StagedEvidenceProject {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.evidenceLibrarySource,
            operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Sources/Widget.swift"
        )
        let point = try #require(points.first, "expected one bool-literal candidate in the fixture")

        let chunk = SchemataChunk(
            chunkID: "matrix-ios-simulator-evidence-chunk", points: [point],
            projectIdentity: "MatrixEvidenceLib.xcodeproj",
            target: "MatrixEvidenceLib", module: "MatrixEvidenceLib", product: "MatrixEvidenceLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "Sources/Widget.swift", contents: Self.evidenceLibrarySource)]
        )
        let entry = try #require(program.entries.first)
        let token = try #require(entry.selectorToken)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-matrix-ios-simulator-evidence-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources")
        let testSourcesDirectory = directory.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let projectManifest = """
        name: MatrixEvidenceLib
        options:
          bundleIdPrefix: dev.mutantkit.matrix.evidence
        targets:
          MatrixEvidenceLib:
            type: framework
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Sources]
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
          MatrixEvidenceLibTests:
            type: bundle.unit-test
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Tests]
            dependencies:
              - target: MatrixEvidenceLib
                embed: true
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
        schemes:
          MatrixEvidenceLib:
            build:
              targets:
                MatrixEvidenceLib: all
                MatrixEvidenceLibTests: [test]
            test:
              targets: [MatrixEvidenceLibTests]
        """
        try Data(projectManifest.utf8).write(to: directory.appendingPathComponent("project.yml"))
        let placeholder = "public func isEnabled() -> Bool { false }\n"
        try Data(placeholder.utf8).write(to: librarySourcesDirectory.appendingPathComponent("Widget.swift"))
        try Data("""
        import XCTest
        import MatrixEvidenceLib

        final class MatrixEvidenceLibTests: XCTestCase {
            func testIsEnabled() {
                XCTAssertTrue(isEnabled())
            }
        }
        """.utf8).write(to: testSourcesDirectory.appendingPathComponent("MatrixEvidenceLibTests.swift"))

        let xcodegen = Process()
        xcodegen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        xcodegen.arguments = ["xcodegen", "generate"]
        xcodegen.currentDirectoryURL = directory
        let xcodegenPipe = Pipe()
        xcodegen.standardOutput = xcodegenPipe
        xcodegen.standardError = xcodegenPipe
        try xcodegen.run()
        let xcodegenOutput = String(decoding: xcodegenPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        xcodegen.waitUntilExit()
        #expect(xcodegen.terminationStatus == 0, "xcodegen generate failed:\n\(xcodegenOutput)")

        return StagedEvidenceProject(directory: directory, program: program, entry: entry, token: token)
    }

    @Test("A real iOS-Simulator run produces a genuine STARTUP/HIT pair whose image UUID matches the build receipt's own")
    func startupHitAndReceiptUUIDMatchOnIOSSimulator() async throws {
        let staged = try stageEvidenceProject()
        let directory = staged.directory
        let program = staged.program
        let entry = staged.entry
        let token = staged.token
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.project.kind = .xcodeProject
        configuration.project.destination = try Acceptance.iPhoneDestination()
        let adapter = XcodeBuildAdapter(configuration: configuration, kind: .xcodeProject, projectFile: nil, projectRoot: directory)

        let artifact = try await adapter.buildSchemataChunk(loweredSources: program.loweredSources, in: directory)
        #expect(artifact.productHash != nil, "a real build must produce a hashable product")

        let runID = RunID()
        let transcriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: transcriptPath) }

        let mutated = try await adapter.runSchemataToken(
            artifact, in: directory, timeoutSeconds: 180,
            environment: [
                SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
                SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
                SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
            ],
            selectedTests: nil
        )
        #expect(
            mutated.status == .failed,
            "the requested token must activate the embedded mutation and flip the test's result: \(mutated.diagnosis)"
        )

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
            planID: "matrix-ios-simulator-evidence-plan", workUnitID: "matrix-ios-simulator-evidence-wu",
            chunkID: program.chunkID, toolchainHash: SHA256Digest.of("toolchain"), buildArgumentsHash: SHA256Digest.of("args")
        )
        let receipt = try await adapter.resolveSchemataBuildReceipt(
            for: [request], artifact: artifact, in: directory, context: receiptContext
        )
        let receiptImageUUIDs = Set(receipt.images.flatMap { $0.slices.map(\.imageUUID) })
        #expect(!receiptImageUUIDs.isEmpty, "a successful iOS-Simulator build-for-testing must produce at least one inspectable image")

        // Direct STARTUP/HIT evidence — real, not inferred.
        let transcript = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
        let startup = try #require(transcript.records.compactMap { record -> RuntimeStartupEvent? in
            guard case let .startup(event) = record, event.token == token, event.runID == runID else { return nil }
            return event
        }.first, "a real iOS-Simulator process must produce a STARTUP event")
        let hit = try #require(transcript.records.compactMap { record -> RuntimeHitEvent? in
            guard
                case let .hit(event) = record, event.token == token,
                event.runID == startup.runID, event.processID == startup.processID
            else { return nil }
            return event
        }.first, "and a real HIT from that same process")
        #expect(hit.compilationUnitID == compilationUnitID)

        // The literal ask: receipt UUID == runtime UUID.
        let uuidMatchMessage = "receipt image UUID(s) \(receiptImageUUIDs) must contain STARTUP's own \(startup.imageUUID)"
        #expect(receiptImageUUIDs.contains(startup.imageUUID), "\(uuidMatchMessage)")
    }
}
