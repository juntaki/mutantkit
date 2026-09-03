import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// With no override set, `SchemataRuntimeLibraryLocator.locate`
/// falls through to a bundled `lib/mutantkit/schemata/` next to the
/// executable itself, validated against `manifest.json` — never trusted on
/// directory-layout convention alone. Every case here builds a real, on-disk
/// fixture tree and passes it via the locator's own `executableURL:`
/// injection seam (never `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE`, so the
/// bundled path — not the override path — is what's actually under test).
@Suite("SchemataRuntimeLibraryLocator: bundled runtime")
struct SchemataRuntimeBundledLocatorTests {
    private static let expectedRuntimeABIVersion: UInt32 = 1

    /// A fresh, empty temp directory standing in for a release install
    /// root, plus the executable URL a real `mutantkit` binary would sit
    /// at inside it — `lib/mutantkit/schemata/` is resolved relative to
    /// this URL's *parent* directory, exactly as production code does; the
    /// file at `executableURL` itself never needs to exist on disk.
    private struct InstallRoot {
        let root: URL
        let executableURL: URL
        var schemataDirectory: URL { root.appendingPathComponent("lib/mutantkit/schemata", isDirectory: true) }
        var manifestPath: URL { schemataDirectory.appendingPathComponent("manifest.json") }
    }

