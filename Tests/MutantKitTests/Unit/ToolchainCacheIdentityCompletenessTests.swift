@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// The cache-identity-layer regression for `ToolchainProbe`'s own
/// `outputComplete` gap: a truncated toolchain probe (`swift --version`,
/// `xcodebuild -version`, or either `xcrun --show-sdk-version`/`--show-sdk-
/// build-version` call) must not be allowed to collapse into "unknown" and
/// get hashed into a cache key as if it were a real, reproducible value —
/// it must instead disable the cache key entirely, through the identical
/// fail-closed path `RunContextProbeOutputCompletenessTests` already proves
/// for incomplete `git` output.
///
/// `ToolchainProbe.fingerprint` itself has no injectable seam for its fixed
/// `/usr/bin/swift`/`/usr/bin/xcodebuild`/`/usr/bin/xcrun` subprocess calls
/// (unlike `RunContextProbe`'s `git` calls), so this exercises the seam
/// `ToolchainProbe`'s own incompleteness actually flows through: the
/// `toolchainCacheIdentityComplete` flag `RunCommand` threads from
/// `ToolchainProbeResult.identityEvidenceComplete` into `RunContextProbe
/// .compute`/`.computeContextDigest` and `RunCommand.runInputState`. The `false` here is a deliberately
/// hand-constructed stand-in for what a real incomplete `ToolchainProbe`
/// subprocess produces — labeled as such, not offered as a substitute for
/// `ToolchainProbeTests`'s own real, subprocess-backed coverage of
/// `fingerprint`'s ordinary values.
@Suite("RunContextProbe: refuses an incomplete toolchain cache identity")
struct ToolchainCacheIdentityCompletenessTests {
    private func toolchain() -> ToolchainFingerprint {
        ToolchainFingerprint(
            toolVersion: "test", toolCommitSHA: nil, swiftVersion: "test", swiftSyntaxVersion: "test",
            xcodeVersion: nil, buildSDKIdentity: nil, destinationRuntimeIdentity: nil
        )
    }

    /// True only for `RunContextProbeError.incompleteToolchainIdentity`,
    /// never for `.gitUnavailable`/`.unprovableWorktreeContent` — pins which
    /// specific case fired rather than merely "some `RunContextProbeError`
    /// was thrown", since a `processRunner` bug could otherwise throw a
    /// different case for a different reason and still pass a same-type check.
    private func isIncompleteToolchainIdentity(_ error: some Error) -> Bool {
        guard let error = error as? RunContextProbeError else { return false }
        if case .incompleteToolchainIdentity = error { return true }
        return false
    }

    @Test("compute() throws incompleteToolchainIdentity when the toolchain probe behind it was incomplete")
    func computeRejectsAnIncompleteToolchainIdentity() throws {
        do {
            _ = try RunContextProbe.compute(
                inputState: .placeholder,
                configuration: Configuration(),
                toolchain: toolchain(),
                workUnitID: "wu",
                toolchainCacheIdentityComplete: false
            )
            Issue.record("expected compute() to throw for an incomplete toolchain identity")
        } catch {
            #expect(isIncompleteToolchainIdentity(error))
        }
    }

    @Test("computeContextDigest() throws incompleteToolchainIdentity identically, for both the coverage-cache and result-cache purposes")
    func computeContextDigestRejectsAnIncompleteToolchainIdentity() throws {
        for purpose in ["coverageProfileCache4", "resultCache3"] {
            do {
                _ = try RunContextProbe.computeContextDigest(
                    inputState: .placeholder, configuration: Configuration(), toolchain: toolchain(), purpose: purpose,
                    toolchainCacheIdentityComplete: false
                )
                Issue.record("expected computeContextDigest(purpose: \(purpose)) to throw for an incomplete toolchain identity")
            } catch {
                #expect(isIncompleteToolchainIdentity(error))
            }
        }
    }

    /// The run computes its input state once, before any identity. With an
    /// incomplete toolchain identity it must not pay for the git work at
    /// all, and every identity is disabled.
    @Test("An incomplete toolchain identity yields no run input state, without touching git at all")
    func runInputStateSkipsGitForAnIncompleteToolchainIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
        let state = await RunCommand.runInputState(
            root: root, layout: .projectOnly(root), scratchRoots: [],
            toolchainCacheIdentityComplete: false,
            processRunner: { _, _, _, _ in
                Issue.record("worktreeContentState must not run when the toolchain identity is already known incomplete")
                throw CancellationError()
            }
        )
        #expect(state == nil)
        #expect(
            RunCommand.runIdentities(inputState: state, configuration: Configuration(), toolchain: toolchain(), workUnitID: "wu")
                == RunCommand.RunIdentities(checkpoint: nil, coverageCacheDigest: nil, resultCacheDigest: nil)
        )
    }

    /// The guard is not always-on: a `processRunner` that succeeds is only
    /// ever reached when `toolchainCacheIdentityComplete` is `true`,
    /// proving `false` — not the parameter's mere presence — is what skips
    /// the git work above.
    @Test("A complete toolchain identity lets the run input state reach the processRunner at all")
    func completeToolchainIdentityReachesTheProcessRunner() async throws {
        let root = FileManager.default.temporaryDirectory
        let tracker = CallTracker()

        _ = await RunCommand.runInputState(
            root: root, layout: .projectOnly(root), scratchRoots: [],
            toolchainCacheIdentityComplete: true,
            processRunner: { _, _, _, _ in
                await tracker.markCalled()
                throw CancellationError()
            }
        )

        #expect(await tracker.wasCalled)
    }
}

/// Tracks whether the scripted `processRunner` was reached, without the
/// data race a plain `var` capture in a `@Sendable` closure would create —
/// mirrors `SimulatorPoolLifecycleTests`'s own `BootCallTracker`.
private actor CallTracker {
    private(set) var wasCalled = false
    func markCalled() { wasCalled = true }
}
