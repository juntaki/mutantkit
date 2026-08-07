@testable import BenchmarkRunner
import Foundation
import Testing

/// A scripted `git` — every test controls exactly what each command
/// returns, so no test in this file ever touches the network.
private actor FakeGit: GitCommandRunning {
    struct Call: Equatable {
        let arguments: [String]
    }

    private var responses: [(exitCode: Int32, output: String)]
    private(set) var calls: [Call] = []

    init(responses: [(exitCode: Int32, output: String)]) {
        self.responses = responses
    }

    func run(_ arguments: [String], in directory: URL) async throws -> (exitCode: Int32, output: String) {
        calls.append(Call(arguments: arguments))
        guard !responses.isEmpty else { return (0, "") }
        return responses.removeFirst()
    }
}

@Suite("ProjectMaterializer")
struct ProjectMaterializerTests {
    private static let project = BenchmarkProject(
        id: "example", repositoryURL: "https://example.com/example.git",
        commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
    )

    @Test("A clean clone + checkout materializes successfully")
    func materializesCleanCheckout() async throws {
        let git = FakeGit(responses: [(0, ""), (0, ""), (0, "")])
        let materializer = ProjectMaterializer(git: git)
        let result = try await materializer.materialize(Self.project, into: URL(fileURLWithPath: "/tmp/example"))
        #expect(result.project.id == "example")
        let calls = await git.calls
        #expect(calls.map(\.arguments.first) == ["clone", "checkout", "status"])
    }

    @Test("A clone failure throws .cloneFailed, never silently proceeds to checkout")
    func cloneFailureThrows() async throws {
        let git = FakeGit(responses: [(128, "fatal: could not resolve host")])
        let materializer = ProjectMaterializer(git: git)
        await #expect(throws: MaterializerError.self) {
            _ = try await materializer.materialize(Self.project, into: URL(fileURLWithPath: "/tmp/example"))
        }
        #expect(await git.calls.count == 1, "checkout must never be attempted after a failed clone")
    }

    @Test("A checkout failure (unknown commit) throws .checkoutFailed")
    func checkoutFailureThrows() async throws {
        let git = FakeGit(responses: [(0, ""), (1, "fatal: reference is not a tree")])
        let materializer = ProjectMaterializer(git: git)
        await #expect(throws: MaterializerError.self) {
            _ = try await materializer.materialize(Self.project, into: URL(fileURLWithPath: "/tmp/example"))
        }
    }

    @Test("A dirty working tree after checkout is rejected, never silently accepted")
    func dirtyWorkingTreeIsRejected() async throws {
        let git = FakeGit(responses: [(0, ""), (0, ""), (0, " M Sources/Widget.swift\n")])
        let materializer = ProjectMaterializer(git: git)
        await #expect(throws: MaterializerError.self) {
            _ = try await materializer.materialize(Self.project, into: URL(fileURLWithPath: "/tmp/example"))
        }
    }

    @Test("A patch file is applied after a clean checkout, and its own failure throws .patchFailed")
    func patchApplicationSucceeds() async throws {
        let git = FakeGit(responses: [(0, ""), (0, ""), (0, ""), (0, "")])
        let materializer = ProjectMaterializer(git: git)
        _ = try await materializer.materialize(
            Self.project, into: URL(fileURLWithPath: "/tmp/example"), patchFile: URL(fileURLWithPath: "/tmp/fixture.patch")
        )
        let calls = await git.calls
        #expect(calls.map(\.arguments.first) == ["clone", "checkout", "status", "apply"])
    }

    @Test("A patch that fails to apply throws .patchFailed, not treated as a no-op")
    func patchFailureThrows() async throws {
        let git = FakeGit(responses: [(0, ""), (0, ""), (0, ""), (1, "error: patch does not apply")])
        let materializer = ProjectMaterializer(git: git)
        await #expect(throws: MaterializerError.self) {
            _ = try await materializer.materialize(
                Self.project, into: URL(fileURLWithPath: "/tmp/example"), patchFile: URL(fileURLWithPath: "/tmp/fixture.patch")
            )
        }
    }
}
