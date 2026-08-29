@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// The consumer-side half of the `ProcessResult.outputComplete` regression:
/// `RunContextProbe` must refuse to treat a subprocess result as valid
/// cache-identity input whenever `outputComplete == false`, exactly as it
/// already refuses a failed subprocess — even when that subprocess's own
/// exit succeeded. Without this, an incomplete-but-successful `git`
/// invocation could feed a truncated worktree fingerprint into cache-key
/// computation as if it were complete, letting a stale result be reused as
/// though the tree had not changed.
///
/// Uses the identical, real, deterministically-forced incomplete
/// `ProcessResult` `ProcessSupervisorOutputCompletenessTests` proves —
/// `ForcedIncompleteOutputFixture` — injected in place of the real `git`
/// invocation via `RunContextProbe.ProcessRunner`. Substituting the runner
/// (rather than trying to make a real `git ls-files` invocation lose output,
/// which would depend on exactly the drain-timing condition this fixture
/// exists to avoid racing) is what makes the "RunContextProbe side" of this
/// regression exercise the real fail-closed code path deterministically:
/// the `ProcessResult` reaching `RunContextProbe.worktreeContentState` here
/// is the same real, unmodified `ProcessSupervisor.run` output the
/// `ProcessSupervisor`-level regression asserts on, not a hand-built fake.
@Suite("RunContextProbe: refuses incomplete-but-successful subprocess output", .subprocessExclusive)
struct RunContextProbeOutputCompletenessTests {
    private func forcedIncompleteRunner() -> RunContextProbe.ProcessRunner {
        { _, _, _, _ in try await ForcedIncompleteOutputFixture.run() }
    }

    /// Also confirms the rejection specifically names incomplete output,
    /// not a coincidental/generic git failure — pinning the message so a
    /// future change that silently drops this check (e.g. collapsing the
    /// two guards in `runBytes` back into one) would be caught by a wording
    /// mismatch here rather than passing silently.
    @Test("worktreeContentState throws, rather than returning a digest, when subprocess output could not be confirmed complete")
    func worktreeContentStateRejectsIncompleteOutput() async throws {
        let root = FileManager.default.temporaryDirectory

        do {
            _ = try await RunContextProbe.worktreeContentState(in: root, processRunner: forcedIncompleteRunner())
            Issue.record("expected worktreeContentState to throw for incomplete output")
        } catch {
            let description = "\(error)"
            let namesIncompleteOutput = description.localizedCaseInsensitiveContains("could not be")
                && description.localizedCaseInsensitiveContains("captured")
            #expect(namesIncompleteOutput)
        }
    }

    /// The same fail-closed gate must fire for every caller that derives a
    /// cache-identity fact through `worktreeContentState`, not only a direct
    /// caller — `compute` (checkpoint identity) and `computeContextDigest`
    /// (coverage/result cache identity) both route through it with no
    /// separate error-handling path of their own, so this pins that neither
    /// one accidentally gained one.
    @Test("compute() and computeContextDigest() both propagate the same rejection, never silently substituting a partial digest")
    func computeAndComputeContextDigestBothPropagateTheRejection() async throws {
        let root = FileManager.default.temporaryDirectory
        let toolchain = ToolchainFingerprint(
            toolVersion: "test", toolCommitSHA: nil, swiftVersion: "test", swiftSyntaxVersion: "test",
            xcodeVersion: nil, buildSDKIdentity: nil, destinationRuntimeIdentity: nil
        )

        await #expect(throws: RunContextProbeError.self) {
            _ = try await RunContextProbe.compute(
                projectRoot: root, configuration: Configuration(), toolchain: toolchain, workUnitID: "wu",
                processRunner: forcedIncompleteRunner()
            )
        }
        await #expect(throws: RunContextProbeError.self) {
            _ = try await RunContextProbe.computeContextDigest(
                projectRoot: root, configuration: Configuration(), toolchain: toolchain, purpose: "resultCache2",
                processRunner: forcedIncompleteRunner()
            )
        }
    }
}
