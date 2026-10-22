@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

@Suite("SwiftPM coverage exporter")
struct SwiftPMCoverageExporterTests {
    private func success(_ stdout: String = "") -> ProcessResult {
        ProcessResult(
            exitCode: 0, standardOutput: Data(stdout.utf8), standardError: Data(),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
    }

    @Test("The scratch directory is created even when its parent does not exist yet")
    func scratchDirectoryIsCreatedWithItsParents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-exporter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = root.appendingPathComponent("run.profraw")
        try Data("raw".utf8).write(to: profile)
        let scratch = root.appendingPathComponent("a/b/scratch", isDirectory: true)

        let result = await SwiftPMCoverageExporter.export(
            profileURL: profile,
            testBundleBinary: root.appendingPathComponent("Bundle"),
            scratchDirectory: scratch,
            processRunner: { [success] _, _, _, _ in success("{}") }
        )

        #expect(result == .exported(Data("{}".utf8)))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: scratch.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test("A missing profile is unavailable and runs nothing")
    func missingProfileIsUnavailable() async {
        let ran = LockedFlag()
        let result = await SwiftPMCoverageExporter.export(
            profileURL: URL(fileURLWithPath: "/nonexistent/run.profraw"),
            testBundleBinary: URL(fileURLWithPath: "/nonexistent/Bundle"),
            scratchDirectory: FileManager.default.temporaryDirectory,
            processRunner: { _, _, _, _ in
                ran.set()
                throw CancellationError()
            }
        )
        #expect(result == .unavailable(reason: "no profile at /nonexistent/run.profraw"))
        #expect(!ran.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
