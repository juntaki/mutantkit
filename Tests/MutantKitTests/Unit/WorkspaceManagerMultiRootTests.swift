import Foundation
@testable import MutationExecution
import Testing

/// Sandboxes built from a layout with external roots: every root copied to
/// its relative position in the container, each with the same excludes,
/// and the container created, reused and destroyed as one unit.
@Suite("WorkspaceManager: sandboxes over several roots")
struct WorkspaceManagerMultiRootTests {
    // MARK: - Placement

    @Test("The project and each external root are copied to their relative positions in the container")
    func rootsAreCopiedToTheirRelativePositions() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Apps/Core/Package.swift")
        try tree.write("Libraries/SwiftMapper/Package.swift")
        try tree.write("Libraries/SwiftMapper/Sources/SwiftMapper/Mapper.swift")
        try tree.write("Libraries/Unrelated/Package.swift")

        let workspaces = try tree.workspaces(project: "Apps/Core", packages: ["Libraries/SwiftMapper"])
        let sandbox = try await workspaces.createSandbox(id: "baseline")

        #expect(sandbox.containerRoot.deletingLastPathComponent().lastPathComponent == "sandboxes")
        #expect(sandbox.containerRoot.lastPathComponent == WorkspaceManager.directoryName(for: "baseline"))
        #expect(sandbox.workspaceRoot.path == sandbox.containerRoot.path + "/Apps/Core")
        #expect(Self.exists(sandbox.workspaceRoot, "Package.swift"))
        #expect(Self.exists(sandbox.containerRoot, "Libraries/SwiftMapper/Sources/SwiftMapper/Mapper.swift"))
        // Only the layout's own paths: no sibling content outside it.
        #expect(try Self.names(sandbox.containerRoot) == ["Apps", "Libraries"])
        #expect(try Self.names(sandbox.containerRoot.appendingPathComponent("Apps")) == ["Core"])
        #expect(try Self.names(sandbox.containerRoot.appendingPathComponent("Libraries")) == ["SwiftMapper"])
    }

    // MARK: - Scratch root and module cache

    @Test("The scratch root and module cache of a nested workspace are found below the scratch root, not in the container")
    func nestedWorkspaceFindsItsScratchRoot() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Apps/Core/Package.swift")
        try tree.write("Libraries/SwiftMapper/Package.swift")

        let layout = try tree.layout(project: "Apps/Core", packages: ["Libraries/SwiftMapper"])
        let workspaces = try tree.workspaces(project: "Apps/Core", packages: ["Libraries/SwiftMapper"])
        let sandbox = try await workspaces.createSandbox(id: "baseline")

        let scratchRoot = try layout.scratchRoot(ofWorkspace: sandbox.workspaceRoot)
        #expect(scratchRoot.path == sandbox.containerRoot.deletingLastPathComponent().path)
        #expect(try layout.containerName(ofWorkspace: sandbox.workspaceRoot) == WorkspaceManager.directoryName(for: "baseline"))
        let cache = WorkspaceManager.moduleCachePath(underScratchRoot: scratchRoot, fingerprint: "cafef00d")
        #expect(cache.deletingLastPathComponent().path == sandbox.containerRoot.deletingLastPathComponent().path)
    }

    @Test("A flat workspace's scratch root is its parent, as before")
    func flatWorkspaceFindsItsScratchRoot() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")

        let layout = try tree.layout(packages: [])
        let workspaces = try tree.workspaces(packages: [])
        let sandbox = try await workspaces.createSandbox(id: "baseline")

        #expect(sandbox.workspaceRoot == sandbox.containerRoot)
        #expect(try layout.scratchRoot(ofWorkspace: sandbox.workspaceRoot).path == sandbox.containerRoot.deletingLastPathComponent().path)
    }

    // MARK: - Excludes

    @Test("Excludes apply inside external roots, relative to each root; .swiftpm is still copied")
    func excludesApplyInsideExternalRoots() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("SwiftMapper/Package.swift")
        try tree.write("SwiftMapper/.build/debug/stale.o")
        try tree.write("SwiftMapper/.git/HEAD")
        try tree.write("SwiftMapper/Sources/SwiftMapper/build.log")
        try tree.write("SwiftMapper/.swiftpm/configuration/registries.json")

        let workspaces = try tree.workspaces(packages: ["SwiftMapper"])
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let mapper = sandbox.containerRoot.appendingPathComponent("SwiftMapper")

        #expect(Self.exists(mapper, "Package.swift"))
        #expect(!Self.exists(mapper, ".build"))
        #expect(!Self.exists(mapper, ".git"))
        #expect(!Self.exists(mapper, "Sources/SwiftMapper/build.log"))
        #expect(Self.exists(mapper, ".swiftpm/configuration/registries.json"))
    }

    @Test("Custom excludes reach external roots too")
    func customExcludesApplyInsideExternalRoots() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("Core/Fixtures/big.bin")
        try tree.write("SwiftMapper/Package.swift")
        try tree.write("SwiftMapper/Fixtures/big.bin")

        let workspaces = try tree.workspaces(packages: ["SwiftMapper"], excludes: ["Fixtures"])
        let sandbox = try await workspaces.createSandbox(id: "baseline")

        #expect(!Self.exists(sandbox.workspaceRoot, "Fixtures"))
        #expect(!Self.exists(sandbox.containerRoot, "SwiftMapper/Fixtures"))
        #expect(Self.exists(sandbox.containerRoot, "SwiftMapper/Package.swift"))
    }

    /// A predictable `scratch/sbx_<digest>` that already exists as a symlink
    /// must never be pruned or filled: both would act on the link's target.
    @Test("A container that is a symbolic link is refused, and its target is left untouched")
    func symlinkedContainerIsRefused() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("SwiftMapper/Package.swift")
        let outside = URL(fileURLWithPath: tree.root).appendingPathComponent("Outside")
        try tree.write(at: URL(fileURLWithPath: tree.root), "Outside/keep.txt")
        let scratch = URL(fileURLWithPath: tree.root).appendingPathComponent("Core/.mutantkit/sandboxes")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scratch.appendingPathComponent(WorkspaceManager.directoryName(for: "baseline")),
            withDestinationURL: outside
        )

        let workspaces = try tree.workspaces(packages: ["SwiftMapper"])
        await #expect(throws: WorkspaceError.self) {
            _ = try await workspaces.createSandbox(id: "baseline")
        }

        #expect(Self.exists(outside, "keep.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    }

    /// The clean-subtree index is keyed on project-relative paths. Consulted
    /// for an external root, `Sources` would be judged by the project's
    /// `Sources` and cloned whole, excluded files included.
    @Test("External roots never take the clean-subtree clone, which is judged on project paths")
    func cleanSubtreeIndexIsNotUsedForExternalRoots() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("Core/Sources/Core/Core.swift")
        try tree.write("SwiftMapper/Package.swift")
        try tree.write("SwiftMapper/Sources/SwiftMapper/Mapper.swift")
        try tree.write("SwiftMapper/Sources/SwiftMapper/build.log")

        let workspaces = try tree.workspaces(packages: ["SwiftMapper"], cleanSubtreeCloning: true)
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let mapper = sandbox.containerRoot.appendingPathComponent("SwiftMapper")

        #expect(Self.exists(sandbox.workspaceRoot, "Sources/Core/Core.swift"))
        #expect(Self.exists(mapper, "Sources/SwiftMapper/Mapper.swift"))
        #expect(!Self.exists(mapper, "Sources/SwiftMapper/build.log"))
    }

    // MARK: - Reuse

    @Test("A reused container loses entries that are no longer on a layout path")
    func reusedContainerIsPruned() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Apps/Core/Package.swift")
        try tree.write("Libraries/SwiftMapper/Package.swift")

        let workspaces = try tree.workspaces(project: "Apps/Core", packages: ["Libraries/SwiftMapper"])
        let first = try await workspaces.createSandbox(id: "baseline")
        // What a previous run with another dependency would have left.
        try tree.write(at: first.containerRoot, "Libraries/Logging/Package.swift")
        try tree.write(at: first.containerRoot, "Leftover/Package.swift")
        try tree.write(at: first.containerRoot, "stray.txt")
        try tree.write(at: first.containerRoot, "Apps/Other/file")
        // State inside a root copy is the build's, and stays.
        try tree.write(at: first.workspaceRoot, ".build/debug/kept.o")

        let second = try await workspaces.createSandbox(id: "baseline")

        #expect(second == first)
        #expect(try Self.names(second.containerRoot) == ["Apps", "Libraries"])
        #expect(try Self.names(second.containerRoot.appendingPathComponent("Apps")) == ["Core"])
        #expect(try Self.names(second.containerRoot.appendingPathComponent("Libraries")) == ["SwiftMapper"])
        #expect(Self.exists(second.workspaceRoot, ".build/debug/kept.o"))
    }

    /// An interrupted run leaves its container behind, and the next run
    /// reuses it. A file deleted from a local package since then must not
    /// survive in the copy, where the build would still compile it.
    @Test("A reused container's external root copies hold only what the packages hold now")
    func reusedExternalRootCopiesDropDeletedFiles() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Apps/Core/Package.swift")
        try tree.write("Libraries/SwiftMapper/Package.swift")
        try tree.write("Libraries/SwiftMapper/Sources/SwiftMapper/Mapper.swift")
        try tree.write("Libraries/SwiftMapper/Sources/SwiftMapper/Old.swift")

        let workspaces = try tree.workspaces(project: "Apps/Core", packages: ["Libraries/SwiftMapper"])
        let first = try await workspaces.createSandbox(id: "baseline")
        #expect(Self.exists(first.containerRoot, "Libraries/SwiftMapper/Sources/SwiftMapper/Old.swift"))

        try FileManager.default.removeItem(at: tree.url("Libraries/SwiftMapper/Sources/SwiftMapper/Old.swift"))
        let second = try await workspaces.createSandbox(id: "baseline")

        #expect(second == first)
        #expect(!Self.exists(second.containerRoot, "Libraries/SwiftMapper/Sources/SwiftMapper/Old.swift"))
        #expect(Self.exists(second.containerRoot, "Libraries/SwiftMapper/Sources/SwiftMapper/Mapper.swift"))
    }

    @Test("A reused project-only sandbox is not pruned: it is the project copy itself")
    func projectOnlySandboxIsNotPruned() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")

        let workspaces = try tree.workspaces(packages: [])
        let first = try await workspaces.createSandbox(id: "baseline")
        #expect(first.workspaceRoot == first.containerRoot)
        try tree.write(at: first.workspaceRoot, "Generated/output.swift")

        let second = try await workspaces.createSandbox(id: "baseline")

        #expect(Self.exists(second.workspaceRoot, "Generated/output.swift"))
    }

    // MARK: - Destruction

    @Test("destroySandbox removes the container with every copy in it")
    func destroyRemovesTheContainer() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("SwiftMapper/Package.swift")

        let workspaces = try tree.workspaces(packages: ["SwiftMapper"])
        let kept = try await workspaces.createSandbox(id: "mut_kept")
        let sandbox = try await workspaces.createSandbox(id: "mut_destroyed")

        try await workspaces.destroySandbox(sandbox)

        #expect(!FileManager.default.fileExists(atPath: sandbox.containerRoot.path))
        #expect(Self.exists(kept.containerRoot, "SwiftMapper/Package.swift"))
        #expect(Self.exists(tree.url("SwiftMapper"), "Package.swift"))
    }

    /// What `reproduce` and `dry-run` do before building: an earlier
    /// attempt's container may hold mutated sources and stale package
    /// copies, and none of it may be reused.
    @Test("destroyExistingSandbox removes a stale container, external copies included, and tolerates none")
    func destroyExistingSandboxRemovesStaleContainer() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("SwiftMapper/Package.swift")

        let workspaces = try tree.workspaces(packages: ["SwiftMapper"])
        let stale = try await workspaces.createSandbox(id: "mut_reproduced")
        try tree.write(at: stale.containerRoot, "SwiftMapper/Sources/Stale.swift")
        try tree.write(at: stale.workspaceRoot, "Sources/Mutated.swift")

        try await workspaces.destroyExistingSandbox(id: "mut_reproduced")
        #expect(!FileManager.default.fileExists(atPath: stale.containerRoot.path))

        try await workspaces.destroyExistingSandbox(id: "mut_reproduced")
        let fresh = try await workspaces.createSandbox(id: "mut_reproduced")
        #expect(fresh == stale)
        #expect(!Self.exists(fresh.containerRoot, "SwiftMapper/Sources/Stale.swift"))
        #expect(!Self.exists(fresh.workspaceRoot, "Sources/Mutated.swift"))
        #expect(Self.exists(fresh.containerRoot, "SwiftMapper/Package.swift"))
    }

    @Test("destroyProductsClone removes a products clone and refuses a sandbox container")
    func destroyProductsCloneOnlyTakesProductsClones() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("SwiftMapper/Package.swift")
        let workspaces = try tree.workspaces(packages: ["SwiftMapper"])
        let sandbox = try await workspaces.createSandbox(id: "mut_built")
        try tree.write(at: sandbox.workspaceRoot, ".build/debug/Product.o")
        let clone = try await workspaces.cloneProducts(
            from: sandbox.workspaceRoot.appendingPathComponent(".build/debug"), id: "mut_built"
        )

        await #expect(throws: WorkspaceError.self) {
            try await workspaces.destroyProductsClone(at: sandbox.containerRoot)
        }
        #expect(FileManager.default.fileExists(atPath: sandbox.containerRoot.path))

        try await workspaces.destroyProductsClone(at: clone)
        #expect(!FileManager.default.fileExists(atPath: clone.path))
    }

    @Test("destroySandbox refuses a container that is not one sbx_ directory directly below the scratch root")
    func destroyRefusesForeignContainers() async throws {
        let tree = try MultiRootTree()
        defer { tree.remove() }
        try tree.write("Core/Package.swift")
        try tree.write("SwiftMapper/Package.swift")
        let workspaces = try tree.workspaces(packages: ["SwiftMapper"])
        let real = try await workspaces.createSandbox(id: "mut_real")
        try tree.write("elsewhere/sbx_0123/file")
        try tree.write(at: tree.scratch, "prd_0123/file")

        let foreign = [
            // The workspace of a nested layout, passed as a container.
            real.containerRoot.appendingPathComponent("Core"),
            tree.scratch,
            tree.scratch.appendingPathComponent("prd_0123"),
            tree.url("elsewhere/sbx_0123")
        ]
        for container in foreign {
            await #expect(throws: WorkspaceError.self, "\(container.path)") {
                try await workspaces.destroySandbox(Sandbox(containerRoot: container, workspaceRoot: container))
            }
            #expect(FileManager.default.fileExists(atPath: container.path), "\(container.path)")
        }
    }

    // MARK: - Support

    private static func exists(_ base: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent(relative).path)
    }

    private static func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

