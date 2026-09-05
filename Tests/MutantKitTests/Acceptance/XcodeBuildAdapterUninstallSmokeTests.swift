@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// The real-`simctl` half of `uninstallStaleApp`'s fail-closed contract,
/// demoted to a smoke test.
///
/// This used to be a unit test that invoked real `simctl` against a
/// deliberately-invalid device UDID and pinned the result, on the premise
/// that the invocation was deterministic — "exits 148 with `Invalid device:
/// ...`". CI disproved that premise: the identical failing invocation
/// reached the caller with the error text captured in full on one run and
/// with nothing captured at all on the next (recorded in
/// `ProcessResult.outputComplete`'s own doc comment). Every assertion that
/// pinned the exit code, the wording, or the completeness of the capture
/// was therefore asserting something the environment, not this code, gets
/// to decide.
///
/// So this suite pins none of them. `XcodeBuildAdapterUninstallFailureTests`
/// owns the contract — which detail each `ProcessResult` shape produces,
/// and that a failed uninstall never reaches `xcodebuild` — deterministically,
/// against a scripted `ProcessRunner`. What is left here is the one thing
/// only a real invocation can tell us, and it is asserted as an
/// implication rather than an equality:
///
///     the real tool exits non-zero  ⇒  the adapter fails closed,
///                                      with a non-empty diagnosis
///
/// A zero exit is not a failure of this test — it means the real tool
/// accepted an invalid device on this machine, which is the very
/// environment-dependence that made the old assertions flake. That branch
/// is asserted too (it must produce `.ready`, not a fabricated failure) and
/// logged, so a silent change in `simctl`'s behaviour is visible in the run
/// output instead of passing as though the failure path had been proven.
///
/// Off by default like every other acceptance suite:
/// `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: XcodeBuildAdapter uninstall fail-closed smoke", .enabled(if: Acceptance.isEnabled), .subprocessExclusive)
struct XcodeBuildAdapterUninstallSmokeTests {
    private static let bogusUDID = "NONEXISTENT-UDID-0000-000000000000"
    private static let bundleID = "com.example.definitely.not.installed.app"

    private func makeXCTestRun() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeBuildAdapterUninstallSmokeTests-\(UUID().uuidString).xctestrun")
        let plist: [String: Any] = [
            "SomeTarget": ["TestHostBundleIdentifier": Self.bundleID]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    @Test("A real simctl uninstall that exits non-zero fails closed with a non-empty diagnosis")
    func realNonZeroExitFailsClosed() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let workingDirectory = FileManager.default.temporaryDirectory

        // Observe what the real tool actually does *first*, so the assertion
        // below is a genuine implication and not a guess about the
        // environment. This is the same command `uninstallStaleApp` issues.
        let probe = try await defaultProcessRunner(
            ToolPaths.xcrun,
            ["simctl", "uninstall", Self.bogusUDID, Self.bundleID],
            workingDirectory,
            30
        )

        let adapter = XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: workingDirectory
        )
        var reported: [String] = []
        let outcome = await adapter.uninstallStaleApp(
            artifact: BuildArtifact(
                productsDirectory: workingDirectory,
                productHash: nil,
                xctestrunPath: xctestrun,
                command: CommandRecord(executable: "xcodebuild", arguments: [], workingDirectory: "/tmp")
            ),
            from: SimulatorLease(device: SimulatorDevice(
                udid: Self.bogusUDID, name: "Bogus",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", state: "Shutdown"
            )),
            report: { reported.append($0) }
        )

        guard probe.exitCode != 0 else {
            // Not a failure: the real tool accepted an invalid device here.
            // The contract still says the adapter must not invent a failure.
            print("""
            note: real `simctl uninstall \(Self.bogusUDID)` exited 0 on this machine \
            (outputComplete=\(probe.outputComplete)) — the non-zero branch was not exercised. \
            XcodeBuildAdapterUninstallFailureTests pins that branch deterministically.
            """)
            #expect(outcome == .ready)
            #expect(reported.isEmpty)
            return
        }

        // The only thing a real invocation is allowed to prove here. No
        // wording, no exit code, no capture-completeness is asserted --
        // every one of those is environment-dependent, which is exactly why
        // this suite exists separately from the contract tests.
        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("real simctl exited \(probe.exitCode) but the adapter did not fail closed: \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        #expect(!detail.isEmpty, "a fail-closed outcome must never carry an empty diagnosis")
        #expect(reported.count == 1)
        let message = try #require(reported.first)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
        print("note: real `simctl` exited \(probe.exitCode), outputComplete=\(probe.outputComplete), detail=\(detail)")
    }
}
