import Foundation
import MutationExecution
import Testing

/// Coverage for `WorkspaceManager.cloneProducts(from:id:)` — the mechanism
/// that lets a persistent, reused incremental-build sandbox (see
/// `Configuration.execution.incrementalBuild`) hand off a just-built
/// products directory before its own `DerivedData` gets overwritten by the
/// next mutant's build, so a later batch (see `Configuration.execution
/// .testBatchSize`) can still test it.
@Suite("WorkspaceManager: cloneProducts")
struct WorkspaceManagerCloneProductsTests {
    private let projectRoot: URL = Self.makeTempDir(prefix: "mutantkit-clone-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-clone-scratch")

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// A products directory shaped like a real one: an `.xctestrun` sitting
    /// beside a bundle it references by relative name, plus a nested file
    /// inside that bundle — enough to prove a clone preserves both file
    /// content and the internal relative layout `BatchXCTestRunBuilder`
    /// depends on, not just a flat file or two.
    private func makeFakeProductsDirectory() throws -> URL {
        let products = projectRoot.appendingPathComponent("Products-\(UUID().uuidString)")
        let bundle = products.appendingPathComponent("Fake.xctest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("binary-bytes".utf8).write(to: bundle.appendingPathComponent("Fake"))
        try Data("<plist>__TESTROOT__/Fake.xctest</plist>".utf8)
            .write(to: products.appendingPathComponent("Fake.xctestrun"))
        return products
    }

    @Test("A clone reproduces file bytes and internal relative layout exactly")
    func clonePreservesBytesAndLayout() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory()

        let clone = try await workspaces.cloneProducts(from: products, id: "mut_a")

        let xctestrun = clone.appendingPathComponent("Fake.xctestrun")
        let binary = clone.appendingPathComponent("Fake.xctest/Fake")
        #expect(FileManager.default.fileExists(atPath: xctestrun.path))
        #expect(FileManager.default.fileExists(atPath: binary.path))
        #expect(try Data(contentsOf: xctestrun) == Data("<plist>__TESTROOT__/Fake.xctest</plist>".utf8))
        #expect(try Data(contentsOf: binary) == Data("binary-bytes".utf8))
    }

    @Test("The clone destination is deterministic per id and distinct across ids")
    func destinationIsDeterministicAndDistinctPerID() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory()

        let first = try await workspaces.cloneProducts(from: products, id: "mut_a")
        try await workspaces.destroySandbox(at: first)
        let firstAgain = try await workspaces.cloneProducts(from: products, id: "mut_a")
        let second = try await workspaces.cloneProducts(from: products, id: "mut_b")

        #expect(first == firstAgain, "same id must resolve to the same path")
        #expect(first != second, "different ids must never collide")
    }

    @Test("Cloning a source directory that does not exist throws rather than producing an empty clone")
    func missingSourceThrows() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let missing = projectRoot.appendingPathComponent("does-not-exist")

        await #expect(throws: WorkspaceError.self) {
            _ = try await workspaces.cloneProducts(from: missing, id: "mut_missing")
        }
    }

    @Test("Re-cloning under a reused id overwrites cleanly rather than failing")
    func recloningUnderReusedIDOverwrites() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let firstProducts = try makeFakeProductsDirectory()
        try Data("first-mutant".utf8).write(to: firstProducts.appendingPathComponent("Fake.xctest/Fake"))
        _ = try await workspaces.cloneProducts(from: firstProducts, id: "mut_reused")

        let secondProducts = try makeFakeProductsDirectory()
        try Data("second-mutant".utf8).write(to: secondProducts.appendingPathComponent("Fake.xctest/Fake"))
        let clone = try await workspaces.cloneProducts(from: secondProducts, id: "mut_reused")

        let binary = clone.appendingPathComponent("Fake.xctest/Fake")
        #expect(try Data(contentsOf: binary) == Data("second-mutant".utf8))
    }

    /// SwiftPM's own products directory shape: `.build/debug` is not a real
    /// directory, always a *relative* symlink to `.build/<triple>/debug`
    /// (`arm64-apple-macosx/debug`, here). A real regression found via
    /// `SchemataConfirmationDifferentialAcceptanceTests`'s own isolated-
    /// backend confirmation retest: cloning that symlink with
    /// `CLONE_NOFOLLOW` (correct for a symlink found *inside* a cloned tree,
    /// see `populate`'s own doc comment) recreated the same relative link
    /// text at the clone's destination — which resolved to a sibling
    /// directory that was never cloned, since only the products directory
    /// itself is cloned out, not `.build` as a whole. The clone looked
    /// populated (`fileExists` on the symlink itself succeeds) but every
    /// path inside it was unreachable — surfacing downstream as a raw
    /// `posix_spawn`-level launch failure (`chdir` into a dangling symlink)
    /// with no obvious connection to a clone gone wrong.
    @Test("A products directory that is itself a relative symlink (SwiftPM's `.build/debug`) clones as a real, independent directory")
    func clonesThroughATopLevelRelativeSymlinkCorrectly() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        let buildDir = projectRoot.appendingPathComponent(".build-\(UUID().uuidString)")
        let realProducts = buildDir.appendingPathComponent("arm64-apple-macosx/debug")
        let bundle = realProducts.appendingPathComponent("Fake.xctest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("binary-bytes".utf8).write(to: bundle.appendingPathComponent("Fake"))

        // A *relative* symlink, exactly as SwiftPM creates `.build/debug`:
        // `arm64-apple-macosx/debug`, relative to `.build` itself — the
        // shape that breaks if the clone destination is anywhere else.
        let debugSymlink = buildDir.appendingPathComponent("debug")
        try FileManager.default.createSymbolicLink(
            atPath: debugSymlink.path, withDestinationPath: "arm64-apple-macosx/debug"
        )

        let clone = try await workspaces.cloneProducts(from: debugSymlink, id: "mut_symlinked")

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: clone.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the clone destination must be a real, independent directory, not another dangling symlink")
        let binary = clone.appendingPathComponent("Fake.xctest/Fake")
        #expect(try Data(contentsOf: binary) == Data("binary-bytes".utf8))
    }

    @Test("destroySandbox deletes a products clone unmodified, same as a sandbox")
    func destroySandboxDeletesAClone() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory()
        let clone = try await workspaces.cloneProducts(from: products, id: "mut_a")
        #expect(FileManager.default.fileExists(atPath: clone.path))

        try await workspaces.destroySandbox(at: clone)

        #expect(!FileManager.default.fileExists(atPath: clone.path))
    }
}
