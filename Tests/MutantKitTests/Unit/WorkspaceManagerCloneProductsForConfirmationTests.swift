import Foundation
import MutationExecution
import Testing

/// Coverage for `WorkspaceManager.cloneProductsForConfirmation(from:id:)` —
/// the sibling of `cloneProducts` that nests its clone under
/// `<destination>/<triple>/<configuration>/` instead of flattening it
/// directly into `destination`.
///
/// Root cause this exists to fix: `SwiftPackageMacOSAdapter`'s confirmation
/// retest (`Configuration.execution.retestKilledMutants`) runs `swift test
/// --skip-build --scratch-path <clone>`, and `--scratch-path` does not
/// accept a flat products directory — confirmed empirically against a real
/// toolchain (see `Research/product-completeness-2026-08
/// /F7-A-E-FREEZE-RELEASE-GATE.md`) — it computes its own triple/
/// configuration internally and looks for pre-built products nested under
/// exactly that shape beneath whatever `--scratch-path` it is given.
@Suite("WorkspaceManager: cloneProductsForConfirmation")
struct WorkspaceManagerCloneProductsForConfirmationTests {
    private let projectRoot: URL = Self.makeTempDir(prefix: "mutantkit-confirm-clone-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-confirm-clone-scratch")

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// A products directory shaped like a real SwiftPM `.build/<triple>
    /// /<configuration>` -- the resolved directory `cloneProductsForConfirmation`
    /// reads its own `<triple>`/`<configuration>` off of.
    private func makeFakeProductsDirectory(
        triple: String = "arm64-apple-macosx", configuration: String = "debug"
    ) throws -> URL {
        let buildDir = projectRoot.appendingPathComponent(".build-\(UUID().uuidString)")
        let products = buildDir.appendingPathComponent("\(triple)/\(configuration)")
        let bundle = products.appendingPathComponent("Fake.xctest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("binary-bytes".utf8).write(to: bundle.appendingPathComponent("Fake"))
        return products
    }

    @Test("The clone is nested under <destination>/<triple>/<configuration>, not flattened")
    func cloneIsNestedUnderTripleAndConfiguration() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory(triple: "arm64-apple-macosx", configuration: "debug")

        let destination = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_a")

        let nestedBinary = destination
            .appendingPathComponent("arm64-apple-macosx/debug/Fake.xctest/Fake")
        #expect(FileManager.default.fileExists(atPath: nestedBinary.path))
        #expect(try Data(contentsOf: nestedBinary) == Data("binary-bytes".utf8))

        // Never flattened directly into the destination root the way
        // `cloneProducts` would -- that shape is exactly what `swift test
        // --scratch-path` cannot resolve pre-built products from.
        let flatBinary = destination.appendingPathComponent("Fake.xctest/Fake")
        #expect(!FileManager.default.fileExists(atPath: flatBinary.path))
    }

    @Test("The triple and configuration are read off the resolved source path, not hardcoded")
    func tripleAndConfigurationAreReadFromTheSourcePath() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory(triple: "x86_64-apple-macosx", configuration: "release")

        let destination = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_release")

        let nestedBinary = destination
            .appendingPathComponent("x86_64-apple-macosx/release/Fake.xctest/Fake")
        #expect(FileManager.default.fileExists(atPath: nestedBinary.path))
    }

    /// SwiftPM's own products directory shape: `.build/debug` is not a real
    /// directory, always a *relative* symlink to `.build/<triple>/debug` —
    /// the same top-level-symlink case `cloneProducts`' own regression test
    /// covers, exercised here too since this function resolves the source
    /// the identical way, before deriving `<triple>`/`<configuration>` from
    /// it.
    @Test("A products directory that is itself a relative symlink (SwiftPM's `.build/debug`) clones as a real, nested directory")
    func clonesThroughATopLevelRelativeSymlinkCorrectly() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        let buildDir = projectRoot.appendingPathComponent(".build-\(UUID().uuidString)")
        let realProducts = buildDir.appendingPathComponent("arm64-apple-macosx/debug")
        let bundle = realProducts.appendingPathComponent("Fake.xctest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("binary-bytes".utf8).write(to: bundle.appendingPathComponent("Fake"))

        let debugSymlink = buildDir.appendingPathComponent("debug")
        try FileManager.default.createSymbolicLink(
            atPath: debugSymlink.path, withDestinationPath: "arm64-apple-macosx/debug"
        )

        let destination = try await workspaces.cloneProductsForConfirmation(from: debugSymlink, id: "mut_symlinked")

        let nestedBinary = destination.appendingPathComponent("arm64-apple-macosx/debug/Fake.xctest/Fake")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try Data(contentsOf: nestedBinary) == Data("binary-bytes".utf8))
    }

    @Test("The clone destination is deterministic per id and distinct across ids")
    func destinationIsDeterministicAndDistinctPerID() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory()

        let first = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_a")
        try await workspaces.destroySandbox(at: first)
        let firstAgain = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_a")
        let second = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_b")

        #expect(first == firstAgain, "same id must resolve to the same path")
        #expect(first != second, "different ids must never collide")
    }

    @Test("Cloning a source directory that does not exist throws rather than producing an empty clone")
    func missingSourceThrows() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let missing = projectRoot.appendingPathComponent("does-not-exist")

        await #expect(throws: WorkspaceError.self) {
            _ = try await workspaces.cloneProductsForConfirmation(from: missing, id: "mut_missing")
        }
    }

    @Test("Re-cloning under a reused id overwrites cleanly rather than failing")
    func recloningUnderReusedIDOverwrites() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let firstProducts = try makeFakeProductsDirectory()
        try Data("first-mutant".utf8).write(to: firstProducts.appendingPathComponent("Fake.xctest/Fake"))
        _ = try await workspaces.cloneProductsForConfirmation(from: firstProducts, id: "mut_reused")

        let secondProducts = try makeFakeProductsDirectory()
        try Data("second-mutant".utf8).write(to: secondProducts.appendingPathComponent("Fake.xctest/Fake"))
        let destination = try await workspaces.cloneProductsForConfirmation(from: secondProducts, id: "mut_reused")

        let binary = destination.appendingPathComponent("arm64-apple-macosx/debug/Fake.xctest/Fake")
        #expect(try Data(contentsOf: binary) == Data("second-mutant".utf8))
    }

    @Test("destroySandbox deletes a nested confirmation clone unmodified, same as a sandbox")
    func destroySandboxDeletesAClone() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory()
        let destination = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_a")
        #expect(FileManager.default.fileExists(atPath: destination.path))

        try await workspaces.destroySandbox(at: destination)

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("cloneProducts and cloneProductsForConfirmation never collide on the same destination root")
    func flatAndNestedClonesShareTheSameDestinationNamingScheme() async throws {
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
        let products = try makeFakeProductsDirectory()

        // Same id, called through the *other* function -- `cloneProducts`
        // must not have left a flat layout behind that this nested clone
        // then silently coexists with (or vice versa): each function
        // unconditionally clears its own destination root before cloning
        // (see `cloneProductsForConfirmation`'s own doc comment), so the
        // later call wins outright, whichever it is.
        _ = try await workspaces.cloneProducts(from: products, id: "mut_shared")
        let destination = try await workspaces.cloneProductsForConfirmation(from: products, id: "mut_shared")

        let nestedBinary = destination.appendingPathComponent("arm64-apple-macosx/debug/Fake.xctest/Fake")
        #expect(FileManager.default.fileExists(atPath: nestedBinary.path))
    }
}
