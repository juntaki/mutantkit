import Foundation
@testable import MutationExecution
import Testing

/// Regression for the real CI incident that motivated `ProcessResult
/// .outputComplete`: a `simctl uninstall` subprocess exit reached its
/// caller non-zero with an empty output detail, while the identical
/// invocation immediately afterward captured "Invalid device: ..." in
/// full. The root cause was never a `simctl` behavior difference — it was
/// `ProcessSupervisor`'s bounded post-exit drain wait (`drainGroup.wait
/// (timeout:)`) timing out and having its result silently discarded
/// (`_ = drainGroup.wait(...)`), so a caller had no way to tell "the
/// process completed and every byte it wrote was captured" apart from
/// "the process completed but its output may have been truncated".
///
/// `ForcedIncompleteOutputFixture` (`Tests/MutantKitTests/Support/`) forces
/// exactly that condition deterministically, on every run, regardless of
/// machine load — see its own doc comment for why a real fd handed to an
/// independent, non-descendant process is what makes this reproducible at
/// all, rather than racing `ProcessSupervisor`'s own (separate, untouched,
/// already-accepted) descendant-reaping behavior.
@Suite("ProcessSupervisor: ProcessResult.outputComplete", .subprocessExclusive)
struct ProcessSupervisorOutputCompletenessTests {
    @Test("A promptly, successfully exiting process whose stdout pipe outlives the drain window reports outputComplete == false")
    func promptSuccessfulExitWithPipeHeldOpenIsIncomplete() async throws {
        let result = try await ForcedIncompleteOutputFixture.run()

        // The exit itself is known and successful — this is the specific gap
        // `outputComplete` closes: `succeeded`/`exitCode`/`timedOut` alone
        // give no signal at all that anything is wrong here.
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.terminatingSignal == nil)
        #expect(result.succeeded)

        // The actual regression: evidence must be reported as incomplete
        // rather than silently treated as the whole story.
        #expect(!result.outputComplete, "a drain that could not reach EOF within the bounded window must report outputComplete == false")

        // What was captured before the write end was handed away is still
        // real data — `outputComplete == false` means "not proven complete",
        // never "discard what we have".
        let capturedStdout = String(decoding: result.standardOutput, as: UTF8.self)
        #expect(capturedStdout.contains("partial-output-before-drain-timeout"))
    }
}
