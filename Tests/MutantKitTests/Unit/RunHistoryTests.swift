import Foundation
import MutationModel
import Reporting
import Testing

@Suite("Run history")
struct RunHistoryTests {
    @Test("records and reads newest runs first")
    func recordsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunHistoryStore(root: root)

        try store.record(report(planID: "older", finishedAt: Date(timeIntervalSince1970: 10)))
        try store.record(report(planID: "newer", finishedAt: Date(timeIntervalSince1970: 20)))

        let records = store.records()
        #expect(records.map(\.planID) == ["newer", "older"])
        #expect(try records.allSatisfy(\.integrityPassed))
        #expect(records.allSatisfy { $0.schemaVersion == SchemaVersion.runHistoryRecord })
    }

    /// A history file written before `schemaVersion` existed has no such
    /// key. Decoding that as a hard failure would silently drop every
    /// history record recorded before this change from `mutantkit
    /// history` — `RunHistoryStore.records()` only ever surfaces what it
    /// can decode (see its own `compactMap`), so a decode failure here
    /// would not even show up as an error, just a shorter list.
    @Test("A history file predating schemaVersion still decodes, defaulting to the current version")
    func preExistingHistoryFileWithoutSchemaVersionStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyJSON = """
        {
          "planID": "legacy-plan",
          "finishedAt": "2024-01-01T00:00:00Z",
          "integrityPassed": true,
          "wallClockSeconds": 12.5,
          "toolVersion": "0.1.0"
        }
        """
        try Data(legacyJSON.utf8).write(to: root.appendingPathComponent("legacy.json"), options: .atomic)

        let records = RunHistoryStore(root: root).records()
        let record = try #require(records.first)
        #expect(record.planID == "legacy-plan")
        #expect(record.schemaVersion == SchemaVersion.runHistoryRecord)
    }

    private func report(planID: String, finishedAt: Date) -> RunReport {
        RunReport(
            planID: planID,
            startedAt: finishedAt.addingTimeInterval(-5),
            finishedAt: finishedAt,
            projectRoot: "/tmp/fixture",
            toolchain: ToolchainFingerprint(
                toolVersion: "test",
                toolCommitSHA: nil,
                swiftVersion: "test",
                swiftSyntaxVersion: "test",
                xcodeVersion: nil
            ),
            baseline: BaselineRecord(
                passed: true,
                testSummary: nil,
                durationSeconds: 1,
                buildProductHash: nil,
                buildCommand: nil,
                testCommand: nil
            ),
            ledger: ResultLedger<MutationResult>(),
            integrity: IntegrityReport(
                discovered: 0,
                planned: 0,
                sourceApplied: 0,
                buildObserved: 0,
                buildFailures: 0,
                executed: 0,
                classified: 0,
                reported: 0,
                explicitlySkipped: 0,
                violations: []
            )
        )
    }
}
