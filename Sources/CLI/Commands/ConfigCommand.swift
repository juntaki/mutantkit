import ArgumentParser
import Foundation
import MutationModel

/// Validates `mutantkit.yml` or emits the JSON Schema used by editors/CI.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Validate MutantKit configuration or print its JSON Schema."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Print the JSON Schema instead of validating the resolved configuration.")
    var schema = false

    /// The validation *result*, not the config file format's JSON Schema
    /// dumped by `--schema` above — a different thing entirely, left
    /// untouched. `ConfigurationIssue` is already `Codable`/`Sendable` with
    /// a structured `severity`/`path`/`message`, so `--json` needed no new
    /// ad hoc issue type, only `ConfigurationValidationResult` to add the
    /// `schemaVersion` + top-level `valid` verdict, mirroring `gate --json`
    /// and `doctor --json`. Exit codes are untouched: this still throws
    /// `MutantKitExit.operationalError` whenever an `.error`-severity issue
    /// is present, regardless of `--json`.
    @Flag(name: .long, help: "Emit the validation result as JSON instead of printing prose diagnostics.")
    var json = false

    func run() throws {
        if schema {
            print(ConfigurationJSONSchema.document)
            return
        }

        let root = common.resolvedProjectRoot
        let configuration = try Self.load(explicitPath: common.configPath, projectRoot: root, json: json)
        let issues = ConfigurationValidator.validate(configuration, projectRoot: root)
        let result = ConfigurationValidationResult(issues: issues)

        if json {
            try JSONOutput.emit(result)
        } else if issues.isEmpty {
            print("Configuration is valid.")
        } else {
            for issue in issues {
                print(issue.description)
            }
        }

        if !result.valid {
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    /// v0.5 Stable Contracts: `--json` previously only enveloped a
    /// *validation* failure (an already-loaded `Configuration` with
    /// `.error`-severity issues) — a *load* failure (missing file,
    /// malformed YAML, an unsupported `version:`) fell straight through to
    /// `ConfigurationLoader.load`'s own thrown error, unmapped, the one gap
    /// `config --json` had that every other `--json`-capable command's own
    /// report-decode path had already closed (see `GateCommand.decode`).
    private static func load(explicitPath: String?, projectRoot: URL, json: Bool) throws -> Configuration {
        do {
            return try ConfigurationLoader.load(explicitPath: explicitPath, projectRoot: projectRoot)
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            try JSONOutput.emitError(
                code: "configurationUnreadable",
                message: "Could not load the configuration: \(error)",
                remedy: "Check --config (or the default mutantkit.yml path) points at a real, valid MutantKit configuration."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
