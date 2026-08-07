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
