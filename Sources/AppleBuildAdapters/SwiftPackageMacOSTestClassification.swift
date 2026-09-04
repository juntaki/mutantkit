import Foundation
import MutationExecution
import MutationModel

extension SwiftPackageMacOSAdapter {
    /// Classifies a `swift test` run from its exit status and its xunit report.
    ///
    /// `swift test` writes no `.xcresult`, but `--xunit-output` gives it a
    /// structured record all the same, so the console text is still never parsed.
    /// The exit status decides the verdict — it is a contract of the tool — while
    /// the xunit report supplies the counts and the names of the tests that
    /// caught the mutant. When no report was written the counts are reported as
    /// unknown rather than invented: a fabricated "1 test failed" would be
    /// indistinguishable downstream from a measured one.
    ///
    /// - Parameter reliableExpectedTestCount: how many tests a narrowed,
    ///   all-Swift-Testing selection named (`TestIdentifier.isSwiftTestingShaped`),
    ///   or `nil` for an unnarrowed run, or a selection that includes an
    ///   XCTest identifier. `swift test --filter` exits 0 even when it
    ///   selects zero tests (P12-B Finding C, confirmed live: SwiftPM emits
    ///   `warning: No matching test cases were run` on stderr and still
    ///   exits 0) — a run that tested nothing must never be indistinguishable
    ///   from one that passed. Restricted to all-Swift-Testing selections
    ///   because Swift Testing's own `--xunit-output` sibling report
    ///   (`XUnitParser`) reflects real executed counts unconditionally,
    ///   while XCTest's report is written only when `tests.parallel` is on
    ///   — under the (safe) default, an XCTest identifier's absence from it
    ///   proves nothing, so mixing frameworks or trusting an XCTest-only
    ///   selection here would misclassify a real, passing default-config
    ///   run as a shortfall.
    static func classify(
        result: ProcessResult,
        command: CommandRecord,
        xunitOutput: URL? = nil,
        reliableExpectedTestCount: Int? = nil
    ) -> TestRunResult {
        let summary = xunitOutput.flatMap { XUnitParser.summary(forRequestedOutput: $0) }
        if result.timedOut {
            return TestRunResult(
                status: .timedOut,
                summary: nil,
                command: command,
                resultArtifactPath: nil,
                diagnosis: """
                The test run exceeded its time limit and was terminated after \
                \(String(format: "%.1f", result.durationSeconds))s.
                """
            )
        }

        if let signal = result.terminatingSignal {
            return TestRunResult(
                status: .crashed,
                summary: nil,
                command: command,
                resultArtifactPath: nil,
                diagnosis: "The test process was killed by signal \(signal)."
            )
        }

        if result.exitCode == 0 {
            if let shortfall = narrowedSelectionShortfall(
                summary: summary, command: command, xunitOutput: xunitOutput, reliableExpectedTestCount: reliableExpectedTestCount
            ) {
                return shortfall
            }

            if let contradiction = exitZeroXUnitContradiction(summary: summary, command: command, xunitOutput: xunitOutput) {
                return contradiction
            }

            return TestRunResult(
                status: .passed,
                summary: summary,
                command: command,
                resultArtifactPath: xunitOutput,
                diagnosis: summary.map { "swift test exited successfully; all \($0.total) tests passed." }
                    ?? "swift test exited successfully; every test passed."
            )
        }

        // A failing suite exits 1. Anything else means the runner could not do its
        // job — a missing bundle, a dyld failure — which is not the mutant's doing.
        guard result.exitCode == 1 else {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: command,
                resultArtifactPath: nil,
                diagnosis: """
                swift test exited with \(result.exitCode), which indicates it could \
                not run the suite rather than that a test failed: \
                \(OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 300)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                """
            )
        }

        if let contradiction = exitOneXUnitContradiction(summary: summary, command: command, xunitOutput: xunitOutput) {
            return contradiction
        }

