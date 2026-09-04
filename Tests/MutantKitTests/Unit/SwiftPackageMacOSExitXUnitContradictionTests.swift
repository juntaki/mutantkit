@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `SwiftPackageMacOSAdapter.classify`'s exit-code/xunit-report contradiction
/// handling.
///
/// A real F7 benchmark run produced 4 `killedByAssertion` verdicts whose own
/// diagnosis read "0 of 130 tests failed" -- `swift test` exited 1 (its own
/// contract for "a test failed"), but the parsed xunit report recorded zero
/// failures. `classify` trusted the exit code alone and never checked
/// whether the report actually agreed with it, unconditionally mapping any
/// exit 1 to `.failed`. None of the 4 reproduced under a clean, isolated
/// re-run (16/16 attempts), consistent with a process-exit-status/xunit-
/// report race under concurrent load, not a real assertion kill -- crediting
/// one on self-contradictory evidence is exactly the over-claim this
/// project's own core invariant treats as its worst failure mode.
///
/// The mirror-image contradiction (exit 0 claiming success while the report
/// records real failures) is closed by the same fix, on the same reasoning.
///
/// Deliberately NOT closed: exit 1 with no xunit report parsed at all
/// (`summary == nil`). XCTest's own xunit report is only written when
/// `tests.parallel` is on (see `SwiftPackageMacOSShortfallClassificationTests`'
/// own doc comment for the parser-level half of this fact) -- under this
/// codebase's own default configuration, a missing report proves nothing
/// about whether a real assertion actually failed, unlike a *present but
/// empty* report, which is a positive, informative contradiction. Failing
/// closed on `summary == nil` too would risk reclassifying large numbers of
/// genuine assertion kills as indeterminate for every project that leaves
/// `tests.parallel` at its default -- a correctness regression, not a fix.
@Suite("SwiftPM exit-code / xunit-report contradiction classification")
struct SwiftPackageMacOSExitXUnitContradictionTests {
    private func result(exitCode: Int32) -> ProcessResult {
        ProcessResult(
            exitCode: exitCode, standardOutput: Data(), standardError: Data(),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
    }

    private func command() -> CommandRecord {
        CommandRecording.record(
            executable: "/usr/bin/xcrun", arguments: ["swift", "test"],
            workingDirectory: URL(fileURLWithPath: "/tmp"), result: nil
        )
    }

    /// XCTest's own xunit report shape -- a `<testsuite>` with real
    /// `tests`/`failures` counts and, when `failed > 0`, one `<testcase>`
    /// per failing test carrying a `<failure>` child, matching what
    /// `XUnitParser` actually looks for (`failingTests` is populated from
    /// `<testcase>` elements containing a `<failure>`, not from the
    /// `failures` attribute alone).
    private func writeXCTestReport(total: Int, failed: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-contradiction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let failingCases = (0 ..< failed).map { index in
            """
              <testcase classname="ArgumentParserEndToEndTests" name="failingTest\(index)" time="0.01">
                <failure message="assertion failed" />
              </testcase>
            """
        }.joined(separator: "\n")
        let passingCases = (0 ..< (total - failed)).map { index in
            """
              <testcase classname="ArgumentParserEndToEndTests" name="passingTest\(index)" time="0.01" />
            """
        }.joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites>
          <testsuite name="TestResults" tests="\(total)" failures="\(failed)" skipped="0" time="1.0">
        \(failingCases)
        \(passingCases)
          </testsuite>
        </testsuites>
        """
        try Data(xml.utf8).write(to: directory.appendingPathComponent("mutantkit-xunit.xml"))
        return directory.appendingPathComponent("mutantkit-xunit.xml")
    }

    // Case 1: exit=0 + failed=0 -> passed
    @Test("exit 0 with zero recorded failures is a genuine pass")
    func exitZeroNoFailuresIsPassed() throws {
        let xunitOutput = try writeXCTestReport(total: 10, failed: 0)
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 0), command: command(), xunitOutput: xunitOutput)
        #expect(outcome.status == .passed)
    }

    // Case 2: exit=0 + failed>0 -> infrastructureFailure (new: closes the
    // mirror-image contradiction)
    @Test("exit 0 with recorded failures is a contradiction, not a pass")
    func exitZeroWithFailuresIsInfrastructureFailure() throws {
        let xunitOutput = try writeXCTestReport(total: 10, failed: 2)
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 0), command: command(), xunitOutput: xunitOutput)
        #expect(outcome.status == .infrastructureFailure)
    }

    // Case 3: exit=1 + failed>0 -> failed (the ordinary, overwhelmingly
    // common case -- must be completely unaffected by this fix)
    @Test("exit 1 with recorded failures is a genuine assertion kill")
    func exitOneWithFailuresIsFailed() throws {
        let xunitOutput = try writeXCTestReport(total: 10, failed: 1)
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 1), command: command(), xunitOutput: xunitOutput)
        #expect(outcome.status == .failed)
    }

    // Case 4 (the real bug): exit=1 + failed=0 -> infrastructureFailure
    @Test("exit 1 with zero recorded failures is a contradiction, not a kill")
    func exitOneNoFailuresIsInfrastructureFailure() throws {
        let xunitOutput = try writeXCTestReport(total: 10, failed: 0)
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 1), command: command(), xunitOutput: xunitOutput)
        #expect(outcome.status == .infrastructureFailure)
    }

    // Case 5 (legacy preservation, load-bearing): exit=1 + summary=nil ->
    // still failed, exactly as before this fix.
    @Test("exit 1 with no xunit report parsed at all still fails as an assertion kill (legacy behavior preserved)")
    func exitOneWithNoReportIsStillFailed() {
        let outcome = SwiftPackageMacOSAdapter.classify(
            result: result(exitCode: 1), command: command(),
            xunitOutput: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)/mutantkit-xunit.xml")
        )
        #expect(outcome.status == .failed)
    }

    // Case 6: any other exit code -> infrastructureFailure (pre-existing
    // behavior, pinned here alongside its siblings for completeness).
    @Test("An exit code other than 0 or 1 is an infrastructure failure")
    func otherExitCodeIsInfrastructureFailure() throws {
        let xunitOutput = try writeXCTestReport(total: 10, failed: 0)
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 2), command: command(), xunitOutput: xunitOutput)
        #expect(outcome.status == .infrastructureFailure)
    }

    /// The exact shape of the real incident this fix responds to, pinned
    /// permanently: `mut_0ab019ce7d96fbbc`'s original diagnosis read
    /// "0 of 130 tests failed" under an exit-1 `killedByAssertion` verdict.
    @Test("The real F7 benchmark incident (exit 1, 130 tests, 0 failed) no longer credits a kill")
    func realIncidentFixtureIsNoLongerCreditedAsAKill() throws {
        let xunitOutput = try writeXCTestReport(total: 130, failed: 0)
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 1), command: command(), xunitOutput: xunitOutput)
        #expect(outcome.status == .infrastructureFailure)
        #expect(outcome.diagnosis.contains("contradiction"))
    }
}
