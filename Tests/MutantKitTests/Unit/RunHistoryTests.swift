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
