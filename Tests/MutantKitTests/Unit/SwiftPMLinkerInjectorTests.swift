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
    @Test("Missing override throws missingOverride, not a silent no-op")
    func missingOverrideThrows() {
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.missingOverride) {
            _ = try SchemataRuntimeLibraryLocator.locate(environment: [:])
        }
    }

    @Test("Empty override is treated the same as missing")
    func emptyOverrideThrows() {
        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.missingOverride) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: ""]
            )
        }
    }

    @Test("An override pointing at a directory with no library file throws libraryNotFound")
    func missingLibraryFileThrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: SchemataRuntimeLibraryLocator.LocatorError.libraryNotFound(directory: directory.path)) {
            _ = try SchemataRuntimeLibraryLocator.locate(
                environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path]
            )
        }
    }

    @Test("An override pointing at a directory that genuinely has the library file resolves successfully")
    func validOverrideResolves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryPath = directory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName)
        try Data("fake archive".utf8).write(to: libraryPath)

        let located = try SchemataRuntimeLibraryLocator.locate(
            environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: directory.path]
        )
        #expect(located.libraryDirectory.path == directory.path)
    }
}
