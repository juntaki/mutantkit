@testable import AppleBuildAdapters
import Foundation
import Testing

/// Direct, pure-function coverage of `SchemataRuntimeStalenessGuard` — the
/// mechanism behind `SchemataRuntimeLibraryLocator.LocatorError.staleArchive`.
/// `SwiftPMLinkerInjectorTests`'s `SchemataRuntimeLibraryLocatorTests` covers
/// the same behavior through the public locator API; these tests instead
/// pin the guard's own edge cases (multiple stale files, `.h` vs `.c`,
/// nested subdirectories, files that are neither) without a locator or
/// override-environment round trip in the way.
@Suite("SchemataRuntimeStalenessGuard")
struct SchemataRuntimeStalenessGuardTests {
    /// Returns the *canonical* path actually written — `FileManager`'s directory
    /// enumerator reports paths with the `/var` → `/private/var` symlink resolved (unlike
    /// `URL.resolvingSymlinksInPath()`, which — at least in this sandboxed environment —
    /// leaves it untouched), so an expectation built from the unresolved
    /// `temporaryDirectory` URL would never string-equal what the guard under test reports,
    /// independent of behavior. `realpath(3)` is what actually matches.
    @discardableResult
    private func makeFile(_ url: URL, contents: String = "x", modified: Date) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    @Test("A nil source directory always reports no stale sources")
    func nilSourceDirectoryReportsNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staleness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("lib.a")
        try makeFile(archive, modified: Date(timeIntervalSince1970: 1000))

        #expect(SchemataRuntimeStalenessGuard.staleSources(archivePath: archive, sourceDirectory: nil).isEmpty)
    }

    @Test("A .h file newer than the archive is reported stale, not just .c")
    func newerHeaderIsStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staleness-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("lib.a")
        try makeFile(archive, modified: Date(timeIntervalSince1970: 1000))
        let header = try makeFile(source.appendingPathComponent("include/mutantkit_protocol_v3.h"), modified: Date(timeIntervalSince1970: 2000))

        let stale = SchemataRuntimeStalenessGuard.staleSources(archivePath: archive, sourceDirectory: source)
        #expect(stale.map(\.path) == [header.path])
    }

    @Test("Files with unrelated extensions never count toward staleness")
    func unrelatedExtensionsIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staleness-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("lib.a")
        try makeFile(archive, modified: Date(timeIntervalSince1970: 1000))
        try makeFile(source.appendingPathComponent("README.md"), modified: Date(timeIntervalSince1970: 2000))
        try makeFile(source.appendingPathComponent(".DS_Store"), modified: Date(timeIntervalSince1970: 2000))

        #expect(SchemataRuntimeStalenessGuard.staleSources(archivePath: archive, sourceDirectory: source).isEmpty)
    }

    @Test("Multiple stale files are all reported, sorted by path")
    func multipleStaleFilesReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staleness-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("lib.a")
        try makeFile(archive, modified: Date(timeIntervalSince1970: 1000))
        let zFile = try makeFile(source.appendingPathComponent("z.c"), modified: Date(timeIntervalSince1970: 2000))
        let aFile = try makeFile(source.appendingPathComponent("a.c"), modified: Date(timeIntervalSince1970: 2000))
        try makeFile(source.appendingPathComponent("old.c"), modified: Date(timeIntervalSince1970: 500))

        let stale = SchemataRuntimeStalenessGuard.staleSources(archivePath: archive, sourceDirectory: source)
        #expect(stale.map(\.path) == [aFile.path, zFile.path])
    }
}
