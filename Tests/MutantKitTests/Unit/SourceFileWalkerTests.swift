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
        ).discover().requireComplete()
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

    @Test("A .docc catalog is pruned regardless of config, and admits agrees")
    func doccCatalogsArePruned() throws {
        try write("Sources/Lib/Real.swift")
        try write("Sources/Lib/Documentation.docc/Tutorials/Step-01.swift")

        #expect(try walk(exclude: []) == ["Sources/Lib/Real.swift"])

        let policy = SourceEligibilityPolicy(settings: SourceSettings(include: ["Sources/**"], exclude: []))
        #expect(policy.fileVerdict(relativePath: "Sources/Lib/Real.swift").isAdmitted)
        #expect(!policy.fileVerdict(relativePath: "Sources/Lib/Documentation.docc/Tutorials/Step-01.swift").isAdmitted)
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
            try SourceFileWalker(root: missing, settings: SourceSettings()).discover().requireComplete()
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
        let policy = SourceEligibilityPolicy(
            settings: SourceSettings(include: ["Sources/**"], exclude: ["Sources/Generated/**"])
        )

        #expect(policy.fileVerdict(relativePath: "Sources/Foo.swift").isAdmitted)
        #expect(!policy.fileVerdict(relativePath: "Sources/Generated/Foo.swift").isAdmitted)
        #expect(!policy.fileVerdict(relativePath: "Tests/Foo.swift").isAdmitted)
    }

    /// `PackageManifestConfirmationRetesting` (the isolated SwiftPM
    /// confirmation-retest fix) depends on `projectRoot`'s `Package.swift`
    /// being invariant across every mutant of a run. Today that holds only
    /// because the *default* `sources.include: ["Sources/**"]` never
    /// reaches the project root — this test proves the walker itself
    /// refuses to plan the manifest even when a user's `sources.include`
    /// is broadened wide enough to otherwise match it, so the invariant
    /// does not depend on that default.
    @Test("Package.swift is never a candidate, even when sources.include would otherwise match it")
    func packageManifestIsNeverACandidate() throws {
        try write("Package.swift", contents: "// swift-tools-version:6.0\n")
        try write("Sources/Real.swift")

        // A broad include covering the whole project root — exactly the
        // kind of config change the review flagged as able to accidentally
        // turn the manifest into a "legitimate" mutation candidate.
        let found = try walk(include: ["**/*.swift"], exclude: [])

        #expect(found == ["Sources/Real.swift"])
        #expect(!found.contains("Package.swift"))
    }

    /// Version-specific manifests (SwiftPM's own "version-specific manifest
    /// selection" naming: `Package@swift-<major>[.<minor>[.<patch>]].swift`,
    /// e.g. `Package@swift-5.9.swift`) get the identical unconditional
    /// exclusion as the base `Package.swift` — mutating either would break
    /// the same invariant.
    @Test("Package@swift-* version-specific manifests are never candidates either")
    func versionSpecificManifestsAreNeverCandidates() throws {
        try write("Package.swift", contents: "// swift-tools-version:6.0\n")
        try write("Package@swift-5.9.swift", contents: "// swift-tools-version:5.9\n")
        try write("Package@swift-5.swift", contents: "// swift-tools-version:5\n")
        try write("Sources/Real.swift")
        // Not a real SwiftPM manifest name (no numeric version component) —
        // must NOT be excluded by this check; only genuine manifest names are.
        try write("Sources/Package@swift-lookalike.swift")

        let found = try walk(include: ["**/*.swift"], exclude: [])

        #expect(found == ["Sources/Package@swift-lookalike.swift", "Sources/Real.swift"])
    }

    @Test("admits refuses Package.swift and version-specific manifests by name")
    func admitsRefusesPackageManifests() {
        let policy = SourceEligibilityPolicy(settings: SourceSettings(include: ["**/*.swift"], exclude: []))

        #expect(!policy.fileVerdict(relativePath: "Package.swift").isAdmitted)
        #expect(!policy.fileVerdict(relativePath: "Package@swift-5.9.swift").isAdmitted)
        #expect(policy.fileVerdict(relativePath: "Sources/Foo.swift").isAdmitted)
    }

    /// The walk and prospective membership used to be two predicates; a file
    /// under `.build/` or `Pods/` was "admitted" by one and never walked by the
    /// other. Both now come from `SourceEligibilityPolicy`, so for every Swift
    /// file on disk the walk lists it exactly when the policy admits it.
    @Test("walk and policy agree on every file, including mandatory-pruned ancestors")
    func walkAndPolicyAgree() throws {
        let paths = [
            "Sources/A.swift", "Sources/.build/Gen.swift", "Sources/Pods/P/Q.swift",
            "Sources/Lib/Doc.docc/T.swift", "Sources/Generated/G.swift", "Sources/Deep/DerivedData/D.swift",
            "Sources/Carthage/C.swift", "Sources/.git/hooks.swift", "Sources/Lib/Real.swift",
            "Sources/Package.swift", "Sources/notes.txt"
        ]
        for path in paths { try write(path) }
        let settings = SourceSettings(include: ["Sources/**"], exclude: ["**/Generated/**"])
        let walked = Set(try SourceFileWalker(root: root, settings: settings).discover().requireComplete())
        let policy = SourceEligibilityPolicy(settings: settings)

        for path in paths {
            #expect(walked.contains(path) == policy.fileVerdict(relativePath: path).isAdmitted, "\(path)")
        }
        #expect(walked == ["Sources/A.swift", "Sources/Lib/Real.swift"])
    }

    @Test("Verdicts name the reason a path is not eligible")
    func verdictsNameReasons() {
        let policy = SourceEligibilityPolicy(settings: SourceSettings(include: ["Sources/**"], exclude: ["**/Gen/**"]))
        #expect(policy.fileVerdict(relativePath: "Sources/.build/X.swift") == .prunedBuildOrVendorDirectory(".build"))
        #expect(policy.fileVerdict(relativePath: "Sources/D.docc/X.swift") == .prunedDocumentationCatalog("D.docc"))
        #expect(policy.fileVerdict(relativePath: "Sources/readme.md") == .notSwiftSource)
        #expect(policy.fileVerdict(relativePath: "Package.swift") == .packageManifest)
        #expect(policy.fileVerdict(relativePath: "Tests/X.swift") == .notIncludedByUser)
        #expect(policy.fileVerdict(relativePath: "Sources/Gen/X.swift") == .excludedByUser)
    }

    /// An unreadable nested directory used to be skipped with `continue`, so a
    /// permissions problem produced a green, smaller plan. It is now an
    /// explicit gap, and `requireComplete()` refuses it.
    @Test("An unreadable nested directory is a reported gap, not a smaller success")
    func unreadableNestedDirectoryIsAGap() throws {
        struct Boom: Error {}
        let fileSystem = SourceWalkerFileSystem { url in
            switch url.lastPathComponent {
            case root.lastPathComponent:
                [.init(name: "Sources", kind: .success(.directory))]
            case "Sources":
                [
                    .init(name: "Ok.swift", kind: .success(.file)),
                    .init(name: "Locked", kind: .success(.directory)),
                    .init(name: "Odd.swift", kind: .failure(Boom()))
                ]
            default:
                throw Boom()
            }
        }
        let walker = SourceFileWalker(root: root, settings: SourceSettings(), fileSystem: fileSystem)

        let discovery = try walker.discover()

        #expect(discovery.files == ["Sources/Ok.swift"])
        #expect(!discovery.isComplete)
        #expect(discovery.gaps.map(\.relativePath) == ["Sources/Locked", "Sources/Odd.swift"])
        #expect(discovery.gaps.map(\.kind) == [.directoryUnreadable, .metadataUnreadable])
        #expect(throws: PlannerError.self) { try discovery.requireComplete() }
    }

    @Test("Pruned directories are never listed, so they cannot become gaps")
    func prunedDirectoriesAreNotGaps() throws {
        struct Boom: Error {}
        let fileSystem = SourceWalkerFileSystem { url in
            if url.lastPathComponent == ".build" { throw Boom() }
            return url.lastPathComponent == root.lastPathComponent
                ? [.init(name: ".build", kind: .success(.directory)), .init(name: "link", kind: .success(.symbolicLink))]
                : []
        }
        let discovery = try SourceFileWalker(root: root, settings: SourceSettings(), fileSystem: fileSystem).discover()
        #expect(discovery.isComplete)
        #expect(discovery.files.isEmpty)
    }

    /// A directory no include pattern can reach (e.g. a root-owned data
    /// volume) cannot hide an eligible file, so failing to list it must not
    /// fail the plan.
    @Test("An unreadable directory outside every include is not a gap")
    func unreadableDirectoryOutsideIncludeIsNotAGap() throws {
        struct Boom: Error {}
        let fileSystem = SourceWalkerFileSystem { url in
            switch url.lastPathComponent {
            case root.lastPathComponent:
                [.init(name: "Sources", kind: .success(.directory)), .init(name: "data", kind: .success(.directory))]
            case "Sources":
                [.init(name: "A.swift", kind: .success(.file))]
            default:
                throw Boom()
            }
        }
        let settings = SourceSettings(include: ["Sources/**"], exclude: [])
        let discovery = try SourceFileWalker(root: root, settings: settings, fileSystem: fileSystem).discover()
        #expect(discovery.isComplete)
        #expect(discovery.files == ["Sources/A.swift"])

        // Exact-file includes (live SwiftPM resolution) reach only their own directories.
        let exact = SourceSettings(include: ["Sources/A.swift"], exclude: [])
        #expect(try SourceFileWalker(root: root, settings: exact, fileSystem: fileSystem).discover().isComplete)
    }

    @Test("Unreadable metadata of an entry policy rejects by name is not a gap")
    func unreadableMetadataOfPrunedNameIsNotAGap() throws {
        struct Boom: Error {}
        let fileSystem = SourceWalkerFileSystem { url in
            url.lastPathComponent == root.lastPathComponent
                ? [
                    .init(name: ".git", kind: .failure(Boom())),
                    .init(name: "Doc.docc", kind: .failure(Boom())),
                    .init(name: "Sources", kind: .success(.directory))
                ]
                : []
        }
        let discovery = try SourceFileWalker(root: root, settings: SourceSettings(), fileSystem: fileSystem).discover()
        #expect(discovery.isComplete)
    }

    @Test("canMatchBeneath: prefix-compatible patterns reach a directory, others do not")
    func canMatchBeneath() {
        #expect(Glob.canMatchBeneath(pattern: "Sources/**", directory: "Sources/A/B"))
        #expect(Glob.canMatchBeneath(pattern: "Sources/A/B.swift", directory: "Sources/A"))
        #expect(Glob.canMatchBeneath(pattern: "Sources/A", directory: "Sources/A/B"))
        #expect(Glob.canMatchBeneath(pattern: "**/*.swift", directory: "anything/at/all"))
        #expect(!Glob.canMatchBeneath(pattern: "Sources/**", directory: "data"))
        #expect(!Glob.canMatchBeneath(pattern: "Sources/A/B.swift", directory: "Sources/C"))
    }
}
