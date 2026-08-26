import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0006 Stage 3: the Xcode half of `SchemataConfirmationAcceptanceTests`
/// — proves schemata confirmation end to end against a real
/// `xcodegen`-generated macOS framework + unit-test bundle. Unlike the
/// SwiftPM adapter, `XCResultAdapter` reads a structured `Crash:` field
/// straight out of the `.xcresult` bundle (`XCResultAdapter.TestFailure
/// .isCrash`) rather than inferring a crash from a process-level signal —
/// so, unlike the SwiftPM suite (which had to fall back to an
/// assertion-kill confirmation because `swift test`'s own coordinator
/// process never itself crashes), a real crash confirmation is provable
/// here.
///
/// Off by default like every other acceptance suite (`xcodegen generate`
/// plus real `xcodebuild` invocations): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: schemata confirmation (Xcode)", .enabled(if: Acceptance.isEnabled))
struct XcodeSchemataConfirmationAcceptanceTests {
    private static let relativePath = "Sources/Widget.swift"

    /// `crashFlag()` starting `true` means the baseline's `!crashFlag()`
    /// guard never fires. Flipping it to `false` makes the guard fire and
    /// call `fatalError`, which Xcode's result bundle records as a
    /// structured `Crash:` failure — a real, independently-observed crash,
    /// not a simulated one.
    private static let librarySource = """
    public func crashFlag() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import XcodeConfirmationLib

    final class XcodeConfirmationLibTests: XCTestCase {
        func testCrashFlag() {
            if !crashFlag() {
                fatalError("mutation activated: crashing on purpose")
            }
        }
    }

    """

    private func stageProject() throws -> (directory: URL, projectFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-xcode-confirm-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources")
        let testSourcesDirectory = directory.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let projectManifest = """
        name: XcodeConfirmationLib
        options:
          bundleIdPrefix: dev.mutantkit.spike
        targets:
          XcodeConfirmationLib:
            type: framework
            platform: macOS
            sources: [Sources]
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
          XcodeConfirmationLibTests:
            type: bundle.unit-test
            platform: macOS
            sources: [Tests]
            dependencies:
              - target: XcodeConfirmationLib
                embed: true
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
        schemes:
          XcodeConfirmationLib:
            build:
              targets:
                XcodeConfirmationLib: all
                XcodeConfirmationLibTests: [test]
            test:
              targets: [XcodeConfirmationLibTests]
        """
        try Data(projectManifest.utf8).write(to: directory.appendingPathComponent("project.yml"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("XcodeConfirmationLibTests.swift"))

        try runXcodegen(in: directory)

        return (directory, directory.appendingPathComponent("XcodeConfirmationLib.xcodeproj"))
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

    private func lowerFixture() throws -> (points: [MutationPoint], program: SchemataProgram) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.librarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let chunk = SchemataChunk(
            chunkID: "xcode-confirm-fixture-chunk", points: points,
            projectIdentity: "XcodeConfirmationLib.xcodeproj",
            target: "XcodeConfirmationLib", module: "XcodeConfirmationLib", product: "XcodeConfirmationLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        return (points, program)
    }

    @Test("A real Xcode crash is confirmed by a genuinely independent second process before being credited as killedByCrash")
    func crashIsConfirmedByARealIndependentProcess() async throws {
        let (directory, projectFile) = try stageProject()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-xcode-confirm-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let (points, program) = try lowerFixture()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let originalSources = [Self.relativePath: Data(Self.librarySource.utf8)]

        let adapter = XcodeBuildAdapter(
            configuration: Configuration(), kind: .xcodeProject, projectFile: projectFile, projectRoot: directory
        )
        let workspaces = try WorkspaceManager(projectRoot: directory, scratchRoot: scratchRoot)
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: true, confirmTimedOutMutants: false
        )
        let runner = SchemataMutationRunner(
            planID: "plan-xcode-schemata-confirm", workUnitID: "plan-xcode-schemata-confirm",
            programs: [program], points: pointsByID, originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 180),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: policy
        )

        let outcome = try await runner.run()

        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass")
        #expect(outcome.results.count == 1)
        let result = try #require(outcome.results.first)
        // `killedByCrash` is only reachable with `confirmCrashKills: true`
        // when `confirmCrash` finds a `.crash`-kind confirmation whose own
        // independent STARTUP -> HIT chain (a genuinely different process,
        // under a fresh RunID) verified successfully and itself recorded a
        // real `Crash:` failure — this outcome alone is the real,
        // end-to-end proof a second independent process ran and crashed
        // the same way, not a placeholder standing in for inspecting it.
        #expect(result.outcome == .killedByCrash, "flipping crashFlag() must crash the test runner, confirmed: \(result.diagnosis)")
        #expect(
            result.diagnosis.contains("Confirmed by an independent rebuild"),
            "the diagnosis itself must name the confirmation, not just the primary crash: \(result.diagnosis)"
        )

        guard case .schemata = result.evidence?.applicationEvidence else {
            Issue.record("expected a schemata observation, got \(String(describing: result.evidence?.applicationEvidence))")
            return
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)
        #expect(leftovers.isEmpty, "every sandbox must be destroyed after use, found: \(leftovers)")
    }
}
