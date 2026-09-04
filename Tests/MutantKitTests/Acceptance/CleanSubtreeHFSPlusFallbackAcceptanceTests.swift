import Foundation
@testable import MutationExecution
import Testing

/// Proves `WorkspaceManager`'s clean-subtree-index fast path (`Configuration
/// .execution.cleanSubtreeCloning`, see `CleanSubtreeIndex`'s own doc
/// comment) falls back correctly when `clonefile` genuinely is not
/// available — a real, freshly-mounted HFS+ (non-APFS) volume, not merely
/// `supportsAPFSClone()`'s own logic asserting it would.
///
/// Split out of `WorkspaceManagerCleanSubtreeCloningTests` (Unit/), which
/// covers every other invariant of this fast path deterministically and
/// fast, in-process. This one test is neither: creating, mounting and
/// unmounting a real disk image via `hdiutil` costs real wall-clock seconds
/// and depends on the host actually being able to create disk images (not
/// guaranteed in every sandboxed CI environment) — exactly the profile
/// `Acceptance.isEnabled`'s own doc comment describes ("too slow to pay on
/// every `swift test`"), so this test is gated and located the same way
/// every other acceptance test is, rather than left running unconditionally
/// in the default fast unit-test loop.
///
///     MUTANTKIT_ACCEPTANCE=1 swift test --filter CleanSubtreeHFSPlusFallbackAcceptanceTests
///
/// "Identical" below means content and relative directory layout, not POSIX
/// permission bits — see `WorkspaceManagerCleanSubtreeCloningTests`' own doc
/// comment (and its Section F) for why permission bits are a separate claim
/// this fast path does not make.
@Suite("Acceptance: clean-subtree-index fallback on a real non-APFS (HFS+) volume", .enabled(if: Acceptance.isEnabled))
struct CleanSubtreeHFSPlusFallbackAcceptanceTests {
    @Test(
        """
        On a real, non-APFS (HFS+) volume, the fast path falls back to a whole-directory copyItem and still \
        produces output with identical content and layout, including a preserved internal symlink
        """
    )
    func fallbackIsCorrectOnARealNonAPFSVolume() async throws {
        let dmgPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("csc-nonapfs-\(UUID().uuidString)")
            .appendingPathExtension("dmg")
        let volumeName = "mkt-csc-\(UUID().uuidString.prefix(8))"

        try Self.run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "HFS+", "-volname", volumeName, dmgPath.path])
        let attachOutput = try Self.run("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse"])
        // `hdiutil attach`'s own stdout names the real mount point -- not
        // assumed to be `/Volumes/<volumeName>` (a second volume with the
        // same name would be suffixed), so this is parsed from the tool's
        // own answer rather than constructed.
        guard let mountLine = attachOutput.split(separator: "\n").last(where: { $0.contains("/Volumes/") }),
              let tab = mountLine.range(of: "/Volumes/") else {
            throw WorkspaceError.unreadable(path: dmgPath.path, underlying: "could not parse hdiutil attach output: \(attachOutput)")
        }
        let mountPoint = URL(fileURLWithPath: String(mountLine[tab.lowerBound...]).trimmingCharacters(in: .whitespaces))
        defer {
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: dmgPath)
        }

        let projectRoot = mountPoint.appendingPathComponent("project")
        let referenceScratch = mountPoint.appendingPathComponent("reference-scratch")
        let fastPathScratch = mountPoint.appendingPathComponent("fastpath-scratch")
        try Self.writeSampleFixture(in: projectRoot)

        let referenceWorkspaces = try WorkspaceManager(
            projectRoot: projectRoot, scratchRoot: referenceScratch, cleanSubtreeCloning: false
        )
        #expect(await referenceWorkspaces.supportsAPFSClone() == false, "expected HFS+ to genuinely not support clonefile")

        let fastPathWorkspaces = try WorkspaceManager(
            projectRoot: projectRoot, scratchRoot: fastPathScratch, cleanSubtreeCloning: true
        )
        let referenceSandbox = try await referenceWorkspaces.createSandbox(id: "mut_nonapfs")
        let fastPathSandbox = try await fastPathWorkspaces.createSandbox(id: "mut_nonapfs")

        let referenceSnapshot = try Self.snapshot(at: referenceSandbox)
        let fastPathSnapshot = try Self.snapshot(at: fastPathSandbox)
        #expect(!referenceSnapshot.isEmpty)
        #expect(referenceSnapshot == fastPathSnapshot)

        let clonedLink = fastPathSandbox.appendingPathComponent("Sources/Pkg/Vendor/RelativeLink")
        let values = try clonedLink.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true, "the copyItem fallback must still preserve an internal symlink as a symlink")
    }

    /// A deliberately small fixture (compared to
    /// `WorkspaceManagerCleanSubtreeCloningTests`' own, much larger mixed
    /// fixture): this test's only job is proving the non-APFS *fallback*
    /// mechanism itself works, not re-proving every exclusion-pattern edge
    /// case the Unit suite already covers deterministically and fast.
    /// Still covers the two shapes specific to this fallback: an ordinary
    /// clean subtree (whole-directory `copyItem`) and an internal symlink
    /// inside one (must survive `copyItem`, not just `clonefile`).
    private static func writeSampleFixture(in root: URL) throws {
        let fm = FileManager.default
        func write(_ relativePath: String, _ contents: String = "x") throws {
            let url = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        try write("Package.swift", "// swift-tools-version:6.0")
        try write("Sources/Pkg/File1.swift", "let a = 1")
        try write("Sources/Pkg/Nested/File2.swift", "let b = 2")
        try write("Tests/PkgTests/Test1.swift", "// tests")
        try write(".git/HEAD", "ref: refs/heads/main")

        let linkURL = root.appendingPathComponent("Sources/Pkg/Vendor/RelativeLink")
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "../File1.swift")
    }

    private enum EntryKind: Hashable {
        case file(Data)
        case symlink(target: String)
        case directory
    }

    private struct Entry: Hashable {
        let relativePath: String
        let kind: EntryKind
    }

    /// Same definition as `WorkspaceManagerCleanSubtreeCloningTests
    /// .CleanSubtreeCloningFixture.snapshot(at:)` (duplicated rather than
    /// shared across a Unit/Acceptance boundary, deliberately: this
    /// suite's only dependency on the Unit suite should be the same
    /// *behaviour*, not the same code, so a change to one can never
    /// silently change what the other proves) -- content and relative
    /// layout only, not POSIX permission bits.
    private static func snapshot(at root: URL) throws -> Set<Entry> {
        var result: Set<Entry> = []
        let fm = FileManager.default
        func walk(_ dir: URL, relative: String) throws {
            let entries = try fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
            )
            for entry in entries {
                let name = entry.lastPathComponent
                let rel = relative.isEmpty ? name : relative + "/" + name
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let target = try fm.destinationOfSymbolicLink(atPath: entry.path)
                    result.insert(Entry(relativePath: rel, kind: .symlink(target: target)))
                } else if values.isDirectory == true {
                    result.insert(Entry(relativePath: rel, kind: .directory))
                    try walk(entry, relative: rel)
                } else {
                    result.insert(Entry(relativePath: rel, kind: .file(try Data(contentsOf: entry))))
                }
            }
        }
        try walk(root, relative: "")
        return result
    }

    /// Runs an external tool synchronously, returns its stdout, and throws
    /// if it exits non-zero -- used only to drive `hdiutil` above.
    @discardableResult
    private static func run(_ executablePath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()
        let outputText = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw WorkspaceError.unwritable(
                path: arguments.joined(separator: " "),
                underlying: "\(executablePath) exited \(process.terminationStatus): \(errorText)"
            )
        }
        return outputText
    }
}
