@testable import CLI
import Foundation
import Testing

/// `SwiftPMLiveSourceResolution` replaces two earlier, both-flawed attempts
/// at keeping `sources.include` in sync with what SwiftPM actually compiles
/// (a directory-level list that over-includes a manifest's narrower
/// `sources:` allow-list, and a file-exact snapshot that under-includes a
/// file added after `setup` last ran) with a design that never drifts in
/// the first place: `sources.include`/`exclude` are an *optional filter*
/// over SwiftPM's own live-resolved compiled set, not a duplicate of it.
/// `["**"]` (the default `init`/`setup` write) applies no narrowing at all.
///
/// These tests exercise the pure filter, `narrow(_:include:exclude:)` — the
/// async `resolve(configuration:root:)` wrapper is a thin composition of
/// `SwiftPMTargetResolver.resolveDependencyGraph` and this function, each
/// covered on its own.
@Suite("SwiftPMLiveSourceResolution.narrow")
struct SwiftPMLiveSourceResolutionTests {
    @Test("The \"**\" default applies no narrowing — every compiled file passes through")
    func defaultMarkerAppliesNoNarrowing() {
        let result = SwiftPMLiveSourceResolution.narrow(
            ["ExampleApp/Services/Parser.swift", "ExampleApp/Services/Formatter.swift"],
            include: ["**"],
            exclude: []
        )
        #expect(result == ["ExampleApp/Services/Formatter.swift", "ExampleApp/Services/Parser.swift"])
    }

    @Test("A real include glob narrows the compiled set, exactly as it always has")
    func realIncludeGlobNarrows() {
        let result = SwiftPMLiveSourceResolution.narrow(
            ["ExampleApp/Services/Parser.swift", "ExampleApp/Networking/Client.swift"],
            include: ["ExampleApp/Networking/**"],
            exclude: []
        )
        #expect(result == ["ExampleApp/Networking/Client.swift"])
    }

    @Test("Exclude removes matches from the compiled set")
    func excludeRemovesMatches() {
        let result = SwiftPMLiveSourceResolution.narrow(
            ["ExampleApp/Services/Parser.swift", "ExampleApp/Services/Formatter.swift"],
            include: ["**"],
            exclude: ["**/Formatter.swift"]
        )
        #expect(result == ["ExampleApp/Services/Parser.swift"])
    }

    @Test("Include can never widen beyond what was actually compiled")
    func includeCannotWidenBeyondCompiled() {
        // A stale or overly broad sources.include (e.g. still naming a
        // directory that used to hold more files) must never resurrect a
        // file SwiftPM no longer compiles — only the compiled set bounds
        // what can come out.
        let result = SwiftPMLiveSourceResolution.narrow(
            ["ExampleApp/Services/Parser.swift"],
            include: ["ExampleApp/Services/**", "ExampleApp/Services/Helper.swift"],
            exclude: []
        )
        #expect(result == ["ExampleApp/Services/Parser.swift"])
    }

    @Test("An empty compiled set narrows to empty, regardless of include/exclude")
    func emptyCompiledSetStaysEmpty() {
        let result = SwiftPMLiveSourceResolution.narrow([], include: ["**"], exclude: [])
        #expect(result.isEmpty)
    }

    @Test("Results are sorted, regardless of input order")
    func resultsAreSorted() {
        let result = SwiftPMLiveSourceResolution.narrow(["Z.swift", "A.swift", "M.swift"], include: ["**"], exclude: [])
        #expect(result == ["A.swift", "M.swift", "Z.swift"])
    }
}

/// `project.path` support (a SwiftPM package living somewhere other than
/// the project root, relative *or* absolute — the same field every other
/// adapter honors, e.g. `SwiftPackageMacOSAdapter.diagnose`) needs `swift
/// package describe` run at that location and its reported file paths
/// rebased back to be `root`-relative before they can be compared against
/// `SourceFileWalker`'s own output or matched against
/// `sources.include`/`exclude`, which are always written relative to
/// `root`. A package outside `root` entirely (found only by `codex review`
/// — an absolute `project.path` silently ran `swift package describe` at
/// `root` itself instead, scoring the run against whatever unrelated
/// package happened to live there) has no such prefix to express, so
/// `resolve` must not attempt it. `resolve(configuration:root:)` itself
/// needs a real `swift package describe` call to test end-to-end; this
/// covers the pure prefix logic it depends on.
@Suite("SwiftPMLiveSourceResolution.packageLocation")
struct SwiftPMLiveSourceResolutionPackagePathTests {
    private let root = URL(fileURLWithPath: "/Users/dev/MyProject")

    @Test("nil, empty, and \".\" all resolve to root itself, with no rebasing prefix")
    func noSubdirectoryCases() {
        for path: String? in [nil, "", "."] {
            #expect(
                SwiftPMLiveSourceResolution.packageLocation(path: path, root: root)
                    == .resolvable(packageRoot: root, prefix: nil)
            )
        }
    }

    @Test("A real relative subdirectory resolves under root, with that subdirectory as the rebasing prefix")
    func realRelativeSubdirectory() {
        #expect(
            SwiftPMLiveSourceResolution.packageLocation(path: "Package", root: root)
                == .resolvable(packageRoot: root.appendingPathComponent("Package"), prefix: "Package")
        )
        #expect(
            SwiftPMLiveSourceResolution.packageLocation(path: "nested/Package", root: root)
                == .resolvable(packageRoot: root.appendingPathComponent("nested/Package"), prefix: "nested/Package")
        )
    }

    @Test("An absolute path still under root resolves identically to the equivalent relative path")
    func absolutePathUnderRootResolvesTheSameAsRelative() {
        #expect(
            SwiftPMLiveSourceResolution.packageLocation(path: "/Users/dev/MyProject/Package", root: root)
                == .resolvable(packageRoot: root.appendingPathComponent("Package"), prefix: "Package")
        )
    }

    @Test("An absolute path outside root is refused, not silently scored against root's own package")
    func absolutePathOutsideRootIsRefused() {
        #expect(SwiftPMLiveSourceResolution.packageLocation(path: "/Users/dev/OtherProject", root: root) == .outsideRoot)
        #expect(SwiftPMLiveSourceResolution.packageLocation(path: "/Users/dev/MyProjectSibling", root: root) == .outsideRoot)
    }
}