        return TestRunResult(
            status: .failed,
            summary: summary,
            command: command,
            resultArtifactPath: xunitOutput,
            diagnosis: summary.map { report in
                let caught = report.failingTests.prefix(3).joined(separator: ", ")
                return caught.isEmpty
                    ? "swift test exited with 1: \(report.failed) of \(report.total) tests failed."
                    : "swift test exited with 1: \(report.failed) of \(report.total) tests failed, caught by \(caught)."
            } ?? "swift test exited with 1: at least one test failed."
        )
    }

    /// `nil` (no xunit report parsed at all -- missing, unreadable, or
    /// `xunitOutput` itself absent) is treated as zero executed, not as
    /// "unknown, so don't check" (codex review, P12-B Phase B3): for a
    /// narrowed selection, no evidence that anything ran is exactly as
    /// unsafe to call a pass as evidence that zero things ran. `nil` when
    /// `reliableExpectedTestCount` is `nil` (an unnarrowed run) or when
    /// enough tests were actually executed.
    private static func narrowedSelectionShortfall(
        summary: TestOutcomeSummary?, command: CommandRecord, xunitOutput: URL?, reliableExpectedTestCount: Int?
    ) -> TestRunResult? {
        guard let reliableExpectedTestCount else { return nil }
        let executedCount = xunitOutput.flatMap { XUnitParser.swiftTestingExecutedCount(forRequestedOutput: $0) }
        guard (executedCount ?? 0) < reliableExpectedTestCount else { return nil }
        return TestRunResult(
            status: .infrastructureFailure,
            summary: summary,
            command: command,
            resultArtifactPath: xunitOutput,
            diagnosis: """
            This run was narrowed to \(reliableExpectedTestCount) Swift Testing test(s), but the \
            xunit report records only \(executedCount.map(String.init) ?? "no") executed. Something \
            in the selection did not run and left no failure record explaining why, so the \
            shortfall is not scored as a pass.
            """
        )
    }

    /// `swift test` exiting 0 is a contract that nothing failed, but the
    /// xunit report is a second, independent witness to the same claim --
    /// when it disagrees (a real failure count under a success exit code),
    /// the run itself is untrustworthy, not merely "passing." The mirror-
    /// image contradiction (`exitOneXUnitContradiction`, below) is a real
    /// bug this fix responds to; this closes the same gap in the other
    /// direction before it can produce a false pass. `nil` when there is no
    /// contradiction to report.
    private static func exitZeroXUnitContradiction(
        summary: TestOutcomeSummary?, command: CommandRecord, xunitOutput: URL?
    ) -> TestRunResult? {
        guard let summary, summary.failed > 0 else { return nil }
        return TestRunResult(
            status: .infrastructureFailure,
            summary: summary,
            command: command,
            resultArtifactPath: xunitOutput,
            diagnosis: """
            swift test exited 0 (success), but its own xunit report records \(summary.failed) of \
            \(summary.total) test(s) failed. This exit/xunit contradiction is not trusted as a pass.
            """
        )
    }

    /// Exit 1 claims a real assertion failure, but the xunit report is the
    /// structured evidence for *which* one -- when it exists and records
    /// zero, the two signals contradict each other. This is a real, observed
    /// failure mode (a `killedByAssertion` verdict whose own diagnosis read
    /// "0 of 130 tests failed"), consistent with a process-exit-status/xunit-
    /// report race under concurrent load rather than a genuine assertion
    /// kill; crediting a kill on evidence that contradicts itself is exactly
    /// the over-claim this project's own core invariant treats as its worst
    /// failure mode, so this fails closed to `.infrastructureFailure`
    /// instead. `summary == nil` (no xunit report parsed at all) is
    /// deliberately NOT included in this fail-closed treatment (returns
    /// `nil`, keeping the caller's original `.failed` behavior): XCTest's
    /// own xunit report is only written when `tests.parallel` is on, so its
    /// absence here is routine and proves nothing, unlike a present-but-
    /// empty report, which is a real, positive contradiction. Tightening the
    /// `nil` case too would risk reclassifying large numbers of genuine
    /// assertion kills as indeterminate under this codebase's own (safe)
    /// default test configuration -- a correctness regression, not a fix.
    private static func exitOneXUnitContradiction(
        summary: TestOutcomeSummary?, command: CommandRecord, xunitOutput: URL?
    ) -> TestRunResult? {
        guard let summary, summary.failed == 0 else { return nil }
        return TestRunResult(
            status: .infrastructureFailure,
            summary: summary,
            command: command,
            resultArtifactPath: xunitOutput,
            diagnosis: """
            swift test exited 1 (failure), but its own xunit report records 0 of \(summary.total) test(s) \
            failed. This exit/xunit contradiction is not trusted as an assertion kill.
            """
        )
    }
}
