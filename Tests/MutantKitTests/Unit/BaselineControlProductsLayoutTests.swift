import Foundation
@testable import MutationExecution
import MutationModel
import Testing

/// The baseline control clones the unmutated products once and runs every
/// control from copies of that clone, so the copies must keep the layout
/// `swift test --scratch-path` looks for, whichever shape the toolchain gave
/// the products.
@Suite("Baseline control: products layout")
struct BaselineControlProductsLayoutTests {
    private struct ManifestAdapter: TestAdapter, PackageManifestConfirmationRetesting {
        func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
            fatalError("not exercised")
        }

        func runMutant(
            _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
        ) async throws -> TestRunResult {
            fatalError("not exercised")
        }

        func runConfirmationRetest(
            _ point: MutationPoint, packageRoot: URL, productsScratchRoot: URL, timeoutSeconds: Double,
            selectedTests: Set<TestIdentifier>?
        ) async throws -> TestRunResult {
            fatalError("not exercised")
        }

        func resolveDependenciesForConfirmationRetest(packageRoot: URL, timeoutSeconds: Double) async throws {}
    }

    private func controlClone(layout: String) async throws -> (clone: URL, cleanup: [URL]) {
        let temp = FileManager.default.temporaryDirectory
        let projectRoot = temp.appendingPathComponent("mk-bc-project-\(UUID().uuidString)")
        let scratchRoot = temp.appendingPathComponent("mk-bc-scratch-\(UUID().uuidString)")
        let buildDir = projectRoot.appendingPathComponent(".build")
        let bundle = buildDir.appendingPathComponent("\(layout)/Fake.xctest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: bundle.appendingPathComponent("Fake"))
        let debug = buildDir.appendingPathComponent("debug")
        try FileManager.default.createSymbolicLink(atPath: debug.path, withDestinationPath: layout)

        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        var execution = ExecutionSettings()
        execution.retestKilledMutants = true
        let artifact = BuildArtifact(
            productsDirectory: debug, productHash: "h", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: "/tmp")
        )
        let source = try #require(await BaselineControlSource.establish(
            execution, from: artifact, workspaces: workspaces, test: ManifestAdapter()
        ))
        let clone = try await workspaces.cloneProducts(from: source.retained, id: "baseline-control-test")
        return (clone, [projectRoot, scratchRoot])
    }

    @Test("A control clone keeps the out/Products/Debug layout of Swift 6.4")
    func outProductsLayout() async throws {
        let (clone, cleanup) = try await controlClone(layout: "out/Products/Debug")
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("out/Products/Debug/Fake.xctest/Fake").path))
        #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent("Products/Debug").path))
    }

    @Test("A control clone keeps the <triple>/<configuration> layout")
    func tripleLayout() async throws {
        let (clone, cleanup) = try await controlClone(layout: "arm64-apple-macosx/debug")
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("arm64-apple-macosx/debug/Fake.xctest/Fake").path))
    }
}
