import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// P11: `mutantkit config --json` — the validation *result*, not `--schema`
/// (the config file format's JSON Schema, untouched by this phase and not
/// exercised here). `ConfigurationValidationResult` wraps the already-
/// structured `[ConfigurationIssue]` `ConfigurationValidator.validate`
/// returns with `schemaVersion` + a top-level `valid` verdict, mirroring
/// `GateCommandJSONTests`/`DoctorCommandJSONTests`'s shape and reasoning,
/// including their choice not to capture `ConfigCommand`'s own stdout.
@Suite("ConfigCommand: --json")
struct ConfigCommandJSONTests {
    // MARK: - JSON shape

    @Test("--json's JSON is schema-versioned and reports valid true with no issues for a default configuration")
    func validConfigurationJSONShape() throws {
        let result = ConfigurationValidationResult(issues: ConfigurationValidator.validate(Configuration()))

        let data = try MutationPlan.encoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.configurationValidationResult)
        #expect(json["valid"] as? Bool == true)
        let issues = try #require(json["issues"] as? [[String: Any]])
        #expect(issues.isEmpty)

        let decoded = try MutationPlan.decoder().decode(ConfigurationValidationResult.self, from: data)
        #expect(decoded == result)
    }

    @Test("--json's JSON is schema-versioned and reports valid false with a structured issue for an invalid configuration")
    func invalidConfigurationJSONShape() throws {
        var configuration = Configuration()
        configuration.execution.workers = 0
        let result = ConfigurationValidationResult(issues: ConfigurationValidator.validate(configuration))
        #expect(!result.valid)

        let data = try MutationPlan.encoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let issues = try #require(json["issues"] as? [[String: Any]])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.configurationValidationResult)
        #expect(json["valid"] as? Bool == false)
        #expect(issues.contains {
            $0["severity"] as? String == "error" && $0["path"] as? String == "execution.workers"
        })

        let decoded = try MutationPlan.decoder().decode(ConfigurationValidationResult.self, from: data)
        #expect(decoded == result)
    }

    // MARK: - Exit codes still hold with --json

    @Test("config --json against a valid configuration exits 0, same as the text path")
    func validConfigurationJSONDoesNotThrow() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "version: 1\n".write(to: dir.appendingPathComponent("mutantkit.yml"), atomically: true, encoding: .utf8)

        let command = try ConfigCommand.parse(["--json", "--project-root", dir.path])
        try command.run()
    }

    @Test("config --json against an invalid configuration still exits MutantKitExit.operationalError")
    func invalidConfigurationJSONStillThrowsOperationalError() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "version: 1\nexecution:\n  workers: 0\n"
            .write(to: dir.appendingPathComponent("mutantkit.yml"), atomically: true, encoding: .utf8)

        let command = try ConfigCommand.parse(["--json", "--project-root", dir.path])

        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try command.run()
        }
    }

    // MARK: - Helpers

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigCommandJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
