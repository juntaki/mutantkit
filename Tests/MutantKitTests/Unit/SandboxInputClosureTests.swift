@testable import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import Testing

@Suite("SandboxInputClosure: sandboxes are built from the captured inputs")
struct SandboxInputClosureTests {
    private let root: URL
    private let scratch: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SandboxInputClosure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = try #require(CanonicalPath.resolve(base.path))
        root = URL(fileURLWithPath: canonical + "/Project")
        scratch = URL(fileURLWithPath: canonical + "/scratch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ relative: String, _ text: String) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func manager(closure: SandboxInputClosure? = nil) throws -> WorkspaceManager {
        try WorkspaceManager(
            layout: .projectOnly(canonicalProjectRoot: root.path), scratchRoot: scratch, inputClosure: closure
        )
    }

    @Test("A file edited after capture, same size and mtime, fails the sandbox instead of being copied")
    func sameSizeSameMtimeEditIsRefused() async throws {
        try write("Sources/a.swift", "let x = 1")
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        let closure = try SandboxInputClosure.capture(layout: layout)
        let file = root.appendingPathComponent("Sources/a.swift")
        let mtime = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("let x = 2".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let workspaces = try manager(closure: closure)
        await #expect(throws: SandboxInputClosureError.contentChanged(path: "Sources/a.swift")) {
            _ = try await workspaces.createSandbox(id: "one")
        }
    }

    @Test("restoreFile restores the captured bytes even if the live source changed")
    func restoreFileProvesTheSource() async throws {
        try write("Sources/a.swift", "let x = 1")
        let workspaces = try manager()
        let sandbox = try await workspaces.createSandbox(id: "one")
        let copy = sandbox.workspaceRoot.appendingPathComponent("Sources/a.swift")
        try Data("mutated!!".utf8).write(to: copy)

        try await workspaces.restoreFile(relativePath: "Sources/a.swift", in: sandbox)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "let x = 1")

