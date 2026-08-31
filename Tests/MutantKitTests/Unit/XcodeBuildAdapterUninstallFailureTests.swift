@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `uninstallStaleApp` used to swallow a real `simctl uninstall` failure
/// entirely via a bare `try?`, with no diagnostic reaching anyone and the
/// mutant's run proceeding anyway — a real, static asymmetry against how
/// this codebase treats the analogous `boot`/`bootstatus` failure class
/// (retried, diagnosed, never silently swallowed). Named in
/// `Research/known-issues/schemata-confirm-timeout-image-uuid-mismatch.md`
/// as a plausible, unconfirmed contributor to a reported image-UUID
/// mismatch. Now fail-closed: a genuine failure returns
/// `.failed(diagnosis:)`, and both real callers (`leaseAndRunTests`,
/// `leaseAndRunSchemataToken`) turn that into an `.infrastructureFailure`
/// `TestRunResult` instead of proceeding against an unproven device.
///
/// These tests exercise the real fix against a real `simctl` invocation
/// (an intentionally-invalid device UDID, confirmed empirically to produce
/// a real, deterministic, non-zero-exit failure — `xcrun simctl uninstall
/// <bogus-udid> <bundle-id>` exits 148 with "Invalid device: ..."), not a
/// scripted double: the whole point is what real `simctl` actually does,
/// which is exactly what a scripted `ProcessRunner` could not prove.
@Suite("XcodeBuildAdapter: uninstallStaleApp fail-closed")
struct XcodeBuildAdapterUninstallFailureTests {
    private static let bogusUDID = "NONEXISTENT-UDID-0000-000000000000"
    private static let bundleID = "com.example.definitely.not.installed.app"

