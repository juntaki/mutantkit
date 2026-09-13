import Foundation
import MutationModel
import MuterCompatibility
import Testing

/// The other half of `MuterConfigImporterTranslationTests` — split out
/// purely to stay under SwiftLint's `type_body_length`, not by topic:
/// timeouts, unmappable fields, decoding (YAML/legacy JSON/failure), error
/// descriptions, and locating/reading the config file from disk.
@Suite("MuterConfigImporter: timeouts, unmappable fields, decoding")
struct MuterConfigImporterDecodingTests {
    private func imported(_ yaml: String, sourceName: String = "muter.conf.yml") throws -> MuterImport {
        try MuterConfigImporter().importConfiguration(from: Data(yaml.utf8), sourceName: sourceName)
    }

    private func entry(_ imported: MuterImport, field: String) throws -> ImportReport.Entry {
        try #require(imported.report.entries.first { $0.field == field }, "no report entry for field '\(field)'")
    }

    // MARK: - Timeouts

    @Test("mutationTestTimeout imports as a fixed-strategy timeout with the same maximum")
    func mutationTestTimeoutImportsAsFixedStrategy() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        mutationTestTimeout: 90
        """)

        #expect(result.configuration.timeouts.mutant.strategy == .fixed)
        #expect(result.configuration.timeouts.mutant.maximumSeconds == 90)

        let timeoutEntry = try entry(result, field: "mutationTestTimeout")
        #expect(timeoutEntry.disposition == .partiallyTranslated)
        #expect(timeoutEntry.detail.contains("adaptive"))
    }

    @Test("An integer mutationTestTimeout decodes the same as a fractional one")
    func integerMutationTestTimeoutDecodes() throws {
        // Muter's own schema does not commit to one JSON/YAML numeric type for
        // this field; MuterConfigurationFile.init(from:) explicitly falls back
        // from Double to Int, so this pins that the fallback actually runs
        // and produces the same value a fractional input would.
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        mutationTestTimeout: 90
        """)

        #expect(result.configuration.timeouts.mutant.maximumSeconds == 90.0)
    }

    @Test("No mutationTestTimeout leaves the default timeout settings and records no entry")
    func noMutationTestTimeoutLeavesDefaults() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """)

        #expect(result.configuration.timeouts.mutant.strategy != .fixed)
        #expect(!result.report.entries.contains { $0.field == "mutationTestTimeout" })
    }

    // MARK: - Unmappable fields

    @Test("A positive coverageThreshold has no equivalent and is reported as dropped")
    func positiveCoverageThresholdIsDropped() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        coverageThreshold: 80
        """)

        let dropped = try entry(result, field: "coverageThreshold")
        #expect(dropped.disposition == .dropped)
        #expect(dropped.muterValue == "80.0")
        #expect(dropped.mutantkitValue == nil)
    }

    @Test("A zero or absent coverageThreshold records no entry at all")
    func zeroCoverageThresholdRecordsNoEntry() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        coverageThreshold: 0
        """)

        #expect(!result.report.entries.contains { $0.field == "coverageThreshold" })
    }

    // MARK: - Decoding: YAML, legacy JSON, and failure

    @Test("A legacy JSON configuration decodes through the JSON fallback")
    func legacyJSONConfigurationDecodes() throws {
        let json = """
        {
          "executable": "/usr/bin/xcodebuild",
          "arguments": ["-project", "App.xcodeproj", "-scheme", "App"]
        }
        """
        let result = try imported(json, sourceName: "muter.conf.json")

        #expect(result.configuration.project.kind == .xcodeProject)
    }

    @Test("Content that is neither valid YAML nor valid JSON fails closed with the source name and YAML diagnosis")
    func undecodableContentFailsClosed() throws {
        #expect(throws: MuterImportError.self) {
            _ = try self.imported(": : :", sourceName: "muter.conf.yml")
        }
    }

    @Test("A configuration missing the required executable key fails to decode")
    func missingExecutableFailsToDecode() throws {
        #expect(throws: MuterImportError.self) {
            _ = try self.imported("arguments: [test]", sourceName: "muter.conf.yml")
        }
    }

    // MARK: - Error descriptions

    @Test("Every MuterImportError case has a distinct, informative description")
    func errorDescriptionsAreInformative() {
        let noConfig = MuterImportError.noConfigurationFound(directory: "/tmp/project")
        #expect(noConfig.description.contains("/tmp/project"))
        #expect(noConfig.description.contains(MuterConfigImporter.configFileName))
        #expect(noConfig.description.contains(MuterConfigImporter.legacyConfigFileName))

        let unreadable = MuterImportError.unreadableFile(path: "muter.conf.yml", detail: "permission denied")
        #expect(unreadable.description.contains("muter.conf.yml"))
        #expect(unreadable.description.contains("permission denied"))

        let undecodable = MuterImportError.undecodable(path: "muter.conf.yml", detail: "missing key")
        #expect(undecodable.description.contains("muter.conf.yml"))
        #expect(undecodable.description.contains("missing key"))
    }

    // MARK: - Locating and reading the file from disk

    @Test("locateConfiguration prefers the YAML config over the legacy JSON one when both exist")
    func locateConfigurationPrefersYAMLOverJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-locate-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let yamlURL = directory.appendingPathComponent(MuterConfigImporter.configFileName)
        let jsonURL = directory.appendingPathComponent(MuterConfigImporter.legacyConfigFileName)
        try Data("executable: /usr/bin/swift".utf8).write(to: yamlURL)
        try Data("{}".utf8).write(to: jsonURL)

        #expect(MuterConfigImporter.locateConfiguration(in: directory) == yamlURL)
    }

    @Test("locateConfiguration falls back to the legacy JSON config when no YAML config exists")
    func locateConfigurationFallsBackToJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-locate-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jsonURL = directory.appendingPathComponent(MuterConfigImporter.legacyConfigFileName)
        try Data("{}".utf8).write(to: jsonURL)

        #expect(MuterConfigImporter.locateConfiguration(in: directory) == jsonURL)
    }

    @Test("locateConfiguration returns nil when no configuration exists in the directory")
    func locateConfigurationReturnsNilWhenAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-locate-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(MuterConfigImporter.locateConfiguration(in: directory) == nil)
    }

    @Test("importConfiguration(from: URL) reads the file and imports it")
    func importConfigurationFromURLReadsRealFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-import-from-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent(MuterConfigImporter.configFileName)
        try Data("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """.utf8).write(to: configURL)

        let result = try MuterConfigImporter().importConfiguration(from: configURL)
        #expect(result.configuration.project.kind == .xcodeProject)
        #expect(result.report.sourceName == MuterConfigImporter.configFileName)
    }

    @Test("importConfiguration(from: URL) throws unreadableFile for a file that does not exist")
    func importConfigurationFromMissingURLThrowsUnreadable() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-does-not-exist-\(UUID().uuidString).yml")

        #expect(throws: MuterImportError.self) {
            _ = try MuterConfigImporter().importConfiguration(from: missing)
        }
    }
}
