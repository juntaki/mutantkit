import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// Split out of `SchemataRuntimeBundledLocatorTests` (which stayed under
/// `type_body_length` on its own) to cover two review findings against the
/// bundled-runtime locator:
///
/// - **High**: `SwiftPMLinkerInjector`/`XcodeLinkerInjector` used to take a
///   `libraryDirectory` plus the fixed `-l<name>` convention, which links
///   whatever file conventionally named `libMutantKitSchemataRuntime.a`
///   happens to sit in that directory — not necessarily the exact file the
///   locator's own SHA-256 check just verified, if a manifest names its
///   verified archive something else. Both injectors now take
///   `Located.archivePath` directly, closing that gap structurally.
/// - **Medium**: a manifest-declared archive `path` was joined onto
///   `lib/mutantkit/schemata/` with no confinement check at all — an
///   absolute path or a `..`-escaping one was never rejected before this.
@Suite("SchemataRuntimeLibraryLocator: bundled runtime archive-path safety (review findings)")
struct SchemataRuntimeBundledLocatorArchivePathTests {
    private struct InstallRoot {
        let root: URL
        let executableURL: URL
        var schemataDirectory: URL { root.appendingPathComponent("lib/mutantkit/schemata", isDirectory: true) }
        var manifestPath: URL { schemataDirectory.appendingPathComponent("manifest.json") }
    }

