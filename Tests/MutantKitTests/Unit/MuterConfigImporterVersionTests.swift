import Foundation
import MutationModel
import MuterCompatibility
import Testing

/// `Configuration.version` used to reach imported files only through
/// `Configuration.init`'s implicit default (1). This suite pins down that the
/// importer now stamps it explicitly and says so in the report, so a reader
/// can tell "tool-authored, version known" apart from a hand-written config
/// that gets the same value by omitting the field entirely.
@Suite("MuterConfigImporter: version stamping")
struct MuterConfigImporterVersionTests {
    private func importedConfiguration() throws -> MuterImport {
        let yaml = """
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """
        return try MuterConfigImporter().importConfiguration(from: Data(yaml.utf8), sourceName: "muter.conf.yml")
    }

    @Test("The imported configuration has version stamped explicitly")
    func importedConfigurationHasVersionStamped() throws {
        let imported = try importedConfiguration()

        #expect(imported.configuration.version == 1)
    }

    @Test("The report calls out the version stamp as tool-authored, not defaulted")
    func reportRecordsTheVersionStamp() throws {
        let imported = try importedConfiguration()

        let entry = try #require(imported.report.entries.first { $0.field == "version" })
        #expect(entry.disposition == .translated)
        #expect(entry.mutantkitValue == "version: 1")
        #expect(entry.detail.contains("tool-authored"))

        #expect(imported.report.rendered().contains("tool-authored"))
    }
}
