@testable import CLI
import Foundation
import Testing

/// AUDIT-FINDINGS.md: "mutantkit init/setup's final 'next step' message can
/// point at the wrong next command (doctor printed 'Next: mutantkit init'
/// even when mutantkit.yml already existed and was in active use from
/// setup)".
///
/// Root cause: `DoctorCommand.run()`'s final "Ready." line used to be a
/// single hardcoded string recommending `mutantkit init` unconditionally,
/// with no check at all for whether a `mutantkit.yml` was already present
/// and in use. `DoctorCommand.nextStepMessage(configExists:)` is the fix,
/// factored out of `run()` precisely so both branches are exercisable here
/// without capturing this command's own stdout (no precedent for shared-fd
/// capture in this repo — see `DoctorCommandJSONTests`'s own note).
@Suite("DoctorCommand: next-step message reflects whether a config already exists")
struct DoctorNextStepMessageTests {
    @Test("No config on disk yet: still recommends `mutantkit init`")
    func recommendsInitWhenNoConfigExists() {
        let message = DoctorCommand.nextStepMessage(configExists: false)
        #expect(message.contains("mutantkit init"))
    }

    @Test("A config already exists (already validated by the time this line runs, per run()'s own comment): no longer recommends init")
    func doesNotRecommendInitWhenConfigAlreadyExists() {
        let message = DoctorCommand.nextStepMessage(configExists: true)
        #expect(!message.contains("mutantkit init"))
        #expect(message.contains("mutantkit plan"))
    }

    /// End-to-end version of the same fix, through the real path `run()`
    /// takes: `ConfigurationLoader.locate` against an actual `mutantkit.yml`
    /// on disk, not a hand-passed boolean.
    @Test("A real mutantkit.yml on disk resolves as \"config exists\" via ConfigurationLoader.locate")
    func realConfigFileOnDiskIsDetectedAsExisting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoctorNextStepMessageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "version: 1\n".write(to: dir.appendingPathComponent("mutantkit.yml"), atomically: true, encoding: .utf8)

        let configExists = (try? ConfigurationLoader.locate(explicitPath: nil, projectRoot: dir)) != nil
        #expect(configExists)
        #expect(!DoctorCommand.nextStepMessage(configExists: configExists).contains("mutantkit init"))
    }

    @Test("No mutantkit.yml on disk resolves as \"config does not exist\" via ConfigurationLoader.locate")
    func missingConfigFileIsDetectedAsAbsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoctorNextStepMessageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configExists = (try? ConfigurationLoader.locate(explicitPath: nil, projectRoot: dir)) != nil
        #expect(!configExists)
        #expect(DoctorCommand.nextStepMessage(configExists: configExists).contains("mutantkit init"))
    }
}
