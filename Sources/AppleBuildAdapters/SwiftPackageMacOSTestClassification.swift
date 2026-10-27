import Foundation
import MutationExecution
import MutationModel

extension SwiftPackageMacOSAdapter {
    /// Something the supervisor does not own may still hold the pipes, so the exit status, the crash line and
    /// the diagnostics may be missing the very output that decides the run. A run that cannot be trusted to
    /// be fully observed is neither a kill nor a survivor.
    private static func incompleteOutputResult(result: ProcessResult, command: CommandRecord) -> TestRunResult? {
        guard !result.outputComplete else { return nil }
        return TestRunResult(
            status: .infrastructureFailure,
            summary: nil,
            command: command,
            resultArtifactPath: nil,
            diagnosis: """
            The test run's output could not be confirmed complete (a process outside the supervisor's control \
            may still hold its pipes), so its exit status \(result.exitCode) is not scored.
            """,
            cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
        )
    }

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
    ///   while XCTest's report is written only in SwiftPM's parallel mode,
    ///   which a coverage run does not use — there an XCTest identifier's
    ///   absence from it proves nothing, so mixing frameworks or trusting an
    ///   XCTest-only selection here would misclassify a real, passing run as
    ///   a shortfall.
    /// - Parameter xctestReportRequested: whether the invocation asked SwiftPM
    ///   for the XCTest xunit report too (`requestsXCTestReport`). When it did,
    ///   both frameworks leave a structured record of every test they ran, so
    ///   an exit 1 that left no report naming any test is not an assertion kill.
    static func classify(
        result: ProcessResult,
        command: CommandRecord,
        xunitOutput: URL? = nil,
        reliableExpectedTestCount: Int? = nil,
        xctestReportRequested: Bool = false
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
                """,
                cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
            )
        }

        if let signal = result.terminatingSignal {
            return TestRunResult(
                status: .crashed, summary: nil, command: command, resultArtifactPath: nil,
                diagnosis: "The test process was killed by signal \(signal).",
                cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
            )
        }

        if let incomplete = incompleteOutputResult(result: result, command: command) { return incomplete }

        // `swift test` runs the test bundle in a helper process. When a mutant makes that helper trap, `swift
        // test` is NOT signalled: it prints one fixed SwiftPM line and exits 1, and the xunit report holds
        // only the tests that finished. The structured outputs cannot record the crash, so the runner's own
        // fixed diagnostic is read as an observation (full-line match, non-zero exit only) and carried with
        // its provenance; it decides nothing by itself — a crash with this provenance must pass the
        // independent crash confirmation before it can be a kill. Anything not exactly that line leaves the
        // run in the exit/xunit contradiction below.
        if result.exitCode != 0, let crash = testProcessCrash(inStandardError: result.standardError) {
            return helperProcessCrashResult(crash, result: result, command: command)
        }

        if result.exitCode == 0 {
            if let shortfall = narrowedSelectionShortfall(
                summary: summary, command: command, xunitOutput: xunitOutput, reliableExpectedTestCount: reliableExpectedTestCount,
                cleanup: result
            ) {
                return shortfall
            }

            if let contradiction = exitZeroXUnitContradiction(
                summary: summary, command: command, xunitOutput: xunitOutput, cleanup: result
            ) {
                return contradiction
            }

            return TestRunResult(
                status: .passed,
                summary: summary,
                command: command,
                resultArtifactPath: xunitOutput,
                diagnosis: summary.map { "swift test exited successfully; all \($0.total) tests passed." }
                    ?? "swift test exited successfully; every test passed.",
                cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
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
                """,
                cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
            )
        }

        if let untrusted = untrustedExitOne(summary, command, xunitOutput, xctestReportRequested, result) {
            return untrusted
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
            } ?? "swift test exited with 1: at least one test failed.",
            cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
        )
    }

    private static func helperProcessCrashResult(
        _ crash: TestProcessCrashObservation, result: ProcessResult, command: CommandRecord
    ) -> TestRunResult {
        let standardErrorText = String(decoding: result.standardError, as: UTF8.self)
        let standardOutputText = String(decoding: result.standardOutput, as: UTF8.self)
        return TestRunResult(
            status: .crashed,
            summary: nil,
            command: command,
            resultArtifactPath: nil,
            diagnosis: "The test process was killed by signal \(crash.signal) (\(crash.process)).",
            crashProvenance: CrashProvenance(
                source: .swiftPMTestHelperSignalDiagnostic,
                matchedLine: crash.line,
                signal: crash.signal,
                standardErrorTail: OutputRedactor.redactAndTruncate(standardErrorText, limit: 4000),
                standardOutputTail: OutputRedactor.redactAndTruncate(standardOutputText, limit: 4000)
            ),
            cleanupVerified: result.cleanupVerified, cleanupDiagnosis: result.cleanupDiagnosis
        )
    }

    struct TestProcessCrashObservation {
        let signal: Int32
        let process: String
        let line: String
    }

    /// SwiftPM's report that the test helper process died from a signal, matched as a WHOLE line:
    /// `error: Process '<executable> <args>' exited with unexpected signal code <N>`.
    ///
    /// Fail closed on anything else. Every line that begins `error: Process '` and mentions an
    /// unexpected signal must match the exact shape (a changed format is not guessed at), and all matches
    /// must agree on the signal (contradictory lines are not resolved); otherwise `nil`, and the run
    /// stays in the exit/xunit contradiction. Lookalikes elsewhere in a line, or in test output, are
    /// ignored because the line must start with the fixed prefix and end with the number.
    static func testProcessCrash(inStandardError data: Data) -> TestProcessCrashObservation? {
        let prefix = "error: Process '"
        let marker = "' exited with unexpected signal code "
        var found: [TestProcessCrashObservation] = []
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.localizedCaseInsensitiveContains("unexpected signal") else { continue }
            guard let range = line.range(of: marker, options: .backwards),
                  let signal = Int32(line[range.upperBound...]), line[range.upperBound...].allSatisfy(\.isNumber)
            else { return nil } // our prefix, but not exactly the known shape: unparsable
            let command = line[line.index(line.startIndex, offsetBy: prefix.count) ..< range.lowerBound]
            guard !command.isEmpty else { return nil }
            let executable = command.prefix { $0 != " " }
            found.append(TestProcessCrashObservation(
                signal: signal, process: String(executable.split(separator: "/").last ?? Substring(executable)), line: line
            ))
        }
        guard let first = found.first, found.allSatisfy({ $0.signal == first.signal }) else { return nil }
        return first
    }

    /// `nil` (no xunit report parsed at all -- missing, unreadable, or
    /// `xunitOutput` itself absent) is treated as zero executed, not as
    /// "unknown, so don't check" (codex review, P12-B Phase B3): for a
    /// narrowed selection, no evidence that anything ran is exactly as
    /// unsafe to call a pass as evidence that zero things ran. `nil` when
    /// `reliableExpectedTestCount` is `nil` (an unnarrowed run) or when
    /// enough tests were actually executed.
    private static func narrowedSelectionShortfall(
        summary: TestOutcomeSummary?, command: CommandRecord, xunitOutput: URL?, reliableExpectedTestCount: Int?,
        cleanup: ProcessResult
    ) -> TestRunResult? {
        guard let reliableExpectedTestCount else { return nil }
        let executedCount = xunitOutput.flatMap { XUnitParser.swiftTestingAccountedCount(forRequestedOutput: $0) }
        guard (executedCount ?? 0) < reliableExpectedTestCount else { return nil }
        return TestRunResult(
            status: .infrastructureFailure,
            summary: summary,
            command: command,
            resultArtifactPath: xunitOutput,
            diagnosis: """
            This run was narrowed to \(reliableExpectedTestCount) Swift Testing test(s), but the \
            xunit report records only \(executedCount.map(String.init) ?? "no") (run or skipped). Something \
            in the selection did not run and left no failure record explaining why, so the \
            shortfall is not scored as a pass.
            """,
            cleanupVerified: cleanup.cleanupVerified, cleanupDiagnosis: cleanup.cleanupDiagnosis
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
        summary: TestOutcomeSummary?, command: CommandRecord, xunitOutput: URL?, cleanup: ProcessResult
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
            """,
            cleanupVerified: cleanup.cleanupVerified, cleanupDiagnosis: cleanup.cleanupDiagnosis
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
    /// instead.
    ///
    /// The same reading used to hit mixed packages: an XCTest failure in a
    /// serial run left only the Swift Testing report, recording zero
    /// failures. Ordinary runs now request the XCTest report as well
    /// (`swiftTestParallelismFlags`), so a failing XCTest is named in it and
    /// no longer reads as zero. `summary == nil` (no report naming any test)
    /// is handled separately, by `exitOneWithoutXUnitRecord`, and only for
    /// runs that requested both reports; a coverage run still requests the
    /// Swift Testing report alone, so its missing XCTest half proves nothing.
    private static func exitOneXUnitContradiction(
        summary: TestOutcomeSummary?, command: CommandRecord, xunitOutput: URL?, cleanup: ProcessResult
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
            """,
            cleanupVerified: cleanup.cleanupVerified, cleanupDiagnosis: cleanup.cleanupDiagnosis
        )
    }

    /// An exit 1 whose xunit evidence does not support an assertion kill, or
    /// `nil` when it does.
    private static func untrustedExitOne(
        _ summary: TestOutcomeSummary?, _ command: CommandRecord, _ xunitOutput: URL?, _ xctestReportRequested: Bool,
        _ cleanup: ProcessResult
    ) -> TestRunResult? {
        if let contradiction = exitOneXUnitContradiction(summary: summary, command: command, xunitOutput: xunitOutput, cleanup: cleanup) {
            return contradiction
        }
        guard xctestReportRequested, xunitOutput != nil else { return nil }
        return exitOneWithoutXUnitRecord(summary: summary, command: command, cleanup: cleanup)
    }

    /// Exit 1 with no xunit report naming any test, from a run that requested
    /// both frameworks' reports. Nothing structured records a failing test:
    /// the test process may have ended before either framework wrote its
    /// report (a mutant that makes code under test end the process does
    /// exactly that), so the exit status alone is not credited as an
    /// assertion kill. `nil` when a report did name tests.
    private static func exitOneWithoutXUnitRecord(
        summary: TestOutcomeSummary?, command: CommandRecord, cleanup: ProcessResult
    ) -> TestRunResult? {
        guard summary == nil else { return nil }
        return TestRunResult(
            status: .infrastructureFailure,
            summary: nil,
            command: command,
            resultArtifactPath: nil,
            diagnosis: """
            swift test exited 1 (failure), but neither its XCTest nor its Swift Testing xunit report \
            names any test, so no test is recorded as having caught this mutant. Not trusted as an \
            assertion kill.
            """,
            cleanupVerified: cleanup.cleanupVerified, cleanupDiagnosis: cleanup.cleanupDiagnosis
        )
    }
}