/// A canonical temporary directory holding a project and its packages.
private struct MultiRootTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceManagerMultiRootTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try #require(CanonicalPath.resolve(base.path))
    }

    var scratch: URL {
        url("Core/.mutantkit/sandboxes")
    }

    func url(_ relative: String) -> URL {
        URL(fileURLWithPath: root + "/" + relative)
    }

    func write(_ relative: String) throws {
        try write(at: URL(fileURLWithPath: root), relative)
    }

    func write(at base: URL, _ relative: String) throws {
        let file = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(relative.utf8).write(to: file)
    }

    func layout(
        project: String = "Core", packages: [String], excludes: [String] = WorkspaceManager.defaultExcludes
    ) throws -> SandboxLayout {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: url(project).path,
            localPackages: packages.map {
                LocalPackageRoot(reportedPath: url($0).path, canonicalPath: url($0).path, declaredBy: url(project).path)
            }
        )
        try SandboxExternalRootValidator.validate(
            layout: layout, excludes: excludes, scratchRoot: url(project + "/.mutantkit/sandboxes")
        )
        return layout
    }

    func workspaces(
        project: String = "Core",
        packages: [String],
        excludes: [String] = WorkspaceManager.defaultExcludes,
        cleanSubtreeCloning: Bool = false
    ) throws -> WorkspaceManager {
        try WorkspaceManager(
            layout: layout(project: project, packages: packages, excludes: excludes),
            scratchRoot: url(project + "/.mutantkit/sandboxes"),
            excludes: excludes,
            cleanSubtreeCloning: cleanSubtreeCloning
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
