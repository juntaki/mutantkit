import Foundation
@testable import MutationExecution
import Testing

/// White-box coverage for `CleanSubtreeIndex.build`/`isClean` in isolation
/// from `WorkspaceManager` — every test here builds a real, on-disk fixture
/// and asks the index real questions about it, rather than asserting
/// against a mocked filesystem: "clean" is a claim about real files, so it
/// is proven against real files.
///
/// See `WorkspaceManagerCleanSubtreeCloningTests` for the end-to-end
/// invariants this index exists to make safe: `populate` output with
/// identical content and directory layout (not, notably, identical POSIX
/// permission bits -- that suite's own doc comment explains why not),
/// non-contamination, symlink safety, non-APFS fallback.
@Suite("CleanSubtreeIndex")
struct CleanSubtreeIndexTests {
    private let root: URL = Self.makeTempDir(prefix: "csi-root")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "csi-scratch")

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func write(_ relativePath: String, contents: String = "x") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func symlink(_ relativePath: String, to target: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    private func build() -> CleanSubtreeIndex {
        CleanSubtreeIndex.build(
            projectRoot: root, excludes: WorkspaceManager.defaultExcludes, scratchRootPath: scratchRoot.path
        )
    }

    @Test("An ordinary directory with no excluded content anywhere inside it is classified clean")
    func ordinaryDirectoryIsClean() throws {
        try write("Sources/Pkg/File1.swift")
        try write("Sources/Pkg/Nested/File2.swift")

        let index = build()
        #expect(index.isClean(relativePath: "Sources"))
        #expect(index.isClean(relativePath: "Sources/Pkg"))
        #expect(index.isClean(relativePath: "Sources/Pkg/Nested"))
    }

    @Test("A top-level excluded directory is never recorded clean, and its own contents never taint an unrelated sibling")
    func topLevelExcludedDirectoryIsNeverClean() throws {
        try write(".git/objects/aa/bbbb", contents: "loose-object")
        try write("Sources/Pkg/File.swift")

        let index = build()
        #expect(!index.isClean(relativePath: ".git"))
        #expect(!index.isClean(relativePath: ".git/objects"))
        #expect(index.isClean(relativePath: "Sources"), "an excluded sibling must never taint an unrelated directory")
    }

    @Test("A single deeply nested excluded file marks every ancestor directory dirty, but never a sibling that does not contain it")
    func deeplyNestedExcludedFileTaintsOnlyItsOwnAncestorChain() throws {
        try write("Sources/A/B/C/debug.log", contents: "log output")
        try write("Sources/A/B/C/Real.swift")
        try write("Sources/D/Untouched.swift")

        let index = build()

        // The whole chain from "Sources" down to the file's own parent must
        // be dirty -- a whole-directory clone at any of these levels would
        // include "debug.log", which the per-entry walk would have excluded.
        #expect(!index.isClean(relativePath: "Sources"))
        #expect(!index.isClean(relativePath: "Sources/A"))
        #expect(!index.isClean(relativePath: "Sources/A/B"))
        #expect(!index.isClean(relativePath: "Sources/A/B/C"))

        // A sibling that never contains the excluded file must still be
        // provably clean -- this is the entire point of classifying every
        // subtree individually rather than the tree as a whole.
        #expect(index.isClean(relativePath: "Sources/D"))
    }

    @Test("A *.log/*.xcresult glob match is caught at any depth, not just at the top level")
    func globPatternsMatchAtAnyDepth() throws {
        try write("Sources/Pkg/Reports/run.xcresult/info.plist")
        try write("Sources/Pkg/Reports/Real.swift")

        let index = build()
        #expect(!index.isClean(relativePath: "Sources/Pkg/Reports"))
        #expect(!index.isClean(relativePath: "Sources/Pkg"))
    }

    @Test("An internal symlink inside an otherwise-clean directory does not taint its cleanliness")
    func internalSymlinkDoesNotTaintCleanliness() throws {
        try write("Sources/Pkg/Real.swift")
        try symlink("Sources/Pkg/RelativeLink", to: "Real.swift")
        try symlink("Sources/Pkg/DanglingLink", to: "does-not-exist.swift")
        try symlink("Sources/Pkg/AbsoluteLink", to: "/etc/hosts")

        let index = build()
        #expect(index.isClean(relativePath: "Sources/Pkg"))
    }

    @Test("A symlink whose own name matches an exclude pattern still taints its parent, exactly like a real excluded file would")
    func excludedNameAppliesToASymlinkToo() throws {
        try write("Sources/Pkg/Real.swift")
        try symlink("Sources/Pkg/stale.log", to: "Real.swift")

        let index = build()
        #expect(!index.isClean(relativePath: "Sources/Pkg"))
    }

    @Test("The bare `Build` pattern excludes any directory named exactly that, at any depth -- not just under `Carthage`")
    func bareBuildPatternMatchesAtAnyDepth() throws {
        // `defaultExcludes` lists both a bare "Build" and a compound
        // "Carthage/Build" -- the bare pattern alone already matches any
        // directory literally named "Build" anywhere in the tree (the
        // `isExcluded` check tests `name` alone, with no path prefix
        // required), independent of `Carthage/Build`'s own narrower reach.
        try write("Sources/Pkg/Build/Artifact.txt")
        try write("Sources/Pkg/Kept/Real.swift")

        let index = build()
        #expect(!index.isClean(relativePath: "Sources/Pkg"))
        #expect(!index.isClean(relativePath: "Sources/Pkg/Build"))
        #expect(index.isClean(relativePath: "Sources/Pkg/Kept"))
    }

    @Test(
        """
        A slash-containing pattern like `Carthage/Build` matches only its exact relativePath, never a nested \
        occurrence of the same spelling -- isolated from the bare `Build` pattern's own, wider reach
        """
    )
    func slashContainingPatternMatchesOnlyItsExactRelativePath() throws {
        // A custom, narrower exclude list containing *only* the compound
        // pattern -- `defaultExcludes`'s own bare "Build" entry would
        // independently exclude every "Build"-named directory in this
        // fixture regardless of position, which would make it impossible
        // to observe `Carthage/Build`'s own narrower, exact-relativePath-
        // only behaviour in isolation. This is exactly the same `fnmatch`
        // call (`WorkspaceManager.isExcluded`), just against a exclude
        // list built to isolate the one pattern under test.
        let excludes = ["Carthage/Build"]
        try write("Carthage/Build/Artifact.framework/Info.plist")
        try write("Vendor/Carthage/Build/Artifact.framework/Info.plist")

        let index = CleanSubtreeIndex.build(projectRoot: root, excludes: excludes, scratchRootPath: scratchRoot.path)

        // Top-level "Carthage/Build" is an exact relativePath match --
        // "Carthage" itself becomes dirty because its own entry "Build" at
        // relativePath "Carthage/Build" matches the pattern exactly.
        #expect(!index.isClean(relativePath: "Carthage"))
        // Nested at "Vendor/Carthage/Build": the pattern is a literal
        // string with no wildcard, so it can only match the exact
        // relativePath "Carthage/Build" -- this nested occurrence's
        // relativePath is "Vendor/Carthage/Build", a different string, so
        // `WorkspaceManager.isExcluded` does not match it, and this index
        // faithfully reproduces that (not a "fixed" version of it -- this
        // pass's own correctness gate is byte-for-byte parity with
        // `isExcluded`'s real behaviour, not a broader exclude semantics
        // change).
        #expect(index.isClean(relativePath: "Vendor/Carthage"))
        #expect(index.isClean(relativePath: "Vendor/Carthage/Build"))
    }

    @Test(
        """
        The scratch root, when nested inside the project root under a name the exclude list does not otherwise \
        cover, is still never descended into and never taints its siblings
        """
    )
    func scratchRootNestedInsideProjectRootIsNeverDescendedInto() throws {
        // A caller-supplied scratch root need not sit under an already-excluded
        // name -- this fixture deliberately avoids one (unlike ".mutantkit",
        // which `defaultExcludes` would skip anyway, telling this test nothing
        // about the scratch-root guard specifically) so the only thing that can
        // be stopping descent here is that guard.
        let nestedScratch = root.appendingPathComponent("BuildScratch/sandboxes")
        try FileManager.default.createDirectory(
            at: nestedScratch.appendingPathComponent("sbx_abc"), withIntermediateDirectories: true
        )
        // A sandbox this run has already created, sitting inside the scratch
        // root -- if the index ever descended into it, this file (whose name
        // matches no exclude pattern) would otherwise make "BuildScratch"
        // look dirty, or leak a bogus "clean" entry for a directory this
        // index has no business describing at all.
        try Data("mutated".utf8).write(to: nestedScratch.appendingPathComponent("sbx_abc/Source.swift"))
        try write("Sources/Pkg/File.swift")

        let index = CleanSubtreeIndex.build(
            projectRoot: root, excludes: WorkspaceManager.defaultExcludes, scratchRootPath: nestedScratch.path
        )

        #expect(index.isClean(relativePath: "Sources"))
        #expect(index.isClean(relativePath: "Sources/Pkg"))
        // "BuildScratch" itself is not descended into at all (the guard
        // fires on its *child*, `nestedScratch`, which is the actual
        // `scratchRootPath`) -- but nothing inside it was ever examined
        // either, so it must not be recorded clean: nothing proved it is.
        #expect(!index.isClean(relativePath: "BuildScratch"))
    }
}
