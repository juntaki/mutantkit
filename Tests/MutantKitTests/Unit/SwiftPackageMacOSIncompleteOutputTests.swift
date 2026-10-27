@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// A run whose output could not be confirmed complete may be missing the lines that decide it, so
/// neither a pass nor a failure read from it is evidence.
@Suite("SwiftPM test classification of an incompletely drained run")
struct SwiftPackageMacOSIncompleteOutputTests {
    private func result(exitCode: Int32, outputComplete: Bool, timedOut: Bool = false) -> ProcessResult {
        ProcessResult(
            exitCode: exitCode, standardOutput: Data(), standardError: Data(), durationSeconds: 5,
            timedOut: timedOut, terminatingSignal: nil, outputComplete: outputComplete
        )
    }

    private func command() -> CommandRecord {
        CommandRecording.record(
            executable: "/usr/bin/xcrun", arguments: ["swift", "test"],
            workingDirectory: URL(fileURLWithPath: "/tmp"), result: nil
        )
    }

    @Test("An exit 0 or exit 1 with incomplete output is an infrastructure failure", arguments: [Int32(0), Int32(1)])
    func incompleteOutputIsNotScored(exitCode: Int32) {
        let outcome = SwiftPackageMacOSAdapter.classify(result: result(exitCode: exitCode, outputComplete: false), command: command())
        #expect(outcome.status == .infrastructureFailure)
        #expect(outcome.diagnosis.contains("could not be confirmed complete"))
    }

    @Test("The same exits with complete output are classified as before")
    func completeOutputIsUnchanged() {
        let passed = SwiftPackageMacOSAdapter.classify(result: result(exitCode: 0, outputComplete: true), command: command())
        #expect(passed.status == .passed)
    }

    @Test("A timeout keeps its own status")
    func timeoutKeepsItsStatus() {
        let outcome = SwiftPackageMacOSAdapter.classify(
            result: result(exitCode: 0, outputComplete: false, timedOut: true), command: command()
        )
        #expect(outcome.status == .timedOut)
    }
}
