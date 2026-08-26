import AppleBuildAdapters
import Foundation
import Testing

@Suite("SwiftPMLinkerInjector")
struct SwiftPMLinkerInjectorTests {
    @Test("Produces -Xlinker -L<dir> -Xlinker -lMutantKitSchemataRuntime, in that order")
    func producesExpectedArguments() {
        let directory = URL(fileURLWithPath: "/tmp/mutantkit-schemata-runtime-lib")
        let arguments = SwiftPMLinkerInjector.extraArguments(libraryDirectory: directory)
        #expect(arguments == ["-Xlinker", "-L/tmp/mutantkit-schemata-runtime-lib", "-Xlinker", "-lMutantKitSchemataRuntime"])
    }
}

@Suite("SchemataRuntimeLibraryLocator")
struct SchemataRuntimeLibraryLocatorTests {
    // Every case here passes `sourceDirectory: nil` explicitly, decoupling these tests from
    // this repo's own real file timestamps: `SchemataRuntimeStalenessGuardTests` covers the
    // staleness check itself in isolation, with fixtures it controls precisely.

    @Test("Missing override throws missingOverride, not a silent no-op — unchanged for .macOS")
    func missingOverrideThrows() {
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.missingOverride) {
            _ = try SchemataRuntimeLibraryLocator.locate(for: .macOS, environment: [:], sourceDirectory: nil)
        }
    }

    @Test("Empty override is treated the same as missing — unchanged for .macOS")
    func emptyOverrideThrows() {
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.missingOverride) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS,
                environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: ""],
                sourceDirectory: nil
            )
        }
    }

    @Test("A .macOS override pointing at a directory with no library file throws libraryNotFound, exactly as before")
    func missingLibraryFileThrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.libraryNotFound(directory: directory.path)) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS,
                environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path],
                sourceDirectory: nil
            )
        }
    }

    @Test("A .macOS override pointing at a directory that genuinely has the library file resolves successfully")
    func validOverrideResolves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryPath = directory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName)
        try Data("fake archive".utf8).write(to: libraryPath)

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS,
            environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path],
            sourceDirectory: nil
        )
        #expect(located.libraryDirectory.path == directory.path)
    }

    @Test("An .iOSSimulator override resolves the iphonesimulator/ subdirectory, not the flat layout")
    func iOSSimulatorResolvesSubdirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        let simulatorDirectory = directory.appendingPathComponent(SchemataRuntimePlatform.iOSSimulator.rawValue)
        try FileManager.default.createDirectory(at: simulatorDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fake simulator archive".utf8).write(
            to: simulatorDirectory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName)
        )

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .iOSSimulator,
            environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path],
            sourceDirectory: nil
        )
        #expect(located.libraryDirectory.path == simulatorDirectory.path)
    }

    @Test(
        "THE regression test for the reported bug: an .iOSSimulator request with only the flat macOS-shaped layout present must refuse, never silently fall back to the macOS archive"
    )
    func iOSSimulatorRefusesFlatMacOSLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Only the flat, macOS-shaped file — no `iphonesimulator/` subdirectory at all.
        try Data("fake macos archive".utf8).write(to: directory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName))

        let simulatorDirectory = directory.appendingPathComponent(SchemataRuntimePlatform.iOSSimulator.rawValue)
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.platformLibraryNotFound(
            platform: .iOSSimulator, searched: simulatorDirectory.path
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .iOSSimulator,
                environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path],
                sourceDirectory: nil
            )
        }
    }

    @Test("An .iOSSimulator request with the env var unset throws missingOverride, same semantics as .macOS")
    func iOSSimulatorMissingOverrideThrows() {
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.missingOverride) {
            _ = try SchemataRuntimeLibraryLocator.locate(for: .iOSSimulator, environment: [:], sourceDirectory: nil)
        }
    }

    @Test("A source directory with a .c file newer than the archive throws staleArchive, not a silent stale link")
    func staleArchiveThrows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        let libraryDirectory = root.appendingPathComponent("lib")
        let sourceDirectory = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let libraryPath = libraryDirectory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName)
        try Data("fake archive".utf8).write(to: libraryPath)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: libraryPath.path)

        let sourceFile = sourceDirectory.appendingPathComponent("mutantkit_protocol_v3.c")
        try Data("int x;".utf8).write(to: sourceFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: sourceFile.path)

        // `FileManager`'s directory enumerator (used inside the staleness guard) reports
        // canonical paths (`/var` symlink resolved to `/private/var`), unlike the plain URL
        // constructed above.
        let canonicalSourceFilePath = realpath(sourceFile.path, nil).map { String(cString: $0) } ?? sourceFile.path
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.staleArchive(
            platform: .macOS, archivePath: libraryPath.path, staleSourcePaths: [canonicalSourceFilePath]
        )) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                for: .macOS,
                environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: libraryDirectory.path],
                sourceDirectory: sourceDirectory
            )
        }
    }

    @Test("A source directory entirely older than the archive resolves successfully — no false positive")
    func freshArchiveResolves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        let libraryDirectory = root.appendingPathComponent("lib")
        let sourceDirectory = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = sourceDirectory.appendingPathComponent("mutantkit_protocol_v3.c")
        try Data("int x;".utf8).write(to: sourceFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: sourceFile.path)

        let libraryPath = libraryDirectory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName)
        try Data("fake archive".utf8).write(to: libraryPath)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: libraryPath.path)

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS,
            environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: libraryDirectory.path],
            sourceDirectory: sourceDirectory
        )
        #expect(located.libraryDirectory.path == libraryDirectory.path)
    }

    @Test("A nil source directory (no checkout found) skips the staleness check entirely, matching V1's unprotected behavior")
    func nilSourceDirectorySkipsStalenessCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fake archive".utf8).write(to: directory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName))

        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS,
            environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path],
            sourceDirectory: nil
        )
        #expect(located.libraryDirectory.path == directory.path)
    }
}
