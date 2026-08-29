@testable import CLI
import Foundation
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
/// .compute`/`.computeContextDigest`. The `false` here is a deliberately
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

    @Test("compute() throws incompleteToolchainIdentity when the toolchain probe behind it was incomplete, without touching git at all")
    func computeRejectsAnIncompleteToolchainIdentity() async throws {
        let root = FileManager.default.temporaryDirectory

        do {
            _ = try await RunContextProbe.compute(
                projectRoot: root,
                configuration: Configuration(),
                toolchain: toolchain(),
                workUnitID: "wu",
                toolchainCacheIdentityComplete: false,
                // A `processRunner` that fails the test outright if called:
                // the toolchain-identity guard must reject before any git
                // work is attempted, not merely reject after also paying for
                // it.
                processRunner: { _, _, _, _ in
                    Issue.record("worktreeContentState must not run when the toolchain identity is already known incomplete")
                    throw CancellationError()
                }
            )
            Issue.record("expected compute() to throw for an incomplete toolchain identity")
        } catch {
            #expect(isIncompleteToolchainIdentity(error))
        }
    }

    @Test("computeContextDigest() throws incompleteToolchainIdentity identically, for both the coverage-cache and result-cache purposes")
    func computeContextDigestRejectsAnIncompleteToolchainIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
        let failingRunner: RunContextProbe.ProcessRunner = { _, _, _, _ in
            Issue.record("worktreeContentState must not run when the toolchain identity is already known incomplete")
            throw CancellationError()
        }

        for purpose in ["coverageProfileCache", "resultCache2"] {
            do {
                _ = try await RunContextProbe.computeContextDigest(
                    projectRoot: root, configuration: Configuration(), toolchain: toolchain(), purpose: purpose,
                    toolchainCacheIdentityComplete: false, processRunner: failingRunner
                )
                Issue.record("expected computeContextDigest(purpose: \(purpose)) to throw for an incomplete toolchain identity")
            } catch {
                #expect(isIncompleteToolchainIdentity(error))
            }
        }
    }

    /// The guard is not always-on: a `processRunner` that succeeds is only
    /// ever reached when `toolchainCacheIdentityComplete` is `true` (the
    /// default), proving `false` — not the parameter's mere presence — is
    /// what triggers rejection above.
    @Test("A complete toolchain identity lets computeContextDigest reach the processRunner at all")
    func completeToolchainIdentityReachesTheProcessRunner() async throws {
        let root = FileManager.default.temporaryDirectory
        let tracker = CallTracker()

        _ = try? await RunContextProbe.computeContextDigest(
            projectRoot: root, configuration: Configuration(), toolchain: toolchain(), purpose: "coverageProfileCache",
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
