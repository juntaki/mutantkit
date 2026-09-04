import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Real, end-to-end iOS-Simulator schemata confirmation, deliberately never
/// exercised by any existing acceptance suite before this one: every
/// existing schemata-confirmation test (`XcodeSchemataConfirmationAcceptanceTests`,
/// `XcodeSchemataAdapterAcceptanceTests`) runs on a macOS unit-test target on
/// purpose, explicitly isolating the confirmation/adapter-conformance
/// question from simulator-specific concerns. This suite is that missing
/// half: a real `xcodegen`-generated iOS framework + unit-test bundle, run
/// against a real, leased iPhone Simulator, with deterministic timeout and
/// crash mutants.
///
/// Off by default like every other acceptance suite (`xcodegen generate`
/// plus real `xcodebuild` invocations against a real simulator):
/// `MUTANTKIT_ACCEPTANCE=1 swift test`.
///
/// `.serialized`: this environment provisions exactly one real iPhone
/// Simulator device for the installed runtime -- run concurrently (Swift
/// Testing's own default), the crash and timeout tests both drive the same
/// booted simulator at once, and one real capture showed this genuinely
/// corrupting the crash confirmation's own runtime transcript (the verifier
/// correctly failed closed: "no STARTUP event matching this run's own
/// expectation"). Not a flaky test to retry past -- a real, understood
/// resource-contention cause, fixed by never letting the two share a
/// simulator's attention at the same time.
@Suite("Acceptance: schemata confirmation (iOS Simulator)", .enabled(if: Acceptance.simulatorEnabled), .serialized)
struct SchemataIOSSimulatorConfirmationAcceptanceTests {
    private static let relativePath = "Sources/Widget.swift"

    /// `crashFlag()` starting `true` means the baseline's `!crashFlag()`
    /// guard never fires (same shape as `XcodeSchemataConfirmationAcceptanceTests`).
    private static let librarySource = """
    public func crashFlag() -> Bool {
        true
    }

    """

    private static let testSource = """
    import XCTest
    import IOSConfirmationLib

    final class IOSConfirmationLibTests: XCTestCase {
        func testCrashFlag() {
            if !crashFlag() {
                fatalError("mutation activated: crashing on purpose")
            }
        }
    }

    """