    private static func makeInstallRoot() -> InstallRoot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-locator-\(UUID().uuidString)")
        return InstallRoot(root: root, executableURL: root.appendingPathComponent("mutantkit"))
    }

    /// Writes `data` at `schemataDirectory`-relative `path`, computing its
    /// real SHA-256 (via `SHA256Digest`, the same production type the
    /// locator itself uses) so a test can either use the genuine digest
    /// (the happy path) or deliberately substitute a wrong one (the
    /// mismatch path), without ever hand-computing a hash by hand.
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

    private static func manifestJSON(
        runtimeABIVersion: UInt32 = expectedRuntimeABIVersion, archivesJSON: String, schemaVersion: Int = 1
    ) -> Data {
        Data("""
        {"schemaVersion": \(schemaVersion), "runtimeABIVersion": \(runtimeABIVersion), "archives": [\(archivesJSON)]}
        """.utf8)
    }

    // MARK: - Happy path

    @Test("A valid manifest with a macOS archive resolves with .bundled provenance and the real archive path")
    func validMacOSManifestResolves() throws {
        let install = Self.makeInstallRoot()
        let macOSData = Data("fake macos archive".utf8)
        let digest = try Self.writeArchive(macOSData, relativePath: "libMutantKitSchemataRuntime.a", in: install)
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(digest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
        )
        #expect(located.provenance == .bundled)
        #expect(located.libraryDirectory.path == install.schemataDirectory.path)
        #expect(located.archivePath.path == install.schemataDirectory.appendingPathComponent("libMutantKitSchemataRuntime.a").path)
    }

    @Test("A valid manifest with an iphonesimulator archive in its own subdirectory resolves correctly")
    func validIOSSimulatorManifestResolves() throws {
        let install = Self.makeInstallRoot()
        let simData = Data("fake simulator archive".utf8)
        let digest = try Self.writeArchive(simData, relativePath: "iphonesimulator/libMutantKitSchemataRuntime.a", in: install)
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "iphonesimulator", "path": "iphonesimulator/libMutantKitSchemataRuntime.a", "sha256": "\(digest)", \
            "architectures": ["arm64", "x86_64"]}
            """),
            in: install
        )

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .iOSSimulator, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
        )
        #expect(located.provenance == .bundled)
        #expect(located.libraryDirectory.path == install.schemataDirectory.appendingPathComponent("iphonesimulator").path)
    }

    @Test("A manifest declaring both platforms resolves each independently to its own archive")
    func manifestWithBothPlatformsResolvesEachIndependently() throws {
        let install = Self.makeInstallRoot()
        let macDigest = try Self.writeArchive(Data("mac".utf8), relativePath: "libMutantKitSchemataRuntime.a", in: install)
        let simDigest = try Self.writeArchive(
            Data("sim".utf8), relativePath: "iphonesimulator/libMutantKitSchemataRuntime.a", in: install
        )
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(macDigest)", "architectures": ["arm64"]}, \
            {"platform": "iphonesimulator", "path": "iphonesimulator/libMutantKitSchemataRuntime.a", "sha256": "\(simDigest)", \
            "architectures": ["arm64", "x86_64"]}
            """),
            in: install
        )

        let mac = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
        )
        let sim = try SchemataRuntimeLibraryLocator.locate(
            for: .iOSSimulator, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
        )
        #expect(mac.archivePath.path == install.schemataDirectory.appendingPathComponent("libMutantKitSchemataRuntime.a").path)
        #expect(
            sim.archivePath.path == install.schemataDirectory.appendingPathComponent("iphonesimulator/libMutantKitSchemataRuntime.a").path
        )
    }

    // MARK: - Fail-closed cases

    @Test("No manifest.json at all throws bundledRuntimeUnavailable, naming the exact path it looked for")
    func missingManifestThrowsBundledRuntimeUnavailable() throws {
        let install = Self.makeInstallRoot()
        try FileManager.default.createDirectory(at: install.root, withIntermediateDirectories: true)

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledRuntimeUnavailable(
            reason: "no bundled schemata runtime manifest at \(install.manifestPath.path)"
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("A completely absent install root also throws bundledRuntimeUnavailable, not a crash")
    func absentInstallRootThrowsBundledRuntimeUnavailable() throws {
        let install = Self.makeInstallRoot() // never created at all
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.self) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("Malformed JSON in manifest.json throws bundledManifestInvalid, never a crash or a silent skip")
    func malformedManifestJSONThrows() throws {
        let install = Self.makeInstallRoot()
        try Self.writeManifest(Data("{ not valid json".utf8), in: install)

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.self) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("An unsupported manifest schemaVersion throws bundledManifestInvalid, never silently accepted")
    func unsupportedSchemaVersionThrows() throws {
        let install = Self.makeInstallRoot()
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: "", schemaVersion: 999),
            in: install
        )

        guard case let .bundledManifestInvalid(path, reason) = try errorThrown(
            for: .macOS, install: install
        ) else {
            Issue.record("expected bundledManifestInvalid")
            return
        }
        #expect(path == install.manifestPath.path)
        #expect(reason.contains("999"))
    }

    @Test("A manifest with no archive entry for the requested platform throws bundledArchiveMissingForPlatform")
    func missingPlatformArchiveThrows() throws {
        let install = Self.makeInstallRoot()
        let macDigest = try Self.writeArchive(Data("mac".utf8), relativePath: "libMutantKitSchemataRuntime.a", in: install)
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(macDigest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchiveMissingForPlatform(
            platform: .iOSSimulator, manifestPath: install.manifestPath.path
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .iOSSimulator, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("A manifest naming an archive file that does not exist on disk throws bundledArchiveFileMissing")
    func missingArchiveFileThrows() throws {
        let install = Self.makeInstallRoot()
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(String(repeating: "0", count: 64))", \
            "architectures": ["arm64"]}
            """),
            in: install
        )

        let expectedArchivePath = install.schemataDirectory.appendingPathComponent("libMutantKitSchemataRuntime.a").path
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledArchiveFileMissing(
            platform: .macOS, path: expectedArchivePath
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    @Test("An archive whose real SHA-256 does not match the manifest's declared digest throws bundledArchiveDigestMismatch, never links it")
    func digestMismatchThrows() throws {
        let install = Self.makeInstallRoot()
        try Self.writeArchive(Data("real bytes on disk".utf8), relativePath: "libMutantKitSchemataRuntime.a", in: install)
        let wrongDigest = SHA256Digest.of(Data("a completely different payload".utf8)).rawValue
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(wrongDigest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        let error = try errorThrown(for: .macOS, install: install)
        guard case let .bundledArchiveDigestMismatch(platform, path, expected, actual) = error else {
            Issue.record("expected bundledArchiveDigestMismatch")
            return
        }
        #expect(platform == .macOS)
        #expect(path == install.schemataDirectory.appendingPathComponent("libMutantKitSchemataRuntime.a").path)
        #expect(expected == wrongDigest)
        #expect(actual == SHA256Digest.of(Data("real bytes on disk".utf8)).rawValue)
    }

    @Test("A manifest declaring a runtimeABIVersion this build does not expect throws bundledRuntimeABIMismatch, never links it")
    func runtimeABIMismatchThrows() throws {
        let install = Self.makeInstallRoot()
        let digest = try Self.writeArchive(Data("mac".utf8), relativePath: "libMutantKitSchemataRuntime.a", in: install)
        try Self.writeManifest(
            Self.manifestJSON(
                runtimeABIVersion: Self.expectedRuntimeABIVersion + 1,
                archivesJSON: """
                {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(digest)", "architectures": ["arm64"]}
                """
            ),
            in: install
        )

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.bundledRuntimeABIMismatch(
            platform: .macOS, manifestVersion: Self.expectedRuntimeABIVersion + 1, expectedVersion: Self.expectedRuntimeABIVersion
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
        }
    }

    // MARK: - Override still takes priority

    @Test("An override set alongside a genuine bundled runtime still wins — the override path never consults the manifest at all")
    func overrideTakesPriorityOverBundled() throws {
        let install = Self.makeInstallRoot()
        let digest = try Self.writeArchive(Data("bundled".utf8), relativePath: "libMutantKitSchemataRuntime.a", in: install)
        try Self.writeManifest(
            Self.manifestJSON(archivesJSON: """
            {"platform": "macosx", "path": "libMutantKitSchemataRuntime.a", "sha256": "\(digest)", "architectures": ["arm64"]}
            """),
            in: install
        )

        let overrideDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("override-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
        try Data("override archive".utf8).write(to: overrideDirectory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName))

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS,
            environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: overrideDirectory.path],
            sourceDirectory: nil,
            executableURL: install.executableURL
        )
        #expect(located.provenance == .override)
        #expect(located.libraryDirectory.path == overrideDirectory.path)
    }

    // MARK: - Helper

    private func errorThrown(
        for platform: SchemataRuntimePlatform, install: InstallRoot
    ) throws -> SchemataRuntimeLibraryLocator.LocatorError {
        do {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: platform, environment: [:], sourceDirectory: nil, executableURL: install.executableURL
            )
            throw TestFailure.expectedThrow
        } catch let error as SchemataRuntimeLibraryLocator.LocatorError {
            return error
        }
    }

    private enum TestFailure: Error { case expectedThrow }
}
