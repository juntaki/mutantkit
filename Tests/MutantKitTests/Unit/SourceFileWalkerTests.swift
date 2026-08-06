import Foundation
import MutationModel
import MutationPlanner
import Testing

/// The walker is the only thing standing between a run and a multi-minute tour
/// of `.build` or `DerivedData`. The pruned set is unconfigurable on purpose:
/// nothing good comes of mutating build products, and a symlink loop would turn
/// the walk into one. These tests build a real (temp) tree because the walker's
/// contract is about what it does on disk — its handling of symlinks, hidden
/// directories, and excluded paths is the part that cannot be exercised any
/// other way.
@Suite("Source file walker")
struct SourceFileWalkerTests {
    /// A temp directory laid out for one walk and torn down at the end. Each
    /// test gets a fresh one because the failure mode being protected against —
    /// descending somewhere it should not — only needs one stray file to spot.
    private let root: URL = Self.makeRoot()

    private static func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-walker-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relativePath: String, contents: String = "//\n") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func walk(
        include: [String] = ["Sources/**"],
        exclude: [String] = SourceSettings.defaultExcludes
    ) throws -> [String] {
        try SourceFileWalker(
            root: root,
            settings: SourceSettings(include: include, exclude: exclude)
        ).walk()
    }

    @Test("Finds nested Swift files, sorted and relative")
    func findsNestedFiles() throws {
        try write("Sources/App/Foo.swift")
        try write("Sources/App/Sub/Bar.swift")
        try write("Sources/Root.swift")

        let found = try walk()

        #expect(found == [
            "Sources/App/Foo.swift",
            "Sources/App/Sub/Bar.swift",
            "Sources/Root.swift"
        ])
    }

    @Test("Non-Swift files are ignored")
    func ignoresNonSwiftFiles() throws {
        try write("Sources/Foo.swift")
        try write("Sources/README.md")
        try write("Sources/notes.txt")

        #expect(try walk() == ["Sources/Foo.swift"])
    }

    /// `.build`, `DerivedData`, `Pods`, etc. are pruned unconditionally. A loose
    /// exclude pattern would let them in; a missing one would walk vendored code
    /// that has no business being mutated.
    @Test("Build-artifact directories are pruned regardless of config")
    func buildArtifactDirectoriesArePruned() throws {
        try write("Sources/Foo.swift")
        try write(".build/arm64-apple-macosx/debug/Foo.swift")
        try write("DerivedData/Build/Products/Debug/Foo.swift")
        try write("Pods/SomeDep/Source.swift")
        try write("Carthage/Checkouts/Dep/Source.swift")

        let found = try walk()

        #expect(found == ["Sources/Foo.swift"])
    }

    /// A symlink that points at an ancestor would loop the walker forever. The
    /// walker skips symlinks rather than resolving them — this is the only
    /// reason a malicious or accidental link cannot hang a run.
    @Test("Symlinks are not followed")
    func symlinksAreNotFollowed() throws {
        try write("Sources/Real.swift")
        try write("Sources/Loop.swift", contents: "// symlink target inside the tree")

        // Create a symlink that points at the root, the classic infinite loop.
        let link = root.appendingPathComponent("Sources/loop-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root
        )

        let found = try walk()

        // The real file shows up; the loop does not pull the tree in twice.
        #expect(found == ["Sources/Loop.swift", "Sources/Real.swift"])
    }

    @Test("Exclude patterns drop matching files")
    func excludeDropsMatchingFiles() throws {
        try write("Sources/Real.swift")
        try write("Sources/Other.swift")

        // An empty exclude lets both through; naming one drops only it. The
        // default excludes are mixed in to confirm they stack, not replace.
        let defaults = try walk(exclude: SourceSettings.defaultExcludes)
        #expect(defaults.sorted() == ["Sources/Other.swift", "Sources/Real.swift"])

        let withExclude = try walk(exclude: SourceSettings.defaultExcludes + ["Sources/Real.swift"])
        #expect(withExclude == ["Sources/Other.swift"])
    }

    /// The default excludes match by file name suffix and by directory. A
    /// directory match has to cover everything beneath it; a name match has to
    /// be exact about the segment it names.
    @Test("The default excludes drop generated code by suffix and directory")
    func defaultExcludesDropGeneratedCode() throws {
        try write("Sources/Real.swift")
        try write("Sources/Generated/Code.swift")
        try write("Sources/Generated/Deep/Code.swift")
        try write("Sources/Entity.generated.swift")
        try write("Sources/UserMock.swift")
        try write("Sources/Aux/Mocks.swift")
        try write("Sources/Aux/Mocks/Helper.swift")

        let found = try walk()

        // `Real.swift` survives. Everything generated — by directory or suffix —
        // is gone. `*Mock*` matches a file named exactly `Mocks.swift` but does
        // not match a *file* inside a `Mocks/` directory unless its own name
        // contains `Mock`.
        #expect(found == ["Sources/Aux/Mocks/Helper.swift", "Sources/Real.swift"])
    }

    /// A non-existent root is a user-facing problem with no recovery — the
    /// walker refuses it rather than returning an empty list and letting the
    /// run continue against zero files.
    @Test("A missing root is an error, not an empty walk")
    func missingRootIsAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-missing-\(UUID().uuidString)")

        #expect(throws: PlannerError.self) {
            try SourceFileWalker(root: missing, settings: SourceSettings()).walk()
        }
    }

    @Test("A custom include pattern restricts the walk")
    func customIncludeRestrictsWalk() throws {
        try write("Sources/App/Foo.swift")
        try write("Sources/Tests/Bar.swift")
        try write("Sources/Shared/Baz.swift")

        let found = try walk(include: ["Sources/App/**"], exclude: [])

        #expect(found == ["Sources/App/Foo.swift"])
    }

    @Test("admits exposes the include/exclude decision without touching disk")
    func admitsMatchesConfiguredRules() {
        let walker = SourceFileWalker(
            root: root,
            settings: SourceSettings(include: ["Sources/**"], exclude: ["Sources/Generated/**"])
        )

        #expect(walker.admits(relativePath: "Sources/Foo.swift"))
        #expect(!walker.admits(relativePath: "Sources/Generated/Foo.swift"))
        #expect(!walker.admits(relativePath: "Tests/Foo.swift"))
    }
}
