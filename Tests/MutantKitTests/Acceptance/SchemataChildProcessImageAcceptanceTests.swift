import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// A mutation in a library that only a *child-process executable* runs.
///
/// The test target links the library (so the planner reaches it) but never calls the mutated file; it
/// launches the executable, which inherits the schemata environment and activates the mutation there.
/// The build receipt must therefore name that executable's image as one that contains the library's
/// compilation unit, because its target graph proves it. An unrelated executable that does not depend on
/// the library must never be part of the set.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: schemata activation in a child-process executable (SwiftPM)", .enabled(if: Acceptance.isEnabled))
struct SchemataChildProcessImageAcceptanceTests {
    private static let gatePath = "Sources/ChildLib/Gate.swift"

    private static let gateSource = """
    public enum Gate {
        public static var enabled: Bool {
            true
        }
    }

    """

    private static let otherSource = """
    public enum Other {
        public static let answer = 42
    }

    """

    private static let childMain = """
    import ChildLib

    print(Gate.enabled ? "on" : "off")

    """

    private static let unrelatedMain = """
    print("unrelated")

    """

    /// Two tests launch the same executable, so one image UUID shows up under several PIDs.
    private static let testSource = """
    import XCTest
    import ChildLib

    final class ChildProcessTests: XCTestCase {
        private func run(_ tool: String) throws -> String {
            let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            let process = Process()
            process.executableURL = products.appendingPathComponent(tool)
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func testTestProcessNeverRunsTheGate() {
            XCTAssertEqual(Other.answer, 42)
        }

        func testChildReportsGateOn() throws {
            XCTAssertEqual(try run("child-tool"), "on")
        }

        func testChildReportsGateOnAgain() throws {
            XCTAssertEqual(try run("child-tool"), "on")
        }

        func testUnrelatedToolRuns() throws {
            XCTAssertEqual(try run("unrelated-tool"), "unrelated")
        }
    }

    """

