import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Gate 3 Phase H8: pins — honestly, not optimistically — what was actually
/// observed while trying to reproduce Phase H7's real, large production
/// iOS app finding (native XCTest timeout containment failing to preempt
/// a real production hang, `mut_70d5b52e5bb74306`) in a fast, local,
/// production-app-independent fixture.
///
/// Neither hang shape tried here reproduces Phase H7's actual severity —
/// both `XcodeBuildAdapter.runBatch` (the real production entry point,
/// same as `XcodeBatchNativeTimeoutContainmentAcceptanceTests`, Phase H3)
/// still self-recovers cleanly, unlike the real production app's batch,
/// which took its
/// full outer aggregate timeout with zero self-recovery. This suite exists
/// to keep that gap visible and pinned, not to claim it is closed — and to
/// give Phase H9+'s watchdog logic two genuinely harder-than-`testHangs`
/// fixtures to develop against while the real differentiator stays
/// unidentified. See `GATE3-RESULT.md`, Phase H8, for the full account.
@Suite("Acceptance: non-cooperative hang shapes (Gate 3 Phase H8 — recorded gaps, not proof of containment)", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeBatchNonCooperativeHangAcceptanceTests {
    private static let allowanceSeconds = 30.0

    @Test("A background-thread, memory-growing (1 GiB-capped) non-cooperative hang still self-recovers — via native timeout, same as a cooperative sleep hang")
    func backgroundThreadHangStillSelfRecovers() async throws {
        let directory = try Acceptance.stageFixture("XcodeProject")
        let destination = try Acceptance.iPhoneDestination()
        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "HangContainmentDemo", destination: destination)
        )
        let adapter = XcodeBuildAdapter(configuration: configuration, kind: .xcodeProject, projectFile: nil, projectRoot: directory)
        let artifact = try await adapter.buildBaseline(in: directory)

        let target = "HangContainmentTests"
        let items = [
            BatchMutantItem(
                id: MutationID(rawValue: "A"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangContainmentTests/testPassesA")]
            ),
            BatchMutantItem(
                id: MutationID(rawValue: "B"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangContainmentTests/testCPUBoundHang")]
            ),
            BatchMutantItem(
                id: MutationID(rawValue: "C"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangContainmentTests/testPassesC")]
            )
        ]

        let results = await adapter.runBatch(
            items, in: directory, timeoutSeconds: 300, nativeTimeoutAllowanceSeconds: Self.allowanceSeconds
        )

        // Recovers cleanly — the hang is contained, siblings run, the batch
        // process is never outer-killed. Real, but not what Phase H7 found
        // for the actual production hang.
        #expect(results[MutationID(rawValue: "A")]?.status == .passed)
        #expect(results[MutationID(rawValue: "B")]?.status == .timedOut)
        #expect(results[MutationID(rawValue: "C")]?.status == .passed)
    }

    @Test("A main-thread, memory-growing (app-hosted) non-cooperative hang also self-recovers — via a faster, different mechanism (SIGTRAP), not native timeout")
    func mainThreadHangSelfRecoversViaADifferentMechanism() async throws {
        let directory = try Acceptance.stageFixture("XcodeProject")
        let destination = try Acceptance.iPhoneDestination()
        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "HangAppDemo", destination: destination)
        )
        let adapter = XcodeBuildAdapter(configuration: configuration, kind: .xcodeProject, projectFile: nil, projectRoot: directory)
        let artifact = try await adapter.buildBaseline(in: directory)

        let target = "HangAppTests"
        let items = [
            BatchMutantItem(
                id: MutationID(rawValue: "A"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangAppTests/testPassesA")]
            ),
            BatchMutantItem(
                id: MutationID(rawValue: "B"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangAppTests/testMainThreadCPUBoundHang")]
            ),
            BatchMutantItem(
                id: MutationID(rawValue: "C"), artifact: artifact,
                selectedTests: [TestIdentifier(target: target, qualifiedName: "HangAppTests/testPassesC")]
            )
        ]

        let results = await adapter.runBatch(
            items, in: directory, timeoutSeconds: 300, nativeTimeoutAllowanceSeconds: Self.allowanceSeconds
        )

        #expect(results[MutationID(rawValue: "A")]?.status == .passed)
        #expect(results[MutationID(rawValue: "C")]?.status == .passed)

        // C1.1 (competitive-parity program, 2026-08-26): originally pinned
        // `.crashed` only. Re-investigated after 3 local reproductions of
        // `.failed` instead, all on unmodified `main` — confirmed this is
        // genuine (rare, ~1-in-16 observed across repeated local runs) OS-
        // level nondeterminism in *which* signal Xcode's own recovery
        // machinery surfaces for the identical fault, not a MutantKit
        // regression:
        //
        //   - Direct, unbatched reproduction (`xcodebuild test-without-
        //     building -only-testing:...testMainThreadCPUBoundHang`,
        //     current Xcode/macOS) reliably shows the OS's unresponsive-app
        //     watchdog firing (`libdispatch.dylib: Abort Cause ...`,
        //     `xcresulttool`'s `testFailures[].failureText` prefixed
        //     `Crash:`) after a `Restarting after unexpected exit, crash,
        //     or test timeout` recovery cycle — the same mechanism Phase H8
        //     originally observed.
        //   - A batch-tree dump of both the one observed `.failed` run and
        //     several `.crashed` runs (`xcresulttool get test-results
        //     tests`, the exact JSON `XCResultAdapter.classify(batch:
        //     tree:)` reads) confirms the tree correctly preserves the
        //     `Crash:`-prefixed failure text whenever the crash path is the
        //     one Xcode's recovery surfaces — ruling out a batch-attribution
        //     bug in `XCResultAdapter` itself as the explanation for the
        //     `.failed` observation. `ownFailures`'s per-configuration
        //     failure-text reconstruction was directly inspected and is not
        //     at fault.
        //   - In every repro, siblings A and C still ran and passed, and no
        //     run hung, produced `.infrastructureFailure`, or reported a
        //     false `.passed` for B — the actual production invariant this
        //     suite exists to pin (see module doc comment) held in both
        //     observed shapes.
        //
        // So `.crashed` and `.failed` are both real, valid representations
        // of the same underlying guarantee for this fixture: a
        // non-cooperative test-host failure is detected (never silently
        // passed), the runner terminates or is reclaimed, sibling
        // executions in the same batch remain unaffected, and the result is
        // never ambiguous (`.infrastructureFailure`) or a hang
        // (`.timedOut` — deliberately *not* included here: that is the
        // *other* hang shape's own signature, `backgroundThreadHangStill
        // SelfRecovers` above, and blurring the two would erase the exact
        // distinction Phase H8 built this pair of tests to keep visible).
        // `.passed`, `.timedOut`, and `.infrastructureFailure` all still
        // fail this assertion — only the two shapes actually observed
        // under real, repeated reproduction are accepted.
        let bResult = results[MutationID(rawValue: "B")]
        #expect(
            bResult?.status == .crashed || bResult?.status == .failed,
            "diagnosis was: \(bResult?.diagnosis ?? "nil")"
        )
    }
}
