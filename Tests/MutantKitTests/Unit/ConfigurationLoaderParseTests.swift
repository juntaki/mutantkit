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

    @Test("ProjectDetectionPlan's own generated template always parses back cleanly")
    func detectionPlanTemplateRoundTrips() throws {
        for kind: ProjectKind in [.auto, .swiftPackageMacOS, .swiftPackageApple, .xcodeProject, .xcodeWorkspace] {
            let template = ConfigurationLoader.template(for: kind, scheme: nil, destination: nil, testTargets: [])
            let configuration = try ConfigurationLoader.parse(template, environment: [:])
            #expect(configuration.project.kind == kind)
        }
    }
}