    private func stagePackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-child-process-image-\(UUID().uuidString)")
        let files: [(String, String)] = [
            ("Package.swift", """
            // swift-tools-version:6.0
            import PackageDescription

            let package = Package(
                name: "ChildProcessFixture",
                platforms: [.macOS(.v14)],
                products: [
                    .library(name: "ChildLib", targets: ["ChildLib"]),
                    .executable(name: "child-tool", targets: ["ChildTool"]),
                    .executable(name: "unrelated-tool", targets: ["UnrelatedTool"])
                ],
                targets: [
                    .target(name: "ChildLib"),
                    .executableTarget(name: "ChildTool", dependencies: ["ChildLib"]),
                    .executableTarget(name: "UnrelatedTool"),
                    .testTarget(name: "ChildProcessTests", dependencies: ["ChildLib"])
                ]
            )
            """),
            (Self.gatePath, Self.gateSource),
            ("Sources/ChildLib/Other.swift", Self.otherSource),
            ("Sources/ChildTool/main.swift", Self.childMain),
            ("Sources/UnrelatedTool/main.swift", Self.unrelatedMain),
            ("Tests/ChildProcessTests/ChildProcessTests.swift", Self.testSource)
        ]
        for (path, contents) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return directory
    }

    private func discover() throws -> [MutationPoint] {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.gateSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.gatePath
        )
        #expect(points.count == 1)
        return points
    }

    private func runIsolated(project: URL, points: [MutationPoint], scratch: URL) async throws -> [MutationResult] {
        let configuration = Configuration()
        let plan = MutationPlan(
            planID: "plan-child-process-isolated", createdAt: Date(), projectRoot: project.path,
            toolchain: ToolchainFingerprint(
                toolVersion: "0.0.0", toolCommitSHA: String(repeating: "0", count: 40), swiftVersion: "6.0", swiftSyntaxVersion: "600.0.0",
                xcodeVersion: nil
            ),
            configurationHash: configuration.configurationHash,
            sourceFileHashes: [Self.gatePath: ContentHash.of(Self.gateSource)],
            mutations: points, skipped: [], operators: [BoolLiteralInversionOperator.descriptor]
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: project, build: adapter, test: adapter,
            workspaces: try WorkspaceManager(projectRoot: project, scratchRoot: scratch)
        )
        return try await runner.run().results
    }

    private func runSchemata(project: URL, points: [MutationPoint], scratch: URL) async throws -> [MutationResult] {
        let chunk = SchemataChunk(
            chunkID: "child-process-chunk", points: points, projectIdentity: "ChildProcessFixture", target: "ChildLib",
            module: "ChildLib", product: "ChildLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.gatePath, contents: Self.gateSource)]
        )
        let configuration = Configuration()
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let runner = SchemataMutationRunner(
            planID: "plan-child-process-schemata", workUnitID: "plan-child-process-schemata", programs: [program],
            points: Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) }),
            originalSources: [Self.gatePath: Data(Self.gateSource.utf8)], build: adapter, test: adapter,
            workspaces: try WorkspaceManager(projectRoot: project, scratchRoot: scratch),
            timeouts: TimeoutSettings(baselineSeconds: 180), toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments",
            policy: .init(
                retestKilledMutants: configuration.execution.retestKilledMutants,
                confirmCrashKills: configuration.execution.confirmCrashKills,
                confirmTimedOutMutants: configuration.execution.confirmTimedOutMutants
            )
        )
        let outcome = try await runner.run()
        #expect(outcome.baseline.passed, "the unmutated fixture must build and pass under schemata too")
        return outcome.results
    }

    @Test("A mutation only the child executable runs is a verified kill, in the executable's own image, with the same verdict as isolated")
    func childProcessActivationIsProven() async throws {
        let project = try stagePackage()
        let isolatedScratch = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-child-iso-\(UUID().uuidString)")
        let schemataScratch = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-child-sch-\(UUID().uuidString)")
        for directory in [isolatedScratch, schemataScratch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { for url in [project, isolatedScratch, schemataScratch] { try? FileManager.default.removeItem(at: url) } }

        let points = try discover()
        let isolated = try #require(try await runIsolated(project: project, points: points, scratch: isolatedScratch).first)
        let schemata = try #require(try await runSchemata(project: project, points: points, scratch: schemataScratch).first)

        #expect(isolated.outcome == .killedByAssertion, "isolated: \(isolated.diagnosis)")
        #expect(schemata.outcome == .killedByAssertion, "schemata: \(schemata.diagnosis)")
        #expect(Set(isolated.testSummary?.failingTests ?? []) == Set(schemata.testSummary?.failingTests ?? []))

        guard case let .schemata(observation)? = schemata.evidence?.applicationEvidence else {
            Issue.record("the schemata result carries no schemata evidence (it fell back or was not verified there)")
            return
        }
        let receipt = try #require(observation.buildReceipt)
        let unit = try #require(receipt.compilationUnits.first)
        let containing = receipt.images(containing: unit)
        let names = containing.map { URL(fileURLWithPath: $0.binaryPath).lastPathComponent }
        #expect(names.contains("child-tool"), "the executable that links the library must be in the containing set: \(names)")
        #expect(!names.contains("unrelated-tool"), "an executable that does not depend on the library must never be in the set: \(names)")
        #expect(receipt.images.allSatisfy { image in
            URL(fileURLWithPath: image.binaryPath).lastPathComponent != "unrelated-tool"
        })

        // Every matching event comes from the child executable's image, from more than one process.
        let childImage = try #require(containing.first { URL(fileURLWithPath: $0.binaryPath).lastPathComponent == "child-tool" })
        let childUUIDs = Set(childImage.slices.map(\.imageUUID))
        let hits = observation.transcript.records.compactMap { record -> RuntimeHitEvent? in
            if case let .hit(event) = record { event } else { nil }
        }
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { childUUIDs.contains($0.imageUUID) })
        #expect(Set(hits.map(\.processID)).count >= 2, "the same image UUID appears under several PIDs (one per child launch)")
    }
}
