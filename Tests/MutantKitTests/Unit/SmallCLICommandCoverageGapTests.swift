import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// A handful of small CLI commands had a real code path never reached by
/// any existing test: `PerfCommand`/`SurvivorsCommand`'s own report-decode
/// call (only ever exercised indirectly, if at all), and `InitCommand`/
/// `MigrateCommand`'s "destination already exists, no --force" branch.
/// Each test here drives `Command.parse(...).run()` directly, the same
/// pattern `ExitCodeConsistencyTests` uses, and — like that file — never
/// captures stdout: reaching the line is the point, not what it prints.
@Suite("Small CLI commands: previously unreached branches")
struct SmallCLICommandCoverageGapTests {
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-SmallCLICommandCoverageGapTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - PerfCommand

    @Test("perf against a valid, well-formed report renders without throwing")
    func perfAgainstValidReportSucceeds() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = dir.appendingPathComponent("report.json")
        let report = makeReport(plan: makePlan(mutations: []), results: [])
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try PerfCommand.parse(["--report", reportPath.path])
        try command.run()
    }

    // MARK: - SurvivorsCommand

    @Test("survivors against a valid, well-formed report runs without throwing")
    func survivorsAgainstValidReportSucceeds() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = dir.appendingPathComponent("report.json")
        let report = makeReport(plan: makePlan(mutations: []), results: [])
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try SurvivorsCommand.parse(["--report", reportPath.path])
        try command.run()
    }

    // MARK: - InitCommand

    @Test("init against a project root that already has a mutantkit.yml, without --force, exits operationally")
    func initWithoutForceOverExistingConfigExitsOperationally() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("existing config".utf8).write(to: dir.appendingPathComponent(ConfigurationLoader.fileName))

        let command = try InitCommand.parse(["--project-root", dir.path])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }

    // MARK: - MigrateCommand

    @Test("migrate against an output path that already exists, without --force, exits operationally")
    func migrateWithoutForceOverExistingOutputExitsOperationally() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let muterConfigPath = dir.appendingPathComponent("muter.conf.yml")
        try Data("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """.utf8).write(to: muterConfigPath)

        let outputPath = dir.appendingPathComponent("mutantkit.yml")
        try Data("existing".utf8).write(to: outputPath)

        let command = try MigrateCommand.parse(["--from-muter", muterConfigPath.path, "--output", outputPath.path])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }
}
