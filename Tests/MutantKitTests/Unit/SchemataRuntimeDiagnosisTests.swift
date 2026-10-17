import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import Testing

/// `doctor` must reveal a missing or unverified schemata runtime before a run, because without it
/// every schemata chunk build fails while the run still exits 0.
@Suite("Doctor: schemata runtime preflight")
struct SchemataRuntimeDiagnosisTests {
    private func emptyInstallDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("no bundled runtime and no override is a warning that names the override variable")
    func missingRuntimeIsAWarning() throws {
        let install = try emptyInstallDirectory().appendingPathComponent("mutantkit")
        let item = SchemataRuntimeDiagnosis.item(required: false, environment: [:], executableURL: install)
        #expect(item.code == .schemataRuntime)
        #expect(item.status == .warning)
        #expect(item.remedy?.contains(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) == true)
        #expect(item.detail.contains("not usable"))
    }

    @Test("the same condition is a failure when the runtime is required")
    func missingRuntimeFailsWhenRequired() throws {
        let install = try emptyInstallDirectory().appendingPathComponent("mutantkit")
        #expect(SchemataRuntimeDiagnosis.item(required: true, environment: [:], executableURL: install).status == .failure)
    }

    @Test("an explicit override is reported as an override, never as a verified bundled runtime")
    func overrideIsShownExplicitly() throws {
        let dir = try emptyInstallDirectory()
        try Data("!<arch>\n".utf8).write(to: dir.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName))
        let item = SchemataRuntimeDiagnosis.item(
            required: false, environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: dir.path],
            executableURL: dir.appendingPathComponent("mutantkit")
        )
        #expect(item.status == .warning)
        #expect(item.detail.contains("developer override"))
        #expect(item.detail.contains("not digest- or ABI-verified"))
    }

    @Test("an override directory without the archive is not usable")
    func overrideWithoutArchive() throws {
        let dir = try emptyInstallDirectory()
        let item = SchemataRuntimeDiagnosis.item(
            required: true, environment: [SchemataRuntimeLibraryLocator.overrideEnvironmentVariable: dir.path],
            executableURL: dir.appendingPathComponent("mutantkit")
        )
        #expect(item.status == .failure)
    }
}