        // The live source changing afterwards cannot reach a restore: it comes
        // from the verified staged copy.
        try write("Sources/a.swift", "let x = 9")
        try Data("mutated!!".utf8).write(to: copy)
        try await workspaces.restoreFile(relativePath: "Sources/a.swift", in: sandbox)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "let x = 1")
    }

    @Test("A reused container drops files deleted from the source and replaces a changed type")
    func reusedContainerHoldsNoStaleEntries() async throws {
        try write("Sources/a.swift", "a")
        try write("Sources/gone.swift", "gone")
        let first = try manager()
        let sandbox = try await first.createSandbox(id: "one")
        #expect(FileManager.default.fileExists(atPath: sandbox.workspaceRoot.appendingPathComponent("Sources/gone.swift").path))

        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/gone.swift"))
        let second = try manager()
        let again = try await second.createSandbox(id: "one")
        #expect(again.workspaceRoot == sandbox.workspaceRoot)
        #expect(!FileManager.default.fileExists(atPath: again.workspaceRoot.appendingPathComponent("Sources/gone.swift").path))
    }

    @Test("Ignored generated files are part of the closure and of its digest")
    func ignoredInputsAreCovered() throws {
        try write("Sources/a.swift", "a")
        try write("Generated/Gen.swift", "v1")
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        let before = try SandboxInputClosure.capture(layout: layout)
        #expect(before.project.entry(at: "Generated/Gen.swift")?.kind == .file)
        try write("Generated/Gen.swift", "v2")
        #expect(try SandboxInputClosure.capture(layout: layout).digest != before.digest)
    }

    @Test("An unreadable entry fails capture; it is never treated as absent")
    func unreadableEntryFailsCapture() throws {
        try write("Sources/a.swift", "a")
        let file = root.appendingPathComponent("Sources/a.swift")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        #expect(throws: SandboxInputClosureError.self) { try SandboxInputClosure.capture(layout: layout) }
    }

    @Test("A snapshot source that changed or that the copy would not carry fails derivation")
    func snapshotMustMatchTheClosure() throws {
        try write("Sources/a.swift", "a")
        try write("logs/b.swift", "b")
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        let context = ResolvedInvocationContext(
            projectRoot: root, projectPath: nil,
            detection: ProjectDetection(kind: .swiftPackageMacOS, reason: "test", projectFile: nil),
            scheme: nil, resolvedDestination: nil
        )
        let ok = SourceSnapshot(files: [.init(relativePath: "Sources/a.swift", data: Data("a".utf8))])
        _ = try SandboxInputClosure.capture(context: context, layout: layout, snapshot: ok)

        let stale = SourceSnapshot(files: [.init(relativePath: "Sources/a.swift", data: Data("OLD".utf8))])
        #expect(throws: SandboxInputClosureError.snapshotMismatch(
            path: "Sources/a.swift", detail: "content differs from the planned bytes"
        )) { try SandboxInputClosure.capture(context: context, layout: layout, snapshot: stale) }

        let excluded = SourceSnapshot(files: [.init(relativePath: "logs/b.swift", data: Data("b".utf8))])
        #expect(throws: SandboxInputClosureError.self) {
            try SandboxInputClosure.capture(context: context, layout: layout, snapshot: excluded)
        }
    }

    @Test("A file swapped for a symlink to identical bytes is refused")
    func symlinkSwapIsRefused() async throws {
        try write("Sources/a.swift", "same")
        try write("Elsewhere/a.swift", "same")
        let closure = try SandboxInputClosure.capture(layout: .projectOnly(canonicalProjectRoot: root.path))
        let file = root.appendingPathComponent("Sources/a.swift")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            atPath: file.path, withDestinationPath: root.appendingPathComponent("Elsewhere/a.swift").path
        )
        let workspaces = try manager(closure: closure)
        await #expect(throws: SandboxInputClosureError.self) { _ = try await workspaces.createSandbox(id: "one") }
    }

    @Test("A symlink retargeted after capture is built from the captured target")
    func retargetedLinkUsesCapturedTarget() async throws {
        try write("Clean/a.swift", "a")
        let link = root.appendingPathComponent("Clean/link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.swift")
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        let closure = try SandboxInputClosure.capture(layout: layout)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "elsewhere")
        let workspaces = try WorkspaceManager(
            layout: layout, scratchRoot: scratch, cleanSubtreeCloning: true, inputClosure: closure
        )
        let sandbox = try await workspaces.createSandbox(id: "one")
        let copy = sandbox.workspaceRoot.appendingPathComponent("Clean/link").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy) == "a.swift")
    }

    @Test("A source edited after the first sandbox cannot reach a later one")
    func laterSandboxesCloneTheVerifiedCopy() async throws {
        try write("Sources/a.swift", "v1")
        let workspaces = try manager()
        _ = try await workspaces.createSandbox(id: "one")
        try write("Sources/a.swift", "v2")
        let later = try await workspaces.createSandbox(id: "two")
        #expect(try String(contentsOf: later.workspaceRoot.appendingPathComponent("Sources/a.swift"), encoding: .utf8) == "v1")
    }

    private static let adapterOutputs = [
        ".build/debug/x.o", ".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata",
        "Package.resolved"
    ]

    @Test("A reused SwiftPM sandbox keeps root adapter output: .build, .swiftpm and an untracked Package.resolved")
    func reuseKeepsAdapterOutput() async throws {
        try write("Package.swift", "// manifest")
        try write("Sources/a.swift", "a")
        let workspaces = try manager()
        let first = try await workspaces.createSandbox(id: "one")
        for output in Self.adapterOutputs {
            let url = first.workspaceRoot.appendingPathComponent(output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("out".utf8).write(to: url)
        }
        let again = try await workspaces.createSandbox(id: "one")
        for output in Self.adapterOutputs {
            #expect(FileManager.default.fileExists(atPath: again.workspaceRoot.appendingPathComponent(output).path), "\(output)")
        }
    }

    @Test("A closure captured for another project than the invocation resolved is refused")
    func projectMismatchIsRefused() throws {
        try write("Sources/a.swift", "a")
        let other = root.deletingLastPathComponent().appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let context = ResolvedInvocationContext(
            projectRoot: other, projectPath: nil,
            detection: ProjectDetection(kind: .swiftPackageMacOS, reason: "test", projectFile: nil),
            scheme: nil, resolvedDestination: nil
        )
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        #expect(throws: SandboxInputClosureError.self) {
            try SandboxInputClosure.capture(context: context, layout: layout, snapshot: SourceSnapshot(files: []))
        }
    }

    @Test("A directory swapped for a link is refused and nothing outside the sandbox is pruned")
    func directorySwappedForLinkDeletesNothing() async throws {
        try write("a/keep.swift", "k")
        try write("outside/precious.txt", "p")
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        let closure = try SandboxInputClosure.capture(layout: layout)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("a").path, withDestinationPath: root.appendingPathComponent("outside").path
        )
        let workspaces = try WorkspaceManager(
            layout: layout, scratchRoot: scratch, cleanSubtreeCloning: true, inputClosure: closure
        )
        await #expect(throws: SandboxInputClosureError.self) { _ = try await workspaces.createSandbox(id: "one") }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside/precious.txt").path))
    }

    @Test("An excluded entry that appears in a clean subtree after capture is not carried into the sandbox")
    func excludedEntryAfterCaptureIsPruned() async throws {
        try write("Clean/a.swift", "a")
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: root.path)
        let closure = try SandboxInputClosure.capture(layout: layout)
        try write("Clean/.build/x.o", "obj")
        let workspaces = try WorkspaceManager(
            layout: layout, scratchRoot: scratch, cleanSubtreeCloning: true, inputClosure: closure
        )
        let sandbox = try await workspaces.createSandbox(id: "one")
        #expect(!FileManager.default.fileExists(atPath: sandbox.workspaceRoot.appendingPathComponent("Clean/.build").path))
    }

    @Test("Resolution state is retained only at the package root and only when the closure lacks it")
    func retentionIsRootRelativeAndYieldsToTheClosure() async throws {
        try write("Package.swift", "// manifest")
        try write("Package.resolved", "pinned")
        try write("Sources/a.swift", "a")
        let first = try await manager().createSandbox(id: "one")
        let nested = first.workspaceRoot.appendingPathComponent("Sources/Package.resolved")
        try Data("stray".utf8).write(to: nested)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Package.resolved"))
        let again = try await manager().createSandbox(id: "one")
        #expect(!FileManager.default.fileExists(atPath: again.workspaceRoot.appendingPathComponent("Package.resolved").path))
        #expect(!FileManager.default.fileExists(atPath: again.workspaceRoot.appendingPathComponent("Sources/Package.resolved").path))
    }

    @Test("Two managers on one scratch root do not disturb each other's staged inputs")
    func managersStageIndependently() async throws {
        try write("Sources/a.swift", "v1")
        let first = try manager()
        let sandbox = try await first.createSandbox(id: "one")
        try write("Sources/a.swift", "v2")
        let second = try manager()
        _ = try await second.createSandbox(id: "two")
        #expect(first.stagingRoot != second.stagingRoot)

        let copy = sandbox.workspaceRoot.appendingPathComponent("Sources/a.swift")
        try Data("mutated".utf8).write(to: copy)
        try await first.restoreFile(relativePath: "Sources/a.swift", in: sandbox)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "v1")
    }

    @Test("A staged file modified after verification is refused, by restore and by later sandboxes")
    func tamperedStagingIsRefused() async throws {
        try write("Sources/a.swift", "v1")
        let workspaces = try manager()
        let sandbox = try await workspaces.createSandbox(id: "one")
        let staged = workspaces.stagingRoot.appendingPathComponent("Sources/a.swift")
        try Data("evil".utf8).write(to: staged)

        await #expect(throws: SandboxInputClosureError.self) {
            try await workspaces.restoreFile(relativePath: "Sources/a.swift", in: sandbox)
        }
        await #expect(throws: SandboxInputClosureError.self) { _ = try await workspaces.createSandbox(id: "two") }
    }

    @Test("A source that vanished between capture and the first sandbox is refused")
    func vanishedSourceIsRefused() async throws {
        try write("Sources/a.swift", "a")
        try write("Sources/b.swift", "b")
        let closure = try SandboxInputClosure.capture(layout: .projectOnly(canonicalProjectRoot: root.path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/b.swift"))
        let workspaces = try manager(closure: closure)
        await #expect(throws: SandboxInputClosureError.contentChanged(path: "Sources/b.swift")) {
            _ = try await workspaces.createSandbox(id: "one")
        }
    }

    @Test("A read-only source directory is staged, copied and cleaned up")
    func readOnlyDirectoryWorks() async throws {
        try write("Vendor/lib.swift", "x")
        let vendor = root.appendingPathComponent("Vendor")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vendor.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendor.path) }
        var staging: URL?
        do {
            let workspaces = try manager()
            staging = workspaces.stagingRoot
            let sandbox = try await workspaces.createSandbox(id: "one")
            #expect(FileManager.default.fileExists(atPath: sandbox.workspaceRoot.appendingPathComponent("Vendor/lib.swift").path))
            #expect(FileManager.default.fileExists(atPath: workspaces.stagingRoot.path))
        }
        // Staging goes with its manager.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: try #require(staging).path))
    }
}
