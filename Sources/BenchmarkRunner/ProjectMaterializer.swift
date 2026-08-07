import Foundation

/// A `BenchmarkProject` after cloning and checking out its pinned commit —
/// a real directory on disk a `MutationBenchmarkTool` can point a CLI at.
public struct MaterializedBenchmarkProject: Sendable {
    public let project: BenchmarkProject
    public let directory: URL

    public init(project: BenchmarkProject, directory: URL) {
        self.project = project
        self.directory = directory
    }
}

/// Thin seam over `git`, so `ProjectMaterializer` is unit-testable without a
/// real network clone — a fake conforming to this protocol drives every
/// materializer test.
public protocol GitCommandRunning: Sendable {
    func run(_ arguments: [String], in directory: URL) async throws -> (exitCode: Int32, output: String)
}

/// Shells to the real `git` binary. The only conformance used outside tests.
public struct SystemGitCommandRunner: GitCommandRunning {
    public init() {}

    public func run(_ arguments: [String], in directory: URL) async throws -> (exitCode: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum MaterializerError: Error, Equatable, CustomStringConvertible {
    case cloneFailed(projectID: String, output: String)
    case checkoutFailed(projectID: String, commitSHA: String, output: String)
    /// A working tree was not byte-for-byte what the pinned commit (plus,
    /// if given, a successfully-applied patch) says it should be —
    /// `git status --porcelain` returned non-empty at a point where it must
    /// not have. A dirty tree at benchmark time means the measurement is
    /// not actually reproducible against the pinned commit, so this is a
    /// hard failure, never a warning.
    case dirtyWorkingTree(projectID: String, status: String)
    case patchFailed(projectID: String, patchPath: String, output: String)

    public var description: String {
        switch self {
        case let .cloneFailed(projectID, output):
            "cloning \(projectID) failed: \(output)"
        case let .checkoutFailed(projectID, commitSHA, output):
            "checking out \(commitSHA) for \(projectID) failed: \(output)"
        case let .dirtyWorkingTree(projectID, status):
            "\(projectID)'s working tree is not clean at a point where it must be: \(status)"
        case let .patchFailed(projectID, patchPath, output):
            "applying patch \(patchPath) to \(projectID) failed: \(output)"
        }
    }
}

/// Clones a `BenchmarkProject` fresh, checks out its pinned commit, and
/// optionally applies one explicit patch file (the incremental-mode
/// fixture) — never a vendored copy of the external repository committed
/// alongside `Benchmarks/results`. Every materialization starts from a
/// clean clone; nothing here mutates a directory in place across runs.
public struct ProjectMaterializer: Sendable {
    private let git: any GitCommandRunning

    public init(git: any GitCommandRunning = SystemGitCommandRunner()) {
        self.git = git
    }

    /// - Parameters:
    ///   - project: which repository/commit to materialize.
    ///   - destination: an empty (or non-existent) directory to clone into.
    ///   - patchFile: the incremental-mode fixture, applied after checkout
    ///     and verified to have actually changed the tree — a patch that
    ///     silently fails to apply (wrong context lines against a moved
    ///     pinned commit) must never be treated as "no-op, still valid."
    public func materialize(
        _ project: BenchmarkProject, into destination: URL, patchFile: URL? = nil
    ) async throws -> MaterializedBenchmarkProject {
        let clone = try await git.run(
            ["clone", "--no-checkout", project.repositoryURL, destination.path], in: destination.deletingLastPathComponent()
        )
        guard clone.exitCode == 0 else {
            throw MaterializerError.cloneFailed(projectID: project.id, output: clone.output)
        }

        let checkout = try await git.run(["checkout", project.commitSHA], in: destination)
        guard checkout.exitCode == 0 else {
            throw MaterializerError.checkoutFailed(projectID: project.id, commitSHA: project.commitSHA, output: checkout.output)
        }

        try await requireClean(project, in: destination)

        if let patchFile {
            let apply = try await git.run(["apply", patchFile.path], in: destination)
            guard apply.exitCode == 0 else {
                throw MaterializerError.patchFailed(projectID: project.id, patchPath: patchFile.path, output: apply.output)
            }
        }

        return MaterializedBenchmarkProject(project: project, directory: destination)
    }

    private func requireClean(_ project: BenchmarkProject, in directory: URL) async throws {
        let status = try await git.run(["status", "--porcelain"], in: directory)
        guard status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaterializerError.dirtyWorkingTree(projectID: project.id, status: status.output)
        }
    }
}
