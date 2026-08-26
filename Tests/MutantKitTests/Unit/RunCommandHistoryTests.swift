import Foundation
@testable import CLI
import MutationModel
import Reporting
import Testing

/// Regression coverage for a bug found during an adversarial review of the
/// product-strategy plan, verified against the source: `RunCommand.run()`
/// used to write to `RunHistoryStore` with a bare `try?`
///
///     try? RunHistoryStore(...).record(report)
///
/// which silently discarded any write failure — a permissions problem, a
/// stray file where `.mutantkit/history` needs to be a directory, a full
/// disk. Nothing about the run's own output or exit code would say so.
///
/// `RunCommand.recordHistory(_:to:stderr:)` is the pulled-out piece of that
/// call site (mirroring how `resolveTestAdapter`/`lockIdentity` are pulled
/// out elsewhere in this file for the same reason): it lets this surfacing
/// behavior be tested directly, without standing up a real project/adapter
/// the way a full `run()` invocation would need.
@Suite("RunCommand: history write surfacing")
struct RunCommandHistoryTests {
    private func tempPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunCommandHistoryTests-\(UUID().uuidString)")
    }

    @Test("A successful write returns no diagnosis, prints nothing, and lands in the store")
    func successfulWriteRecordsSilently() throws {
        let root = tempPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunHistoryStore(root: root)
        let report = makeReport(plan: makePlan(mutations: []), results: [])

        var stderrOutput = ""
        let diagnosis = RunCommand.recordHistory(report, to: store) { stderrOutput += $0 }

        #expect(diagnosis == nil)
        #expect(stderrOutput.isEmpty)
        #expect(store.records().count == 1)
    }

    /// The actual regression: a write failure must be surfaced (a `stderr`
    /// warning, in the same shape `MutationRunner.finalize` already uses for
    /// a checkpoint write failure — see `OperationalIssue`'s doc comment),
    /// not swallowed the way `try?` swallowed it before this fix.
    @Test("A failing write is surfaced to stderr, not swallowed")
    func failingWriteIsSurfacedNotSwallowed() throws {
        let root = tempPath()
        defer { try? FileManager.default.removeItem(at: root) }
        // A plain file sits where `RunHistoryStore.record` needs to create a
        // directory (its first action), so the write fails deterministically
        // without touching real filesystem permissions.
        try Data().write(to: root)

        let store = RunHistoryStore(root: root)
        let report = makeReport(plan: makePlan(mutations: []), results: [])

        var stderrOutput = ""
        let diagnosis = RunCommand.recordHistory(report, to: store) { stderrOutput += $0 }

        #expect(diagnosis != nil, "a history write failure must be surfaced, not silently discarded")
        #expect(stderrOutput.contains("warning:"), "surfaced the same way a checkpoint write failure is")
        #expect(stderrOutput.contains(report.planID), "the diagnosis should name which run failed to record")
    }

    /// `--no-history` defaults to `false`, so a plain, unsharded `mutantkit
    /// run` keeps writing to history exactly as it always has — only a shard
    /// of a sharded plan is expected to opt out (see the design note on the
    /// flag itself in `RunCommand.swift`, and `MergeCommandHistoryTests` for
    /// the other half: `merge` always records the real, combined result).
    @Test("--no-history defaults to false and parses when passed")
    func noHistoryFlagDefaultsFalseAndParses() throws {
        let defaulted = try RunCommand.parse([])
        #expect(defaulted.noHistory == false)

        let opted = try RunCommand.parse(["--no-history"])
        #expect(opted.noHistory == true)
    }
}
