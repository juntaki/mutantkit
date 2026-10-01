import Foundation
@testable import MutationExecution
import Testing

@Suite("Sandbox external-root validation")
struct SandboxExternalRootValidatorTests {
    @Test("A relative symlink that climbs out of an external root is refused")
    func relativeEscapeIsRefused() throws {
        let tree = try ValidationTree(directories: [
            "SwiftMapper/Sources",
            "Elsewhere"
        ])
        defer { tree.remove() }
        try tree.symlink(
            "SwiftMapper/Sources/Shared",
            to: "../../Elsewhere"
        )

        #expect(throws: SandboxExternalRootError.symlinkLeavesExternalRoot(
            link: tree.path("SwiftMapper/Sources/Shared"),
            target: "../../Elsewhere",
            externalRoot: tree.path("SwiftMapper")
        )) {
            try tree.validate("SwiftMapper")
        }
    }

    @Test("An absolute symlink is refused even when it points inside the root")
    func absoluteSymlinkIsRefused() throws {
        let tree = try ValidationTree(directories: [
            "SwiftMapper/Sources/Real"
        ])
        defer { tree.remove() }
        try tree.symlink(
            "SwiftMapper/Sources/Alias",
            to: tree.path("SwiftMapper/Sources/Real")
        )

        #expect(throws: SandboxExternalRootError.symlinkLeavesExternalRoot(
            link: tree.path("SwiftMapper/Sources/Alias"),
            target: tree.path("SwiftMapper/Sources/Real"),
            externalRoot: tree.path("SwiftMapper")
        )) {
            try tree.validate("SwiftMapper")
        }
    }

    @Test("A dangling relative symlink that would land outside is refused")
    func danglingEscapeIsRefused() throws {
        let tree = try ValidationTree(directories: ["SwiftMapper"])
        defer { tree.remove() }
        try tree.symlink(
            "SwiftMapper/Missing",
            to: "../Nowhere/file.swift"
        )

        #expect(throws: SandboxExternalRootError.self) {
            try tree.validate("SwiftMapper")
        }
    }

    @Test("A lexically-contained link that escapes through another symlink is refused")
    func chainedEscapeIsRefused() throws {
        let tree = try ValidationTree(directories: [
            "SwiftMapper",
            "Elsewhere"
        ])
        defer { tree.remove() }
        try tree.symlink("SwiftMapper/Here", to: ".")
        try tree.symlink(
            "SwiftMapper/Via",
            to: "Here/../Elsewhere"
        )

        #expect(throws: SandboxExternalRootError.symlinkLeavesExternalRoot(
            link: tree.path("SwiftMapper/Via"),
            target: "Here/../Elsewhere",
            externalRoot: tree.path("SwiftMapper")
        )) {
            try tree.validate("SwiftMapper")
        }
    }

    @Test("Relative symlinks that remain inside the external root are allowed")
    func internalSymlinksAreAllowed() throws {
        let tree = try ValidationTree(directories: [
            "SwiftMapper/Sources/Real"
        ])
        defer { tree.remove() }
        try tree.symlink("SwiftMapper/Sources/Alias", to: "Real")
        try tree.symlink(
            "SwiftMapper/Top",
            to: "Sources/../Sources/Real"
        )

        try tree.validate("SwiftMapper")
    }

    @Test("Excluded directories are not scanned because the sandbox never copies them")
    func excludedDirectoriesAreSkipped() throws {
        let tree = try ValidationTree(directories: [
            "SwiftMapper/.build/checkouts",
            "Elsewhere"
        ])
        defer { tree.remove() }
        try tree.symlink(
            "SwiftMapper/.build/checkouts/Linked",
            to: tree.path("Elsewhere")
        )

        try tree.validate("SwiftMapper")
    }
}

private struct ValidationTree {
    let root: String

    init(directories: [String]) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SandboxExternalRootValidatorTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        root = try #require(CanonicalPath.resolve(base.path))
        for directory in directories {
            try FileManager.default.createDirectory(
                atPath: path(directory),
                withIntermediateDirectories: true
            )
        }
    }

    func path(_ relative: String) -> String {
        root + "/" + relative
    }

    func symlink(_ relative: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: path(relative),
            withDestinationPath: target
        )
    }

    func validate(_ relative: String) throws {
        try SandboxExternalRootValidator.validate(
            root: URL(
                fileURLWithPath: path(relative),
                isDirectory: true
            ),
            excludes: WorkspaceManager.defaultExcludes,
            scratchRootPath: path("Core/.mutantkit/sandboxes")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
