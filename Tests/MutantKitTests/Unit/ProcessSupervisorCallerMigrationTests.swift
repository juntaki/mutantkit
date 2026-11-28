@testable import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Production callers of `ProcessSupervisor.run` must not read the `-1` placeholder of an unobserved exit
/// as an exit code, and must not derive a fact from output that was not fully captured.
@Suite("ProcessSupervisor callers honour the checked result")
struct ProcessSupervisorCallerMigrationTests {
    private static let reason = "exit status of pid 7 unavailable: waitpid(7) returned -1 (No child processes, errno 10)"

    private static func unobservedExit(outputComplete: Bool = true, stdout: String = "") -> ProcessResult {
        ProcessResult(
            exitCode: -1, standardOutput: Data(stdout.utf8), standardError: Data(), durationSeconds: 1,
            timedOut: false, terminatingSignal: nil, outputComplete: outputComplete,
            cleanupVerified: false, cleanupDiagnosis: reason, exitStatusAvailable: false
        )
    }

    private static func truncated(stdout: String) -> ProcessResult {
        ProcessResult(
            exitCode: 0, standardOutput: Data(stdout.utf8), standardError: Data(), durationSeconds: 1,
            timedOut: false, terminatingSignal: nil, outputComplete: false, cleanupVerified: true
        )
    }

    private static let command = CommandRecording.record(
        executable: "/usr/bin/xcrun", arguments: [], workingDirectory: URL(fileURLWithPath: "/tmp"), result: nil
    )

    @Test("The predicates")
    func predicates() {
        #expect(Self.truncated(stdout: "x").succeeded && !Self.truncated(stdout: "x").succeededWithCompleteOutput)
        #expect(Self.unobservedExit().exitStatusDescription == "unavailable")
        let exited = ProcessResult(
            exitCode: 3, standardOutput: Data(), standardError: Data(), durationSeconds: 0, timedOut: false,
            terminatingSignal: nil, outputComplete: true, cleanupVerified: true
        )
        #expect(exited.exitStatusDescription == "3")
    }

    @Test("A command record never stores the placeholder as an exit code")
    func commandRecordOmitsPlaceholder() {
        let record = CommandRecording.record(
            executable: "x", arguments: [], workingDirectory: URL(fileURLWithPath: "/tmp"), result: Self.unobservedExit()
        )
        #expect(record.exitCode == nil)
    }

    @Test("A build whose exit was never observed is infrastructure, not an unattributed exit -1")
    func buildClassifierUnobservedExit() {
        let failure = BuildClassifier.failure(from: Self.unobservedExit(), command: Self.command)
        #expect(failure.kind == .infrastructure)
        #expect(failure.diagnosis.contains("exit status could not be observed"))
        #expect(!failure.diagnosis.contains("exited with -1"))
    }

    @Test("A swift test run whose exit was never observed is not scored")
    func swiftTestUnobservedExit() {
        let run = SwiftPackageMacOSAdapter.classify(result: Self.unobservedExit(), command: Self.command)
        #expect(run.status == .infrastructureFailure)
        #expect(run.diagnosis.contains("exit status could not be observed"))
        #expect(!run.cleanupVerified)
    }

    private static func service(_ result: ProcessResult) -> XCTestInvocationService {
        XCTestInvocationService(
            terminationGracePeriodSeconds: 1, resultReader: XCResultAdapter(), launch: { _, _, _, _ in result }
        )
    }

    private static func bundle() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("caller-mig-\(UUID().uuidString)/r.xcresult")
    }

    @Test("xcodebuild single: an unobserved exit is infrastructure and the bundle is not consulted")
    func xcodebuildSingleUnobservedExit() async {
        let run = await Self.service(Self.unobservedExit()).runSingle(
            arguments: [], resultBundle: Self.bundle(), timeoutSeconds: 1, timeoutDiagnosis: "t",
            in: FileManager.default.temporaryDirectory,
            classify: { XCResultAdapter.Outcome(status: .passed, summary: makeTestSummary(), diagnosis: "from bundle") }
        )
        #expect(run.status == .infrastructureFailure)
        #expect(run.diagnosis.contains("exit status could not be observed"))
        #expect(!run.cleanupVerified)
    }

    @Test("xcodebuild batch: an unobserved exit fails every member")
    func xcodebuildBatchUnobservedExit() async {
        let runs = await Self.service(Self.unobservedExit()).runBatch(
            arguments: [], resultBundle: Self.bundle(), timeoutSeconds: 1,
            configurationTestIdentifiers: ["a": ["T/a"], "b": ["T/b"]], in: FileManager.default.temporaryDirectory
        )
        #expect(runs.count == 2)
        #expect(runs.values.allSatisfy {
            $0.status == .infrastructureFailure && $0.diagnosis.contains("exit status could not be observed") && !$0.cleanupVerified
        })
    }

    @Test("A truncated git diff is a failure, never a narrower scope")
    func truncatedGitDiff() async {
        let diff = "+++ b/A.swift\n@@ -1,0 +1,2 @@\n"
        await #expect(throws: GitDiffError.self) {
            _ = try await GitDiff.changedLines(since: "HEAD", in: URL(fileURLWithPath: "/tmp")) { _, _, _, _ in
                Self.truncated(stdout: diff)
            }
        }
        let scope = try? await GitDiff.changedLines(since: "HEAD", in: URL(fileURLWithPath: "/tmp")) { _, _, _, _ in
            ProcessResult(
                exitCode: 0, standardOutput: Data(diff.utf8), standardError: Data(), durationSeconds: 0,
                timedOut: false, terminatingSignal: nil, outputComplete: true, cleanupVerified: true
            )
        }
        #expect(scope?.changedLines["A.swift"] == [1 ..< 3])
    }
}
