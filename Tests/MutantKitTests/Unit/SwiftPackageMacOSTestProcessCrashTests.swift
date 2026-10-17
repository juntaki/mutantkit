@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// A mutant that traps inside the test bundle (Swift runtime `Fatal error`, SIGTRAP) is a kill.
/// `swift test` is not signalled itself: it prints SwiftPM's own `exited with unexpected signal code N`
/// line and exits 1, with an xunit report that records only the tests that finished. That used to be
/// an infrastructure failure ("exit/xunit contradiction") — found on a self-hosted run.
@Suite("SwiftPM test-process crash classification")
struct SwiftPackageMacOSTestProcessCrashTests {
    /// Verbatim from a real reproduction (path shortened).
    private static let crashLine = "error: Process '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
        + "/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path "
        + "/tmp/x/MutantKitTests.xctest/Contents/MacOS/MutantKitTests --skip-build --parallel "
        + "--testing-library swift-testing' exited with unexpected signal code 5\n"

    private func result(exitCode: Int32, stderr: String) -> ProcessResult {
        ProcessResult(
            exitCode: exitCode, standardOutput: Data("Fatal error: Range requires lowerBound <= upperBound\n".utf8),
            standardError: Data(stderr.utf8), durationSeconds: 5, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
    }

    private func command() -> CommandRecord {
        CommandRecording.record(
            executable: "/usr/bin/xcrun", arguments: ["swift", "test"],
            workingDirectory: URL(fileURLWithPath: "/tmp"), result: nil
        )
    }

    private func xunit(total: Int, failed: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-classify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases = (0 ..< total).map { index in
            index < failed
                ? "<testcase classname=\"T\" name=\"f\(index)\" time=\"0.01\"><failure message=\"x\" /></testcase>"
                : "<testcase classname=\"T\" name=\"p\(index)\" time=\"0.01\" />"
        }.joined(separator: "\n")
        let xml = "<?xml version=\"1.0\"?><testsuites><testsuite name=\"R\" tests=\"\(total)\" failures=\"\(failed)\" skipped=\"0\" time=\"1\">\(cases)</testsuite></testsuites>"
        let url = directory.appendingPathComponent("x.xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    @Test("the real crash: exit 1, clean xunit, SwiftPM's line -> crashed, with the line and raw output as provenance")
    func realCrashIsACrashCandidateWithProvenance() throws {
        let outcome = SwiftPackageMacOSAdapter.classify(
            result: result(exitCode: 1, stderr: Self.crashLine), command: command(), xunitOutput: try xunit(total: 41, failed: 0)
        )
        #expect(outcome.status == .crashed)
        #expect(outcome.diagnosis.contains("signal 5"))
        let provenance = try #require(outcome.crashProvenance)
        #expect(provenance.source == .swiftPMTestHelperSignalDiagnostic)
        #expect(provenance.signal == 5)
        #expect(provenance.matchedLine == Self.crashLine.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(provenance.standardErrorTail.contains("exited with unexpected signal code 5"))
        #expect(provenance.standardOutputTail.contains("Fatal error: Range requires lowerBound"))
    }

    @Test("exit 1 + xunit with zero failures and no SwiftPM line stays the contradiction (infrastructureFailure)")
    func contradictionWithoutTheLineIsUnchanged() throws {
        let outcome = SwiftPackageMacOSAdapter.classify(
            result: result(exitCode: 1, stderr: ""), command: command(), xunitOutput: try xunit(total: 130, failed: 0)
        )
        #expect(outcome.status == .infrastructureFailure)
        #expect(outcome.crashProvenance == nil)
    }

    @Test("an ordinary assertion kill is unchanged")
    func ordinaryKillUnchanged() throws {
        let outcome = SwiftPackageMacOSAdapter.classify(
            result: result(exitCode: 1, stderr: "some warning\n"), command: command(), xunitOutput: try xunit(total: 10, failed: 2)
        )
        #expect(outcome.status == .failed)
        #expect(outcome.crashProvenance == nil)
    }

    @Test("the line on a successful run is never a crash")
    func exitZeroIsNeverACrash() throws {
        let outcome = SwiftPackageMacOSAdapter.classify(
            result: result(exitCode: 0, stderr: Self.crashLine), command: command(), xunitOutput: try xunit(total: 10, failed: 0)
        )
        #expect(outcome.status == .passed)
    }

    @Test("lookalike text is ignored: other prefixes, the words inside other output, a trailing remainder")
    func lookalikeTextIsIgnored() {
        func crash(_ text: String) -> Int32? { SwiftPackageMacOSAdapter.testProcessCrash(inStandardError: Data(text.utf8))?.signal }
        #expect(crash("test printed: exited with unexpected signal code 9\n") == nil)
        #expect(crash("warning: Process 'x' exited with unexpected signal code 9\n") == nil)
        #expect(crash("  note: error: Process 'x' exited with unexpected signal code 9\n") == nil)
        #expect(crash("noise\n" + Self.crashLine) == 5)
    }

    @Test("fail closed: a changed format, a trailing remainder or contradictory signals are not guessed at")
    func changedOrContradictoryFormatsFailClosed() {
        func crash(_ text: String) -> Int32? { SwiftPackageMacOSAdapter.testProcessCrash(inStandardError: Data(text.utf8))?.signal }
        // Same prefix, but the sentence changed (Swift update): unparsable -> no crash candidate.
        #expect(crash("error: Process 'x' was terminated by unexpected signal 5\n") == nil)
        // The number is followed by more text.
        #expect(crash("error: Process 'x' exited with unexpected signal code 5 (core dumped)\n") == nil)
        // No number.
        #expect(crash("error: Process 'x' exited with unexpected signal code \n") == nil)
        // Contradictory signals from two lines.
        #expect(crash(
            "error: Process 'a' exited with unexpected signal code 5\n"
                + "error: Process 'b' exited with unexpected signal code 11\n"
        ) == nil)
        // One good line next to one unparsable line of ours: still no candidate.
        #expect(crash(Self.crashLine + "error: Process 'b' exited with unexpected signal code x\n") == nil)
        // The same signal twice is consistent.
        #expect(crash(
            "error: Process 'a' exited with unexpected signal code 5\n"
                + "error: Process 'b' exited with unexpected signal code 5\n"
        ) == 5)
    }
}
