@testable import CLI
import Foundation
import MutationModel
import Testing

/// `ReadinessCheck.run(root:configuration:skipBuild:)` diagnoses a
/// `Configuration` value handed to it directly, instead of loading one from
/// a path on disk — the fix for `mutantkit setup --dry-run` previewing one
/// config while diagnosing whatever else already happened to be on disk.
///
/// Each test below plants a *different*, deliberately disagreeing config on
/// disk at the same root than the one passed in memory, so the two entry
/// points would answer differently if the in-memory one were not actually
/// wired up to diagnose what was passed to it — the exact bug this proves
/// fixed.
@Suite("ReadinessCheck: diagnosing an in-memory Configuration")
struct ReadinessCheckInMemoryConfigurationTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-ReadinessCheckInMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `execution.workers: 0` is a real `ConfigurationValidator` error
    /// ("Must be at least 1"), not a contrived one — the same check
    /// `mutantkit doctor`/`plan`/`run` all rely on already.
    private func invalidConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.project.kind = .swiftPackageMacOS
        configuration.execution.workers = 0
        return configuration
    }

    private func validConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.project.kind = .swiftPackageMacOS
        return configuration
    }

    @Test("An in-memory config's own failure is diagnosed even when the on-disk file at the same root is valid")
    func inMemoryFailureIsDiagnosedOverValidOnDiskFile() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A perfectly valid mutantkit.yml sits on disk — if the in-memory
        // entry point were secretly still reading from disk (the bug this
        // fixes), this would report ready.
        try Data("""
        version: 1
        project:
          kind: swiftPackageMacOS
        """.utf8).write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let outcome = await ReadinessCheck.run(root: directory, configuration: invalidConfiguration(), skipBuild: true)

        #expect(!outcome.diagnosis.canProceed, "the in-memory config's own workers:0 error must fail readiness")
        let configItem = outcome.diagnosis.items.first { $0.name == "Configuration" }
        #expect(configItem?.status == .failure)
        #expect(configItem?.detail.contains("execution.workers") == true, "\(String(describing: configItem))")
    }

    @Test("An in-memory config's own success is diagnosed even when the on-disk file at the same root is invalid")
    func inMemorySuccessIsDiagnosedOverInvalidOnDiskFile() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The file on disk would fail readiness on its own (workers: 0) — if
        // the in-memory entry point silently fell back to it, this would
        // report not-ready despite the passed-in config being fine.
        try Data("""
        version: 1
        project:
          kind: swiftPackageMacOS
        execution:
          workers: 0
        """.utf8).write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let diskBased = await ReadinessCheck.run(root: directory, configPath: nil, skipBuild: true)
        #expect(!diskBased.diagnosis.canProceed, "sanity check: the on-disk file alone must fail readiness")

        let inMemory = await ReadinessCheck.run(root: directory, configuration: validConfiguration(), skipBuild: true)
        #expect(inMemory.diagnosis.canProceed, "\(ReadinessCheck.render(inMemory.diagnosis))")
        #expect(inMemory.diagnosis.items.first { $0.name == "Configuration" } == nil)
    }
}