    private func stageProject() throws -> (directory: URL, projectFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-ios-confirm-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources")
        let testSourcesDirectory = directory.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let projectManifest = """
        name: IOSConfirmationLib
        options:
          bundleIdPrefix: dev.mutantkit.spike
        targets:
          IOSConfirmationLib:
            type: framework
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Sources]
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
          IOSConfirmationLibTests:
            type: bundle.unit-test
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Tests]
            dependencies:
              - target: IOSConfirmationLib
                embed: true
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
        schemes:
          IOSConfirmationLib:
            build:
              targets:
                IOSConfirmationLib: all
                IOSConfirmationLibTests: [test]
            test:
              targets: [IOSConfirmationLibTests]
        """
        try Data(projectManifest.utf8).write(to: directory.appendingPathComponent("project.yml"))
        try Data(Self.librarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("IOSConfirmationLibTests.swift"))

        try runXcodegen(in: directory)

        return (directory, directory.appendingPathComponent("IOSConfirmationLib.xcodeproj"))
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
            chunkID: "ios-confirm-fixture-chunk", points: points,
            projectIdentity: "IOSConfirmationLib.xcodeproj",
            target: "IOSConfirmationLib", module: "IOSConfirmationLib", product: "IOSConfirmationLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.librarySource)]
        )
        return (points, program)
    }

    @Test("A real iOS-Simulator crash is confirmed by a genuinely independent second process before being credited as killedByCrash")
    func crashIsConfirmedByARealIndependentProcess() async throws {
        let destination = try Acceptance.iPhoneDestination()
        let (directory, projectFile) = try stageProject()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-ios-confirm-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let (points, program) = try lowerFixture()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let originalSources = [Self.relativePath: Data(Self.librarySource.utf8)]

        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "IOSConfirmationLib", destination: destination)
        )
        let adapter = XcodeBuildAdapter(
            configuration: configuration, kind: .xcodeProject, projectFile: projectFile, projectRoot: directory
        )
        let workspaces = try WorkspaceManager(projectRoot: directory, scratchRoot: scratchRoot)
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: true, confirmTimedOutMutants: false
        )
        let runner = SchemataMutationRunner(
            planID: "plan-ios-schemata-confirm", workUnitID: "plan-ios-schemata-confirm",
            programs: [program], points: pointsByID, originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 300),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: policy
        )

        let outcome = try await runner.run()

        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass")
        #expect(outcome.results.count == 1)
        #expect(outcome.isolatedFallbacks.isEmpty, "expected zero isolated fallbacks: \(outcome.isolatedFallbacks)")
        #expect(outcome.sharedChunkBuildFailureEvents.isEmpty, "expected zero shared chunk build failures")
        let result = try #require(outcome.results.first)
        #expect(result.outcome == .killedByCrash, "flipping crashFlag() must crash the test runner, confirmed: \(result.diagnosis)")
        #expect(
            result.diagnosis.contains("Confirmed by an independent rebuild"),
            "the diagnosis itself must name the confirmation, not just the primary crash: \(result.diagnosis)"
        )

        guard case let .schemata(observation) = result.evidence?.applicationEvidence else {
            Issue.record("expected a schemata observation, got \(String(describing: result.evidence?.applicationEvidence))")
            return
        }
        try assertPrimaryProofChain(observation)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)
        #expect(leftovers.isEmpty, "every sandbox must be destroyed after use, found: \(leftovers)")
    }

    /// The primary run's own proof chain, the only half `MutationResult`'s
    /// public evidence exposes -- `finalize`'s own `sourceApplication:
    /// .applied(handoff.evidence)` is always the *primary* observation, per
    /// `SchemataMutationRunner.runEntries`; the confirmation's own separate
    /// `SchemataExecutionObservation` (its own fresh RunID, its own
    /// post-rebuild receipt) is gathered and verified internally but not
    /// retained on the public record -- `SchemataExecutionObservation`'s own
    /// doc comment is explicit that this type is deliberately raw, "gather
    /// the facts, decide nothing," and only the verdict survives past
    /// `MutationVerdictVerifier.verifySchemataChain`. The confirmation
    /// having genuinely run, under an independent process, is what
    /// `result.diagnosis.contains("Confirmed by an independent rebuild")`
    /// is this test's own proof of instead.
    private func assertPrimaryProofChain(_ observation: SchemataExecutionObservation) throws {
        let expectation = observation.expectation
        let startupMatch = observation.transcript.records.contains {
            if case let .startup(event) = $0 {
                return event.runID == expectation.runID && event.compilationUnitID == expectation.compilationUnitID
            }
            return false
        }
        #expect(startupMatch, "expected a STARTUP record matching the primary run's own expectation")

        let hitMatch = observation.transcript.records.first {
            if case let .hit(event) = $0 {
                return event.runID == expectation.runID && event.compilationUnitID == expectation.compilationUnitID
            }
            return false
        }
        guard case let .hit(hitEvent) = hitMatch else {
            Issue.record("expected a HIT record matching the primary run's own expectation")
            return
        }

        let receipt = try #require(observation.buildReceipt, "expected a resolved build receipt for the primary run")
        let knownImageUUIDs = receipt.images.flatMap { $0.slices.map(\.imageUUID) }
        #expect(
            knownImageUUIDs.contains(hitEvent.imageUUID),
            "expected the HIT record's own imageUUID to appear among the primary build receipt's own image slices"
        )
    }

    // MARK: - Deterministic timeout

    /// `while false { }` mutated to `while true { }` (a genuine, unbounded
    /// empty loop -- confirmed live, not assumed, to actually hang rather
    /// than being optimized away) makes `timeoutProbe()` never return, so
    /// `testTimeoutProbe` never completes.
    private static let timeoutLibrarySource = """
    public func timeoutProbe() -> Int {
        while false {
        }
        return 42
    }

    """

    private static let timeoutTestSource = """
    import XCTest
    import IOSTimeoutConfirmationLib

    final class IOSTimeoutConfirmationLibTests: XCTestCase {
        func testTimeoutProbe() {
            XCTAssertEqual(timeoutProbe(), 42)
        }
    }

    """

    private func stageTimeoutProject() throws -> (directory: URL, projectFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-ios-timeout-confirm-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources")
        let testSourcesDirectory = directory.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let projectManifest = """
        name: IOSTimeoutConfirmationLib
        options:
          bundleIdPrefix: dev.mutantkit.spike
        targets:
          IOSTimeoutConfirmationLib:
            type: framework
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Sources]
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
          IOSTimeoutConfirmationLibTests:
            type: bundle.unit-test
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Tests]
            dependencies:
              - target: IOSTimeoutConfirmationLib
                embed: true
            settings:
              base:
                GENERATE_INFOPLIST_FILE: YES
        schemes:
          IOSTimeoutConfirmationLib:
            build:
              targets:
                IOSTimeoutConfirmationLib: all
                IOSTimeoutConfirmationLibTests: [test]
            test:
              targets: [IOSTimeoutConfirmationLibTests]
        """
        try Data(projectManifest.utf8).write(to: directory.appendingPathComponent("project.yml"))
        try Data(Self.timeoutLibrarySource.utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.timeoutTestSource.utf8).write(to: testSourcesDirectory.appendingPathComponent("IOSTimeoutConfirmationLibTests.swift"))

        try runXcodegen(in: directory)

        return (directory, directory.appendingPathComponent("IOSTimeoutConfirmationLib.xcodeproj"))
    }

    private func lowerTimeoutFixture() throws -> (points: [MutationPoint], program: SchemataProgram) {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.timeoutLibrarySource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        #expect(points.count == 1, "expected exactly one candidate")

        let chunk = SchemataChunk(
            chunkID: "ios-timeout-confirm-fixture-chunk", points: points,
            projectIdentity: "IOSTimeoutConfirmationLib.xcodeproj",
            target: "IOSTimeoutConfirmationLib", module: "IOSTimeoutConfirmationLib", product: "IOSTimeoutConfirmationLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.timeoutLibrarySource)]
        )
        return (points, program)
    }

    @Test("A real iOS-Simulator timeout is confirmed by a genuinely independent second process before being credited as verifiedTimeout")
    func timeoutIsConfirmedByARealIndependentProcess() async throws {
        let destination = try Acceptance.iPhoneDestination()
        let (directory, projectFile) = try stageTimeoutProject()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-ios-timeout-confirm-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let (points, program) = try lowerTimeoutFixture()
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let originalSources = [Self.relativePath: Data(Self.timeoutLibrarySource.utf8)]

        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "IOSTimeoutConfirmationLib", destination: destination)
        )
        let adapter = XcodeBuildAdapter(
            configuration: configuration, kind: .xcodeProject, projectFile: projectFile, projectRoot: directory
        )
        let workspaces = try WorkspaceManager(projectRoot: directory, scratchRoot: scratchRoot)
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
        )
        // A short, fixed mutant timeout -- the whole point is to hang, not
        // to exercise the real adaptive-timeout derivation, and a fixed 20s
        // budget keeps this acceptance test's own wall-clock reasonable
        // while still being generous against real device/build variance.
        let timeouts = TimeoutSettings(
            baselineSeconds: 300,
            mutant: MutantTimeoutSettings(strategy: .fixed, maximumSeconds: 20)
        )
        let runner = SchemataMutationRunner(
            planID: "plan-ios-schemata-timeout-confirm", workUnitID: "plan-ios-schemata-timeout-confirm",
            programs: [program], points: pointsByID, originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeouts: timeouts,
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: policy
        )

        let outcome = try await runner.run()

        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass")
        #expect(outcome.results.count == 1)
        #expect(outcome.isolatedFallbacks.isEmpty, "expected zero isolated fallbacks: \(outcome.isolatedFallbacks)")
        #expect(outcome.sharedChunkBuildFailureEvents.isEmpty, "expected zero shared chunk build failures")
        let result = try #require(outcome.results.first)
        #expect(result.outcome == .verifiedTimeout, "flipping while false to while true must hang the test runner, confirmed: \(result.diagnosis)")

        guard case let .schemata(observation) = result.evidence?.applicationEvidence else {
            Issue.record("expected a schemata observation, got \(String(describing: result.evidence?.applicationEvidence))")
            return
        }
        try assertPrimaryProofChain(observation)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)
        #expect(leftovers.isEmpty, "every sandbox must be destroyed after use, found: \(leftovers)")
    }
}
