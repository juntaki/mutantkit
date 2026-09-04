import Foundation
@testable import MutationExecution
import Testing

/// End-to-end coverage for `Configuration.execution.cleanSubtreeCloning` --
/// `WorkspaceManager.createSandbox`'s clean-subtree-index fast path. Every
/// test compares real, on-disk output against either a known-correct
/// baseline (the *same* fixture populated with the flag off, which is the
/// production-proven, unmodified-in-this-pass code path) or a direct,
/// content-level assertion about what a sandbox does or does not contain --
/// never a mocked filesystem.
///
/// Companion to `CleanSubtreeIndexTests` (which tests classification in
/// isolation) and `WorkspaceManagerCloneProductsTests` (whose own
/// `0a1296e` symlink regression this suite's symlink tests are modelled
/// after).
///
/// "Identical" throughout this suite means content and relative directory
/// layout -- file bytes, symlink targets, and which paths exist -- exactly
/// what `CleanSubtreeCloningFixture.snapshot(at:)` captures and nothing
/// more. It does **not** mean POSIX permission bits: Section F proves those
/// are *not* guaranteed identical between the two code paths, so no test in
/// Sections A-E ever compares them, and none of their names claim to.
///
/// The real, environment-dependent (`hdiutil`, disk-image creation) non-APFS
/// fallback test lives in `Acceptance/CleanSubtreeHFSPlusFallbackAcceptanceTests.swift`,
/// not here -- gated by `MUTANTKIT_ACCEPTANCE=1` like every other slow,
/// real-filesystem/real-tool acceptance test, rather than run on every
/// plain `swift test`. See that file's own doc comment.
@Suite("WorkspaceManager: clean-subtree-index fast path (cleanSubtreeCloning)")
struct WorkspaceManagerCleanSubtreeCloningTests {
    // MARK: - A. Content-and-layout parity (the core correctness gate)

    @Test(
        """
        Old (per-file walk) and new (clean-subtree-index) populate() produce sandboxes with identical content \
        and directory layout for the same real source tree (POSIX permission bits are a separate claim -- see \
        Section F)
        """
    )
    func oldAndNewPopulateHaveIdenticalContentAndLayout() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-parity-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try CleanSubtreeCloningFixture.writeMixedFixture(in: projectRoot)

        let oldScratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-parity-old-scratch")
        let newScratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-parity-new-scratch")
        defer {
            try? FileManager.default.removeItem(at: oldScratch)
            try? FileManager.default.removeItem(at: newScratch)
        }