    private static func makeInstallRoot() -> InstallRoot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-locator-archive-path-\(UUID().uuidString)")
        return InstallRoot(root: root, executableURL: root.appendingPathComponent("mutantkit"))
    }

    @discardableResult
    private static func writeArchive(_ data: Data, relativePath: String, in install: InstallRoot) throws -> String {
        let url = install.schemataDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return SHA256Digest.of(data).rawValue
    }

    private static func writeManifest(_ manifestJSON: Data, in install: InstallRoot) throws {
        try FileManager.default.createDirectory(at: install.schemataDirectory, withIntermediateDirectories: true)
        try manifestJSON.write(to: install.manifestPath)
    }

    private static func manifestJSON(runtimeABIVersion: UInt32 = 1, archivesJSON: String, schemaVersion: Int = 1) -> Data {
        Data("""
        {"schemaVersion": \(schemaVersion), "runtimeABIVersion": \(runtimeABIVersion), "archives": [\(archivesJSON)]}
        """.utf8)
    }

    // MARK: - Digest-verified file is the exact file that gets linked (review finding, High)

    /// The regression this suite exists to close: a manifest may legitimately name
    /// its archive anything (`SchemataRuntimeManifest.Archive.path`'s own doc comment
    /// never requires it to be called `libMutantKitSchemataRuntime.a`), so a
    /// directory can genuinely contain *two* files — the manifest-declared,
    /// digest-verified one, and an unrelated file that happens to share the
    /// conventional library name. Before `SwiftPMLinkerInjector`/`XcodeLinkerInjector`
    /// were switched to link `Located.archivePath` directly, a `-L<dir>
    /// -lMutantKitSchemataRuntime` pair would have silently linked the *second* file
    /// regardless of which one the locator actually verified. This test fixes the
    /// contract at the locator boundary: `archivePath` must be the exact file whose
    /// digest was checked, never merely "a file conventionally named
    /// `libMutantKitSchemataRuntime.a` living in the same directory."
    @Test("A differently-named manifest archive resolves to that exact file, not a same-directory sibling sharing the conventional name")
    func archivePathIsTheExactVerifiedFileNotTheConventionallyNamedSibling() throws {
        let install = Self.makeInstallRoot()
        let verifiedData = Data("the real, manifest-declared, digest-verified archive".utf8)
        let verifiedDigest = try Self.writeArchive(verifiedData, relativePath: "validated.a", in: install)
        // A same-directory file with the conventional name, deliberately different
        // bytes and never named by the manifest at all — must never be what gets
        // resolved or linked.
        let conventionallyNamedSiblingData = Data("an unrelated file that just happens to be named libMutantKitSchemataRuntime.a".utf8)
        try Self.writeArchive(conventionallyNamedSiblingData, relativePath: "libMutantKitSchemataRuntime.a", in: install)
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "validated.a", "sha256": "\(verifiedDigest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
        )
        #expect(located.provenance == .bundled)
        #expect(located.archivePath.path == install.schemataDirectory.appendingPathComponent("validated.a").path)
        #expect(located.archivePath.lastPathComponent != SchemataRuntimeLibraryLocator.libraryFileName)

        // The actual production seam this whole scenario is about: both injectors
        // must receive exactly this file, never a directory+conventional-name pair.
        let swiftPMArguments = SwiftPMLinkerInjector.extraArguments(archivePath: located.archivePath)
        #expect(swiftPMArguments == ["-Xlinker", located.archivePath.path])
        let xcodeArguments = XcodeLinkerInjector.extraArguments(archivePath: located.archivePath)
        #expect(xcodeArguments == ["OTHER_LDFLAGS=$(inherited) \(located.archivePath.path)"])
    }

    // MARK: - Manifest archive path confinement (review finding, Medium)

    @Test("A manifest declaring an absolute archive path throws bundledArchivePathUnsafe, never reads outside lib/mutantkit/schemata/")
    func absoluteArchivePathRejected() throws {
        let install = Self.makeInstallRoot()
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "/etc/passwd", "sha256": "\(String(repeating: "0", count: 64))", "architectures": ["arm64"]}
            """),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchivePathUnsafe(platform: .macOS, path: "/etc/passwd")) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("A manifest declaring a '..'-escaping archive path throws bundledArchivePathUnsafe, never resolves outside its root")
    func parentTraversalArchivePathRejected() throws {
        let install = Self.makeInstallRoot()
        // A real file genuinely sits where the traversal points, so a locator that
        // failed to reject this would otherwise happily "succeed" — proving this is
        // a real refusal, not one that only works because the target is absent.
        let escapee = install.root.appendingPathComponent("escaped.a")
        try FileManager.default.createDirectory(at: install.root, withIntermediateDirectories: true)
        try Data("outside lib/mutantkit/schemata entirely".utf8).write(to: escapee)
        defer { try? FileManager.default.removeItem(at: escapee) }

        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "../escaped.a", "sha256": "\(String(repeating: "0", count: 64))", "architectures": ["arm64"]}
            """),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchivePathUnsafe(platform: .macOS, path: "../escaped.a")) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("A manifest declaring an archive path with an empty or '.' component throws bundledArchivePathUnsafe")
    func emptyOrDotArchivePathComponentRejected() throws {
        let install = Self.makeInstallRoot()
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "./libMutantKitSchemataRuntime.a", "sha256": "\(String(repeating: "0", count: 64))", \
            "architectures": ["arm64"]}
            """),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchivePathUnsafe(
            platform: .macOS, path: "./libMutantKitSchemataRuntime.a"
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    // MARK: - Symlink-escaped confinement (review follow-up, High closure)

    /// The lexical-only version of the confinement check (layers 1/2 in
    /// `confinedArchiveURL`'s own doc comment) would pass this: the manifest
    /// path itself never contains `..`, and the plain joined path's own
    /// string is lexically confined to `lib/mutantkit/schemata/`. Only
    /// resolving the *real* target of the intermediate `escape` symlink
    /// reveals it is not. The archive at the escaped location is
    /// deliberately digest-valid — this is not "an archive that fails the
    /// digest check anyway," it is a real file a genuinely malicious
    /// manifest could point at and pass every other check, proving the
    /// confinement layer alone is what stops it.
    @Test("A symlinked intermediate directory escaping root throws bundledArchivePathUnsafe, even with a digest-valid archive there")
    func symlinkedIntermediateDirectoryEscapeRejected() throws {
        let install = Self.makeInstallRoot()
        try FileManager.default.createDirectory(at: install.schemataDirectory, withIntermediateDirectories: true)

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-locator-escape-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let payload = Data("a real archive, sitting entirely outside lib/mutantkit/schemata".utf8)
        try payload.write(to: outside.appendingPathComponent("libMutantKitSchemataRuntime.a"))
        let realDigest = SHA256Digest.of(payload).rawValue

        // The symlink itself lives inside the schemata directory — its own
        // path is lexically confined, only its *target* is not.
        try FileManager.default.createSymbolicLink(
            at: install.schemataDirectory.appendingPathComponent("escape"), withDestinationURL: outside
        )

        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "escape/libMutantKitSchemataRuntime.a", "sha256": "\(realDigest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchivePathUnsafe(
            platform: .macOS, path: "escape/libMutantKitSchemataRuntime.a"
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    /// The other shape the same review finding named explicitly: not an
    /// intermediate directory symlink, but the manifest-named archive
    /// *file itself* being a symlink whose target sits outside root. A
    /// check that only resolved intermediate directories (never the leaf)
    /// would miss this one.
    @Test("An archive that is itself a symlink escaping root throws bundledArchivePathUnsafe, even with a digest-valid target")
    func archiveFileItselfSymlinkEscapeRejected() throws {
        let install = Self.makeInstallRoot()
        try FileManager.default.createDirectory(at: install.schemataDirectory, withIntermediateDirectories: true)

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-locator-escape-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let payload = Data("a real archive, reached only through a symlinked leaf".utf8)
        let realTarget = outside.appendingPathComponent("runtime.a")
        try payload.write(to: realTarget)
        let realDigest = SHA256Digest.of(payload).rawValue

        // The symlink's own name is exactly the conventional library
        // filename, living directly inside the schemata directory — only
        // its target escapes.
        try FileManager.default.createSymbolicLink(
            at: install.schemataDirectory.appendingPathComponent("libMutantKitSchemataRuntime.a"), withDestinationURL: realTarget
        )

        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(realDigest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchivePathUnsafe(
            platform: .macOS, path: "libMutantKitSchemataRuntime.a"
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }
}
