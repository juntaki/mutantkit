import Foundation
import MuterCompatibility
import MutationModel
import Testing

/// `MuterConfigImporter` had no dedicated test coverage before this file —
/// found while wiring `excludeCalls`' migration for Phase C3
/// (competitive-parity program). Scoped narrowly to that one field rather
/// than attempting full importer coverage in the same pass.
@Suite("MuterConfigImporter: excludeCalls migration")
struct MuterConfigImporterExcludeCallsTests {
    private func importedConfiguration(excludeCalls: [String]) throws -> MuterImport {
        let excludeCallsBlock = excludeCalls.isEmpty
            ? ""
            : "excludeCalls:\n\(excludeCalls.map { "  - \($0)" }.joined(separator: "\n"))\n"
        let yaml = """
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        \(excludeCallsBlock)
        """
        return try MuterConfigImporter().importConfiguration(from: Data(yaml.utf8), sourceName: "muter.conf.yml")
    }

    @Test("excludeCalls maps onto operators.sideEffectCallRemoval.excludeCalls, not dropped")
    func excludeCallsMapsOntoOperatorSettings() throws {
        let imported = try importedConfiguration(excludeCalls: ["print", "myLogger.record"])

        #expect(imported.configuration.operators.sideEffectCallRemoval?.excludeCalls == ["print", "myLogger.record"])

        let entry = try #require(imported.report.entries.first { $0.field == "excludeCalls" })
        #expect(entry.disposition == .partiallyTranslated)
        #expect(entry.mutantkitValue?.contains("sideEffectCallRemoval") == true)
    }

    @Test("Importing does not itself enable the experimental operator")
    func importingDoesNotEnableTheOperator() throws {
        let imported = try importedConfiguration(excludeCalls: ["print"])

        #expect(imported.configuration.operators.profile == .default)
        #expect(!imported.configuration.operators.enable.contains("swift.core.side-effect-call-removal"))
    }

    @Test("An empty excludeCalls list produces no entry and no sideEffectCallRemoval settings")
    func emptyExcludeCallsProducesNothing() throws {
        let imported = try importedConfiguration(excludeCalls: [])

        #expect(imported.configuration.operators.sideEffectCallRemoval == nil)
        #expect(!imported.report.entries.contains { $0.field == "excludeCalls" })
    }
}