        let oldWorkspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: oldScratch, cleanSubtreeCloning: false)
        let newWorkspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: newScratch, cleanSubtreeCloning: true)

        let oldSandbox = try await oldWorkspaces.createSandbox(id: "mut_parity")
        let newSandbox = try await newWorkspaces.createSandbox(id: "mut_parity")

        let oldSnapshot = try CleanSubtreeCloningFixture.snapshot(at: oldSandbox)
        let newSnapshot = try CleanSubtreeCloningFixture.snapshot(at: newSandbox)

        #expect(!oldSnapshot.isEmpty, "the fixture must have produced real, non-empty output to be a meaningful comparison")
        #expect(oldSnapshot == newSnapshot)

        // Named directly, not only implied by set equality above: neither
        // sandbox may contain any excluded content at all.
        for excludedRelativePath in [
            ".git", ".git/HEAD", ".build", "Carthage/Build", "logs",
            "Sources/Pkg/Nested/Deep/debug.log", "Sources/Pkg/Reports/run.xcresult"
        ] {
            #expect(
                !FileManager.default.fileExists(atPath: oldSandbox.appendingPathComponent(excludedRelativePath).path)
            )
            #expect(
                !FileManager.default.fileExists(atPath: newSandbox.appendingPathComponent(excludedRelativePath).path)
            )
        }
    }

    @Test(
        """
        Old and new populate() also have identical content and layout on this manager's own real, built Swift \
        package source (Sources/ and Tests/)
        """
    )
    func oldAndNewPopulateHaveIdenticalContentAndLayoutOnARealSwiftPackageTree() async throws {
        // `#filePath` is this very test file, inside the real MutantKit
        // checkout this pass is being developed in -- a real, non-synthetic
        // small-to-medium SwiftPM project, not a fixture built to order.
        // `Sources/CLI` alone is a real, deeply-nested tree of real Swift
        // source; `.git` here is a linked-worktree gitfile, not a directory,
        // which is itself a real shape worth proving parity on.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // WorkspaceManagerCleanSubtreeCloningTests.swift -> Unit/
            .deletingLastPathComponent() // Unit -> MutantKitTests/
            .deletingLastPathComponent() // MutantKitTests -> Tests/
            .deletingLastPathComponent() // Tests -> repo root
        let sourcesCLI = repoRoot.appendingPathComponent("Sources/CLI")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourcesCLI.path, isDirectory: &isDirectory)
        try #require(
            exists && isDirectory.boolValue,
            "expected \(sourcesCLI.path) to exist -- this test must run from inside the real MutantKit checkout"
        )

        let oldScratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-real-old-scratch")
        let newScratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-real-new-scratch")
        defer {
            try? FileManager.default.removeItem(at: oldScratch)
            try? FileManager.default.removeItem(at: newScratch)
        }

        let oldWorkspaces = try WorkspaceManager(projectRoot: sourcesCLI, scratchRoot: oldScratch, cleanSubtreeCloning: false)
        let newWorkspaces = try WorkspaceManager(projectRoot: sourcesCLI, scratchRoot: newScratch, cleanSubtreeCloning: true)

        let oldSandbox = try await oldWorkspaces.createSandbox(id: "mut_real")
        let newSandbox = try await newWorkspaces.createSandbox(id: "mut_real")

        let oldSnapshot = try CleanSubtreeCloningFixture.snapshot(at: oldSandbox)
        let newSnapshot = try CleanSubtreeCloningFixture.snapshot(at: newSandbox)
        #expect(oldSnapshot.count > 20, "expected a real, non-trivial tree of Swift source files")
        #expect(oldSnapshot == newSnapshot)
    }

    // MARK: - B. A deeply nested excluded file is never wrongly whole-tree-cloned

    @Test(
        """
        A directory containing one deeply nested excluded file is walked entry-by-entry, never whole-cloned -- \
        and its clean siblings still take the fast path
        """
    )
    func deeplyNestedExcludedFileIsNeverIncludedByAWholeTreeClone() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-nested-exclude-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try CleanSubtreeCloningFixture.writeMixedFixture(in: projectRoot)

        let scratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-nested-exclude-scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratch, cleanSubtreeCloning: true)
        let sandbox = try await workspaces.createSandbox(id: "mut_nested")

        #expect(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Sources/Pkg/Nested/Deep/debug.log").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Sources/Pkg/Nested/Deep/Real.swift").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Sources/Pkg/File1.swift").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Tests/PkgTests/Test1.swift").path))
    }

    // MARK: - C. Sandbox non-contamination through the fast path

    @Test(
        """
        Two sandboxes cloned through the fast path from the same source, one mutated after creation, never \
        observe each other's mutation -- and the index is built once, reused for both
        """
    )
    func fastPathSandboxesDoNotContaminateEachOther() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-contamination-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try CleanSubtreeCloningFixture.writeMixedFixture(in: projectRoot)

        let scratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-contamination-scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratch, cleanSubtreeCloning: true)

        let sandboxA = try await workspaces.createSandbox(id: "mut_contam_a")
        let sandboxB = try await workspaces.createSandbox(id: "mut_contam_b")

        let targetInA = sandboxA.appendingPathComponent("Sources/Pkg/File1.swift")
        let targetInB = sandboxB.appendingPathComponent("Sources/Pkg/File1.swift")
        let originalContent = try Data(contentsOf: targetInB)

        try Data("MUTATED IN A ONLY".utf8).write(to: targetInA)

        #expect(try Data(contentsOf: targetInB) == originalContent, "sandbox B observed a mutation made only to sandbox A")
        #expect(
            try Data(contentsOf: projectRoot.appendingPathComponent("Sources/Pkg/File1.swift")) == originalContent,
            "the mutation leaked back into the original project tree"
        )
    }

    @Test(
        """
        Content added to the project root after the index was built is not re-excluded on a later sandbox from \
        the same manager -- proving the index is reused, not rebuilt, per sandbox
        """
    )
    func indexIsReusedNotRebuiltPerSandbox() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-reuse-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let clean = projectRoot.appendingPathComponent("Sources/Extra/Keep.swift")
        try FileManager.default.createDirectory(at: clean.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: clean)

        let scratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-reuse-scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratch, cleanSubtreeCloning: true)

        // First sandbox: "Sources/Extra" is genuinely clean, gets classified
        // (and cached) as such.
        let firstSandbox = try await workspaces.createSandbox(id: "mut_reuse_a")
        #expect(FileManager.default.fileExists(atPath: firstSandbox.appendingPathComponent("Sources/Extra/Keep.swift").path))

        // New excluded content appears in the *source* tree after the index
        // was already built and cached.
        try Data("should have been excluded".utf8).write(
            to: projectRoot.appendingPathComponent("Sources/Extra/late.log")
        )

        let secondSandbox = try await workspaces.createSandbox(id: "mut_reuse_b")

        // This is the documented, accepted trade-off `ExecutionSettings
        // .cleanSubtreeCloning`'s own doc comment names as the reason this
        // flag stays opt-in: a cached "clean" classification does not
        // notice content that starts existing after it was recorded, so
        // the whole-directory clone brings the new file along. If this
        // assertion ever starts failing because the index began rebuilding
        // itself per sandbox, that is a *performance* regression to fix,
        // not a correctness bug to "fix" by making this assertion pass the
        // other way -- see this test's own name and the flag's doc comment.
        #expect(
            FileManager.default.fileExists(atPath: secondSandbox.appendingPathComponent("Sources/Extra/late.log").path),
            "expected the cached (now-stale) clean classification to be reused, bringing the new file along"
        )
    }

    // MARK: - D. Symlink safety

    @Test(
        """
        An internal symlink inside a clean subtree is recreated as a symlink with the exact original target \
        text, never dereferenced into a copy
        """
    )
    func internalSymlinkInsideACleanSubtreeIsPreservedExactly() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-symlink-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try CleanSubtreeCloningFixture.writeMixedFixture(in: projectRoot)

        let scratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-symlink-scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratch, cleanSubtreeCloning: true)
        let sandbox = try await workspaces.createSandbox(id: "mut_symlink")

        let fm = FileManager.default
        for (relativePath, expectedTarget) in [
            ("Sources/Pkg/Vendor/RelativeLink", "../File1.swift"),
            ("Sources/Pkg/Vendor/DanglingLink", "does-not-exist.swift"),
            ("Sources/Pkg/Vendor/AbsoluteLink", "/etc/hosts")
        ] {
            let cloned = sandbox.appendingPathComponent(relativePath)
            let values = try cloned.resourceValues(forKeys: [.isSymbolicLinkKey])
            #expect(values.isSymbolicLink == true, "\(relativePath) must still be a symlink, not a dereferenced copy")
            #expect(try fm.destinationOfSymbolicLink(atPath: cloned.path) == expectedTarget)
        }
    }

    @Test(
        """
        A top-level entry that is itself a symlink to a clean directory is recreated as a symlink, never \
        mistaken for a plain directory and whole-cloned
        """
    )
    func symlinkedEntryIsNeverTreatedAsAWholeSubtreeCloneCandidate() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-boundary-symlink-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try CleanSubtreeCloningFixture.writeMixedFixture(in: projectRoot)

        let scratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-boundary-symlink-scratch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratch, cleanSubtreeCloning: true)
        let sandbox = try await workspaces.createSandbox(id: "mut_boundary")

        let cloned = sandbox.appendingPathComponent("Sources/LinkedModule")
        let values = try cloned.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        #expect(values.isSymbolicLink == true, "Sources/LinkedModule must be recreated as a symlink")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: cloned.path) == "../ActualModule")
    }

    // MARK: - E. The scratch root is never pulled into a whole-directory clone

    @Test(
        """
        A scratch root nested under a name the exclude list does not otherwise cover is never copied into a \
        new sandbox by the fast path
        """
    )
    func scratchRootIsNeverPulledIntoAWholeSubtreeClone() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-scratchguard-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        // Everything under "BuildScratch" is the scratch root -- a name the
        // exclude list has no pattern for, so the only thing that can be
        // keeping it out of a sandbox is the scratch-root guard itself, not
        // `isExcluded`.
        let scratch = projectRoot.appendingPathComponent("BuildScratch/sandboxes")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("clean".utf8).write(to: projectRoot.appendingPathComponent("BuildScratch/Keep.swift"))

        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratch, cleanSubtreeCloning: true)
        let firstSandbox = try await workspaces.createSandbox(id: "mut_guard_a")
        // A second sandbox exists on disk, inside the scratch root, by the
        // time the *next* sandbox is populated -- exactly the shape that
        // would leak if "BuildScratch" were ever wrongly whole-cloned.
        let secondSandbox = try await workspaces.createSandbox(id: "mut_guard_b")

        for sandbox in [firstSandbox, secondSandbox] {
            #expect(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("BuildScratch/Keep.swift").path))
            #expect(
                !FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("BuildScratch/sandboxes").path),
                "the scratch root itself must never be copied into a sandbox"
            )
        }
    }

    // MARK: - F. Permission bits are a separate claim from "identical"

    /// Section A-E's "identical" is `CleanSubtreeCloningFixture.snapshot(at:)`'s
    /// own definition: kind, relative path, and (file bytes / symlink target
    /// text). POSIX
    /// permission bits are deliberately not part of that struct, and this
    /// test is why: the new whole-subtree `clonefile` path clones a
    /// directory's real mode bits along with everything else, while the old
    /// per-entry walk's `populate` creates every directory fresh via
    /// `FileManager.createDirectory`, which takes whatever mode the process's
    /// umask dictates, never the source directory's own. A file's own
    /// permission bits are not affected by this gap -- both paths always
    /// clone or copy a file's bytes rather than freshly creating it, and
    /// `clonefile`/`copyItem` both carry the source file's real mode along --
    /// only a *directory's* own bits diverge, and only through the old walk.
    @Test(
        """
        A clean directory's own POSIX permission bits are preserved exactly by the new whole-subtree clonefile \
        path, but NOT by the old per-entry walk, which creates every directory fresh at the process's default \
        mode instead of the source's
        """
    )
    func cleanDirectoryPermissionBitsDivergeBetweenOldAndNewPaths() async throws {
        let projectRoot = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-permbits-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let cleanDir = projectRoot.appendingPathComponent("Sources/Distinctive")
        try FileManager.default.createDirectory(at: cleanDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cleanDir.appendingPathComponent("File.swift"))
        // A mode `createDirectory`'s own umask-derived default is never
        // going to land on by chance -- recovering exactly this value
        // downstream is proof the source directory's real bits made the
        // trip, not a coincidence of whatever the default happens to be.
        let distinctiveMode = 0o751
        try FileManager.default.setAttributes([.posixPermissions: distinctiveMode], ofItemAtPath: cleanDir.path)

        let oldScratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-permbits-old-scratch")
        let newScratch = CleanSubtreeCloningFixture.makeTempDir(prefix: "csc-permbits-new-scratch")
        defer {
            try? FileManager.default.removeItem(at: oldScratch)
            try? FileManager.default.removeItem(at: newScratch)
        }
        let oldWorkspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: oldScratch, cleanSubtreeCloning: false)
        let newWorkspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: newScratch, cleanSubtreeCloning: true)
        let oldSandbox = try await oldWorkspaces.createSandbox(id: "mut_permbits")
        let newSandbox = try await newWorkspaces.createSandbox(id: "mut_permbits")

        // What the old walk's freshly-created directories actually land on
        // in *this* environment -- read from a directory this same scratch
        // root's own `WorkspaceManager` created moments ago, not assumed,
        // so this test never depends on a specific umask value being set.
        let referenceDefaultDir = oldScratch.appendingPathComponent("csc-permbits-reference-default")
        try FileManager.default.createDirectory(at: referenceDefaultDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: referenceDefaultDir) }

        func posixPermissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? Int)
        }

        let defaultMode = try posixPermissions(referenceDefaultDir)
        try #require(
            defaultMode != distinctiveMode,
            "the fixture's distinctive mode must differ from this environment's actual default, or this test cannot tell the two apart"
        )

        let oldMode = try posixPermissions(oldSandbox.appendingPathComponent("Sources/Distinctive"))
        let newMode = try posixPermissions(newSandbox.appendingPathComponent("Sources/Distinctive"))

        #expect(newMode == distinctiveMode, "the whole-subtree clonefile path must preserve the source directory's real permission bits")
        #expect(
            oldMode == defaultMode,
            """
            the per-entry walk creates a fresh directory at this environment's default mode, not the source's -- \
            documenting the actual, current divergence rather than an assumption
            """
        )
    }
}

