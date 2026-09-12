@testable import CLI
import MutationModel
import Testing

/// `ConfigurationLoader.parse` decodes a `mutantkit.yml`-shaped YAML string
/// directly — the entry point `mutantkit setup`/`setup --dry-run` use so
/// they diagnose the exact `Configuration` they are about to write (or would
/// write), parsed from `ProjectDetectionPlan`'s own generated template text,
/// instead of one independently re-read from a path on disk.
@Suite("ConfigurationLoader.parse")
struct ConfigurationLoaderParseTests {
    @Test("Decodes the same fields ConfigurationLoader.load would, from text instead of a file")
    func decodesFieldsFromText() throws {
        let configuration = try ConfigurationLoader.parse("""
        version: 1
        project:
          kind: xcodeProject
          scheme: MyApp
        tests:
          targets:
            - MyAppTests
        """, environment: [:])

        #expect(configuration.project.kind == .xcodeProject)
        #expect(configuration.project.scheme == "MyApp")
        #expect(configuration.tests.targets == ["MyAppTests"])
    }

    @Test("Applies environment overrides the same way ConfigurationLoader.load does")
    func appliesEnvironmentOverrides() throws {
        let configuration = try ConfigurationLoader.parse(
            "version: 1\nproject:\n  kind: auto\n",
            environment: ["MUTANTKIT_SCHEME": "FromEnvironment"]
        )
        #expect(configuration.project.scheme == "FromEnvironment")
    }

    @Test("Rejects an unsupported schema version, matching ConfigurationLoader.load's own check")
    func rejectsUnsupportedVersion() {
        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.parse("version: 2\n", environment: [:])
        }
    }

    /// v1 config precedence contract (2026-09-12): CLI > project config file
    /// > environment > built-in defaults, with no exception for
    /// `operators.profile`. Before this fix, `MUTANTKIT_OPERATOR_PROFILE`
    /// unconditionally overwrote `configuration.operators.profile` because
    /// the decoded value (`.default`) is indistinguishable from "the file
    /// never mentioned profile at all" without checking the raw YAML.
    @Test("An explicit operators.profile in the config file wins over MUTANTKIT_OPERATOR_PROFILE, even matching the default")
    func explicitOperatorProfileBeatsEnvironment() throws {
        let configuration = try ConfigurationLoader.parse(
            "version: 1\nproject:\n  kind: auto\noperators:\n  profile: default\n",
            environment: ["MUTANTKIT_OPERATOR_PROFILE": "experimental"]
        )
        #expect(configuration.operators.profile == .default)
    }

    @Test("MUTANTKIT_OPERATOR_PROFILE fills the gap when the config file never mentions operators.profile")
    func environmentOperatorProfileFillsAnUnsetGap() throws {
        let configuration = try ConfigurationLoader.parse(
            "version: 1\nproject:\n  kind: auto\n",
            environment: ["MUTANTKIT_OPERATOR_PROFILE": "experimental"]
        )
        #expect(configuration.operators.profile == .experimental)
    }

    @Test("An unrecognized MUTANTKIT_OPERATOR_PROFILE value fails closed instead of silently keeping the default")
    func unknownEnvironmentOperatorProfileFailsClosed() {
        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.parse(
                "version: 1\nproject:\n  kind: auto\n",
                environment: ["MUTANTKIT_OPERATOR_PROFILE": "not-a-real-profile"]
            )
        }
    }

    @Test("A non-numeric MUTANTKIT_WORKERS fails closed instead of silently keeping the default")
    func nonNumericEnvironmentWorkersFailsClosed() {
        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.parse(
                "version: 1\nproject:\n  kind: auto\n",
                environment: ["MUTANTKIT_WORKERS": "abc"]
            )
        }
    }

    @Test("A zero or negative MUTANTKIT_WORKERS fails closed instead of silently keeping the default")
    func nonPositiveEnvironmentWorkersFailsClosed() {
        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.parse(
                "version: 1\nproject:\n  kind: auto\n",
                environment: ["MUTANTKIT_WORKERS": "0"]
            )
        }
    }

    @Test("execution.workers explicitly set in the config file wins over MUTANTKIT_WORKERS")
    func explicitWorkersBeatsEnvironment() throws {
        let configuration = try ConfigurationLoader.parse(
            "version: 1\nproject:\n  kind: auto\nexecution:\n  workers: 3\n",
            environment: ["MUTANTKIT_WORKERS": "9"]
        )
        #expect(configuration.execution.workers == 3)
    }

    /// v0.5 Stable Contracts: an unrecognized key, at any level, is
    /// currently ignored rather than rejected by the decoder itself — the
    /// JSON Schema's `additionalProperties: false` is only ever advertised
    /// to a schema-aware editor (`ConfigurationSchemaParityTests
    /// .typoNestedKeyIsRejectedByTheSchema` pins that half), never enforced
    /// by `ConfigurationLoader`/`mutantkit config` at load time (see
    /// `ConfigurationValidation.swift`'s own comment on this exact gap).
    /// That behavior was previously correct-but-unpinned: nothing failed if
    /// it silently changed (e.g. a Yams/Codable version bump adding strict
    /// unknown-key rejection). This locks it in as an explicit, enforced
    /// contract rather than an artifact of how `Codable` happens to behave
    /// today.
    @Test("An unrecognized key, top-level or nested, is silently ignored rather than rejected")
    func unrecognizedKeysAreIgnored() throws {
        let configuration = try ConfigurationLoader.parse("""
        version: 1
        bogusTopLevelKey: 1
        project:
          kind: xcodeProject
          scheme: MyApp
        execution:
          workerz: 4
        tests:
          targets:
            - MyAppTests
        """, environment: [:])

        #expect(configuration.project.kind == .xcodeProject)
        #expect(configuration.project.scheme == "MyApp")
        #expect(configuration.tests.targets == ["MyAppTests"])
        #expect(
            configuration.execution.workers == Configuration().execution.workers,
            "the typo'd 'workerz' must not affect the real 'workers' default"
        )
    }

    @Test("ProjectDetectionPlan's own generated template always parses back cleanly")
    func detectionPlanTemplateRoundTrips() throws {
        for kind: ProjectKind in [.auto, .swiftPackageMacOS, .swiftPackageApple, .xcodeProject, .xcodeWorkspace] {
            let template = ConfigurationLoader.template(for: kind, scheme: nil, destination: nil, testTargets: [])
            let configuration = try ConfigurationLoader.parse(template, environment: [:])
            #expect(configuration.project.kind == kind)
        }
    }
}
