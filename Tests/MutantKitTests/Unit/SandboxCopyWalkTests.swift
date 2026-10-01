import Foundation
@testable import MutationExecution
import Testing

@Suite("Sandbox copy walk")
struct SandboxCopyWalkTests {
    /// A temporary tree under its canonical path. On macOS the temporary
    /// directory is `/var/...`, whose canonical form is `/private/var/...`,
    /// the spelling `CanonicalPath.resolve` returns.
    private func makeTree() throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-copywalk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        return URL(fileURLWithPath: try #require(CanonicalPath.resolve(created.path)), isDirectory: true)
    }

    private func write(_ relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test("A scratch root inside the tree is skipped when given in its canonical /private spelling")
    func scratchRootInsideTreeIsSkipped() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Sources/A.swift", in: root)
        try write("scratch/sbx_0123456789abcdef0123/Sources/A.swift", in: root)
        let scratch = root.appendingPathComponent("scratch").path
        #expect(scratch.hasPrefix("/private/") || scratch == CanonicalPath.resolve(scratch))

        var visited: [String] = []
        try SandboxCopyWalk.walk(root: root, excludes: [], skippingCanonicalPaths: [scratch]) { entry in
            visited.append(entry.relativePath)
            return true
        }

        #expect(visited == ["Sources", "Sources/A.swift"], "walked into the scratch root: \(visited)")
    }

    @Test("The same scratch root is skipped when given in its /var spelling")
    func scratchRootInAliasSpellingIsSkipped() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Sources/A.swift", in: root)
        try write("scratch/B.swift", in: root)
        // `URL.resolvingSymlinksInPath()` strips the leading /private.
        let alias = root.appendingPathComponent("scratch").resolvingSymlinksInPath().standardizedFileURL.path

        var visited: [String] = []
        try SandboxCopyWalk.walk(root: root, excludes: [], skippingCanonicalPaths: [alias]) { entry in
            visited.append(entry.relativePath)
            return true
        }

        #expect(visited == ["Sources", "Sources/A.swift"], "walked into the scratch root: \(visited)")
    }

    @Test("Without a skip, the same tree is walked in full")
    func controlWalksTheScratchRoot() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Sources/A.swift", in: root)
        try write("scratch/B.swift", in: root)

        var visited: [String] = []
        try SandboxCopyWalk.walk(root: root, excludes: [], skippingCanonicalPaths: []) { entry in
            visited.append(entry.relativePath)
            return true
        }

        #expect(visited == ["Sources", "Sources/A.swift", "scratch", "scratch/B.swift"])
    }
}
