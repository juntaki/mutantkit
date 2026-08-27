@testable import CLI
import Darwin
import Foundation

/// Throwaway git repositories for the tests that need real git behaviour
/// rather than a stand-in for it — `RunContextProbe`'s digest is defined in
/// terms of what `git ls-files` and `git status` actually report, so a fake
/// would only ever prove that the fake agrees with itself.
///
/// Shared between `RunContextProbeTests` and
/// `RunContextProbeContentIdentityTests`, which are two classes rather than
/// one because the second covers a distinct guarantee (content identity
/// across commits) and because one class carrying both would be past
/// SwiftLint's type-body-length threshold.
enum GitFixture {
    /// A fresh repository under the temporary directory, with an identity
    /// configured so `commit` works on a machine that has no global git
    /// config (a clean CI image).
    static func makeRepository(named label: String = "MutantKit-GitFixture") throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run(["init"], in: repo)
        try run(["config", "user.email", "tests@mutantkit.local"], in: repo)
        try run(["config", "user.name", "MutantKit Tests"], in: repo)
        return repo
    }

    /// The source/test/project-file shape every digest test starts from,
    /// committed, plus the digest it produces — so each test only has to
    /// express what it changed.
    static func committedBaseline() async throws -> (repo: URL, state: String) {
        let repo = try makeRepository(named: "MutantKit-RunContextProbeTests")
        try write("let x = 1\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try write("import XCTest\n", at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift"))
        try write("pbx-body\n", at: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        try write("<scheme/>\n", at: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        try write("# App\n", at: repo.appendingPathComponent("README.md"))
        try run(["add", "."], in: repo)
        try run(["commit", "-m", "baseline"], in: repo)
        return (repo, try await RunContextProbe.worktreeContentState(in: repo))
    }

    static func write(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    static func makeDirectory(_ relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func run(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let standardError = cloexecPipe()
        process.standardError = standardError
        try process.run()
        let message = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        BoundedProcessWait.wait(process)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
    }

    /// `run`, but capturing stdout — for the places a test needs a value back
    /// out of git rather than just an effect.
    static func output(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let standardOutput = cloexecPipe()
        process.standardOutput = standardOutput
        try process.run()
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        BoundedProcessWait.wait(process)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A `Pipe()` with both ends marked close-on-exec immediately.
    ///
    /// `pipe(2)` does not set `FD_CLOEXEC` by default, so any *other*,
    /// unrelated `posix_spawn`/`Process.run()` call racing on another
    /// thread while this pipe's write end is still open can inherit a copy
    /// of it, holding it open long after the intended child has exited and
    /// blocking `readDataToEndOfFile()` forever -- the identical bug class
    /// already fixed in
    /// `Sources/MutationExecution/ProcessSupervisor.swift`/
    /// `Sources/BenchmarkRunner/ToolRunner.swift`, caught here too by a
    /// real CI stack sample stuck in exactly this shape in
    /// `ProcessSupervisorResidueTests.survivingProcesses(referencing:)`.
    /// Safe for `git`'s own intended stdout/stderr the same way it is
    /// there: POSIX `dup2` always clears close-on-exec on the *new*
    /// descriptor it creates, regardless of the source's own flag, so
    /// `Process.run()`'s own `dup2`-based wiring into `git`'s real fds 1/2
    /// is unaffected by marking these *original* pipe fds here.
    private static func cloexecPipe() -> Pipe {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        return pipe
    }
}