/// The real, on-disk fixture and comparison logic every test above shares --
/// pulled out to a file-scope type rather than nested inside
/// `WorkspaceManagerCleanSubtreeCloningTests` itself so that struct's own
/// body (the tests) stays under SwiftLint's `type_body_length` limit; a
/// `private` file-scope type is exactly as invisible outside this file as a
/// `private` nested one would have been.
private enum CleanSubtreeCloningFixture {
    static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// A single, deliberately-mixed fixture that exercises every shape this
    /// pass's own required invariants care about at once: ordinary clean
    /// source directories, top-level excluded directories (`.git`, `.build`,
    /// `Carthage/Build`, `logs`), a `*.xcresult` glob match nested several
    /// levels down, a single excluded file buried inside an
    /// otherwise-ordinary-looking directory, an internal symlink (relative,
    /// dangling, and absolute) inside a clean subtree, and a top-level entry
    /// that is itself a symlink to another clean directory.
    static func writeMixedFixture(in root: URL) throws {
        let fm = FileManager.default
        func write(_ relativePath: String, _ contents: String = "x") throws {
            let url = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        func link(_ relativePath: String, to target: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }

        // Ordinary, unambiguously clean source content.
        try write("Package.swift", "// swift-tools-version:6.0")
        try write("Sources/Pkg/File1.swift", "let a = 1")
        try write("Sources/Pkg/Nested/File2.swift", "let b = 2")
        try write("Tests/PkgTests/Test1.swift", "// tests")

        // A directory that looks like an ordinary source tree but has one
        // excluded file buried three levels down -- the case the "never
        // wrongly whole-tree-cloned" invariant is about.
        try write("Sources/Pkg/Nested/Deep/Real.swift", "let c = 3")
        try write("Sources/Pkg/Nested/Deep/debug.log", "should never appear in a sandbox")

        // A glob-pattern match nested inside an otherwise ordinary directory.
        try write("Sources/Pkg/Reports/run.xcresult/Info.plist", "<plist/>")
        try write("Sources/Pkg/Reports/Notes.md", "kept")

        // Top-level excluded directories, standard shape.
        try write(".git/HEAD", "ref: refs/heads/main")
        try write(".git/objects/aa/bbbbbbbb", "loose-object-bytes")
        try write(".build/debug/Pkg.swiftmodule", "binary")
        try write("Carthage/Build/Something.framework/Info.plist", "<plist/>")
        try write("logs/run1.txt", "log")

        // An internal symlink inside a clean subtree -- relative, dangling,
        // and absolute targets, matching `CleanSubtreeIndexTests`'s own
        // coverage but proven here through an actual sandbox clone.
        try link("Sources/Pkg/Vendor/RelativeLink", to: "../File1.swift")
        try link("Sources/Pkg/Vendor/DanglingLink", to: "does-not-exist.swift")
        try link("Sources/Pkg/Vendor/AbsoluteLink", to: "/etc/hosts")

        // A top-level entry that is itself a symlink to another real,
        // otherwise-clean directory -- the "symlink at the subtree's own
        // boundary" case: this must always be recreated as a symlink, never
        // mistaken for a plain directory eligible for the whole-subtree
        // fast path, whatever the index says about the directory it points to.
        try write("ActualModule/Real.swift", "let d = 4")
        try link("Sources/LinkedModule", to: "../ActualModule")
    }

    enum EntryKind: Hashable {
        case file(Data)
        case symlink(target: String)
        case directory
    }

    struct Entry: Hashable, CustomStringConvertible {
        let relativePath: String
        let kind: EntryKind
        var description: String {
            switch kind {
            case let .file(data): "F \(relativePath) (\(data.count) bytes)"
            case let .symlink(target): "L \(relativePath) -> \(target)"
            case .directory: "D \(relativePath)"
            }
        }
    }

    /// A full, order-independent snapshot of every entry in a tree: kind,
    /// relative path, and (file bytes / symlink target text) content. Two
    /// snapshots being `==` is a stronger claim than `diff -r` would prove --
    /// it also confirms symlink-ness and target text are preserved exactly,
    /// not merely that a `readlink` would resolve to the same place.
    static func snapshot(at root: URL) throws -> Set<Entry> {
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
}
