import Foundation
@testable import MutationExecution
import MutationModel
import Testing

/// The baseline control runs binaries that were compiled in the baseline
/// sandbox. Their `#filePath` values name that sandbox, and tests read fixtures
/// and golden files through them, so the sandbox must outlive every control run.
/// Destroying it right after the baseline made those tests fail on the
/// unmutated control and turned genuine kills into `flaky`.
@Suite("BaselineControlSource: baseline sandbox lifetime")
struct BaselineControlSandboxLifetimeTests {
    private struct StubTestAdapter: TestAdapter {
        func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
            fatalError("not exercised")
        }

        func runMutant(
            _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
        ) async throws -> TestRunResult {
            fatalError("not exercised")
        }
    }

    private let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-control-project-\(UUID().uuidString)")
    private let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-control-scratch-\(UUID().uuidString)")

    private func makeWorkspaces() throws -> WorkspaceManager {
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("// fixture\n".utf8).write(to: projectRoot.appendingPathComponent("Package.swift"))
        return try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
    }

    private func makeArtifact() throws -> BuildArtifact {
        let products = projectRoot.appendingPathComponent("Products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: products.appendingPathComponent("Fake.xctestrun"))
        return BuildArtifact(
            productsDirectory: products, productHash: "h", xctestrunPath: nil,
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/")
        )
    }

    @Test("The baseline sandbox survives until the control is torn down, then goes")
    func sandboxLivesWithTheControl() async throws {
        let workspaces = try makeWorkspaces()
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let artifact = try makeArtifact()
        let execution = ExecutionSettings(retestKilledMutants: true)

        let control = await BaselineControlSource.establish(execution, from: artifact, workspaces: workspaces, test: StubTestAdapter())
        let source = try #require(control)
        await BaselineControlSource.retainOrDestroy(sandbox, control: source, workspaces: workspaces)

        #expect(FileManager.default.fileExists(atPath: sandbox.workspaceRoot.path))
        #expect(FileManager.default.fileExists(atPath: source.retained.path))

        await source.teardown()

        #expect(!FileManager.default.fileExists(atPath: sandbox.containerRoot.path))
        #expect(!FileManager.default.fileExists(atPath: source.retained.path))
    }

    @Test("Without a control the baseline sandbox is destroyed at once")
    func sandboxIsDestroyedWithoutControl() async throws {
        let workspaces = try makeWorkspaces()
        let sandbox = try await workspaces.createSandbox(id: "baseline")

        await BaselineControlSource.retainOrDestroy(sandbox, control: nil, workspaces: workspaces)

        #expect(!FileManager.default.fileExists(atPath: sandbox.containerRoot.path))
    }
}