    private func adapter() -> XcodeBuildAdapter {
        XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: FileManager.default.temporaryDirectory
        )
    }

    /// A minimal, real, format-version-1 `.xctestrun` plist: a single
    /// top-level target dictionary naming one `TestHostBundleIdentifier` —
    /// exactly the shape `bundleIdentifiers(inXCTestRun:)` already parses.
    private func makeXCTestRun() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeBuildAdapterUninstallFailureTests-\(UUID().uuidString).xctestrun")
        let plist: [String: Any] = [
            "SomeTarget": ["TestHostBundleIdentifier": Self.bundleID]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    private func artifact(xctestrunPath: URL?) -> BuildArtifact {
        BuildArtifact(
            productsDirectory: FileManager.default.temporaryDirectory,
            productHash: nil,
            xctestrunPath: xctestrunPath,
            command: CommandRecord(executable: "xcodebuild", arguments: [], workingDirectory: "/tmp")
        )
    }

    private func lease(udid: String) -> SimulatorLease {
        SimulatorLease(
            device: SimulatorDevice(
                udid: udid, name: "Bogus", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", state: "Shutdown"
            )
        )
    }

    // MARK: - Message formatting (pure)

    @Test("uninstallFailureWarning names the bundle, the device, and the real detail")
    func warningMessageIsInformative() {
        let message = XcodeBuildAdapter.uninstallFailureWarning(
            bundleID: "com.example.App", udid: "ABCD-1234", detail: "Invalid device: ABCD-1234"
        )
        #expect(message.contains("com.example.App"))
        #expect(message.contains("ABCD-1234"))
        #expect(message.contains("Invalid device: ABCD-1234"))
        #expect(message.hasPrefix("warning:"))
    }

    // MARK: - Real simctl failure fails closed

    @Test("A real simctl uninstall failure returns .failed with an informative diagnosis, never proceeding as ready", .subprocessExclusive)
    func realUninstallFailureFailsClosed() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter().uninstallStaleApp(artifact: artifact(xctestrunPath: xctestrun), from: lease(udid: Self.bogusUDID))

        guard case .failed(let diagnosis) = outcome else {
            Issue.record("expected .failed for a real simctl failure against a bogus UDID, got \(outcome)")
            return
        }
        #expect(diagnosis.contains(Self.bundleID))
        #expect(diagnosis.contains(Self.bogusUDID))
        // Ordinarily `simctl`'s real "Invalid device: ..." text is captured
        // in full and preserved verbatim. On the rare real-CI occasion where
        // `ProcessSupervisor`'s bounded post-exit drain wait cannot confirm
        // stdout/stderr were fully read before this exit was observed
        // (`ProcessResult.outputComplete == false`), the contract is
        // instead that the diagnosis says so explicitly rather than
        // reporting nothing useful — never a blank/empty detail either way.
        #expect(
            diagnosis.localizedCaseInsensitiveContains("invalid device")
                || diagnosis.localizedCaseInsensitiveContains("subprocess output incomplete"),
            "expected either the real simctl error text or an explicit incomplete-output diagnosis, got: \(diagnosis)"
        )
    }

    /// The direct counterpart to `realUninstallFailureFailsClosed`'s
    /// loosened assertion above: rather than accepting either outcome
    /// depending on real CI timing, this forces `ProcessResult
    /// .outputComplete == false` deterministically via the injected
    /// `processRunner` seam and pins the exact diagnosis text a truncated
    /// capture must produce.
    @Test("An incomplete-but-failed simctl result fails closed with the exact 'subprocess output incomplete' diagnosis")
    func incompleteOutputProducesTheExactDiagnosis() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            processRunner: { _, _, _, _ in
                ProcessResult(
                    exitCode: 148,
                    standardOutput: Data(),
                    standardError: Data(),
                    durationSeconds: 1,
                    timedOut: false,
                    terminatingSignal: nil,
                    outputComplete: false
                )
            }
        )

        guard case .failed(let diagnosis) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(diagnosis.contains(Self.bundleID))
        #expect(diagnosis.contains(Self.bogusUDID))
        #expect(diagnosis.contains("subprocess output incomplete (stdout/stderr could not be fully captured before the process exited)"))
    }

    /// The differential-pair counterpart to
    /// `incompleteOutputProducesTheExactDiagnosis` above: forces
    /// `ProcessResult.outputComplete == true` with real, specific
    /// `combinedOutput` content through the identical injected
    /// `processRunner` seam, and pins that the diagnosis reports *that*
    /// content — never the incomplete-output message. Without this,
    /// `incompleteOutputProducesTheExactDiagnosis` alone could not
    /// distinguish the real fix from a hypothetical implementation that
    /// always reports the incomplete-output message regardless of
    /// `outputComplete`; only having both prove the `true`/`false` branches
    /// are genuinely distinguished.
    @Test("A complete-but-failed simctl result fails closed with the real captured detail, never the incomplete-output diagnosis")
    func completeOutputProducesTheRealDetail() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            processRunner: { _, _, _, _ in
                ProcessResult(
                    exitCode: 148,
                    standardOutput: Data(),
                    standardError: Data("Invalid device: \(Self.bogusUDID)".utf8),
                    durationSeconds: 1,
                    timedOut: false,
                    terminatingSignal: nil,
                    outputComplete: true
                )
            }
        )

        guard case .failed(let diagnosis) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(diagnosis.contains(Self.bundleID))
        #expect(diagnosis.contains(Self.bogusUDID))
        #expect(diagnosis.contains("Invalid device: \(Self.bogusUDID)"))
        #expect(!diagnosis.contains("subprocess output incomplete"))
    }

    @Test("A process launch failure (never even reaching simctl) also fails closed")
    func launchFailureFailsClosed() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        struct LaunchError: Error {}
        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            processRunner: { _, _, _, _ in throw LaunchError() }
        )

        guard case .failed(let diagnosis) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(diagnosis.contains(Self.bundleID))
        #expect(diagnosis.contains(Self.bogusUDID))
    }

    // MARK: - Legitimate "nothing to do" cases stay ready

    @Test("A build with no .xctestrun is .ready -- nothing for this method to name or uninstall")
    func noXCTestRunIsReady() async {
        let outcome = await adapter().uninstallStaleApp(artifact: artifact(xctestrunPath: nil), from: lease(udid: Self.bogusUDID))
        #expect(outcome == .ready)
    }

    @Test("A successful simctl uninstall (including 'nothing was installed', which also exits 0) is .ready")
    func successfulUninstallIsReady() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            processRunner: { _, _, _, _ in
                ProcessResult(
                    exitCode: 0, standardOutput: Data(), standardError: Data(), durationSeconds: 0.1,
                    timedOut: false, terminatingSignal: nil, outputComplete: true
                )
            }
        )
        #expect(outcome == .ready)
    }
}
