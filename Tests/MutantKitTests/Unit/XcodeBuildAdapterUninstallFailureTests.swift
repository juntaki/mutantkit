@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `uninstallStaleApp` used to swallow a real `simctl uninstall`
/// failure entirely via a bare `try?`, with no diagnostic reaching anyone,
/// then (an intermediate state) logged the failure but still let the run
/// proceed regardless — a real, static asymmetry against how this codebase
/// treats the analogous `boot`/`bootstatus` failure class (retried,
/// diagnosed, never silently proceeded past). A plausible, unconfirmed
/// contributor to a separate, still-open schemata-confirmation timing
/// investigation.
///
/// The hardened contract, proven here: `uninstallStaleApp` returns
/// `.ready`/`.failed` rather than `Void`, and both `runTestsAfterUninstall`
/// (isolated) and `runSchemataTokenAfterUninstall` (schemata) must report
/// `.infrastructureFailure` and never reach `xcodebuild
/// test-without-building` at all when it returns `.failed`.
///
/// These tests exercise the real fix against a real `simctl` invocation
/// (an intentionally-invalid device UDID, confirmed empirically to produce
/// a real, deterministic, non-zero-exit failure — `xcrun simctl uninstall
/// <bogus-udid> <bundle-id>` exits 148 with "Invalid device: ..."), not a
/// scripted double: the whole point is what real `simctl` actually does,
/// which is exactly what a scripted `ProcessRunner` could not prove.
@Suite("XcodeBuildAdapter: uninstallStaleApp fail-closed contract")
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
        SimulatorLease(device: SimulatorDevice(udid: udid, name: "Bogus", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", state: "Shutdown"))
    }

    // MARK: - Message formatting (pure)

    @Test("uninstallFailureWarning names the bundle, the device, and the real detail")
    func warningMessageIsInformative() {
        let message = XcodeBuildAdapter.uninstallFailureWarning(bundleID: "com.example.App", udid: "ABCD-1234", detail: "Invalid device: ABCD-1234")
        #expect(message.contains("com.example.App"))
        #expect(message.contains("ABCD-1234"))
        #expect(message.contains("Invalid device: ABCD-1234"))
        #expect(message.hasPrefix("warning:"))
    }

    // MARK: - Real simctl failure is reported AND returned as .failed

    @Test("A real simctl uninstall failure is both reported through the injected callback and returned as .failed", .subprocessExclusive)
    func realUninstallFailureIsReportedAndFailsClosed() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )

        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        // Ordinarily `simctl`'s real "Invalid device: ..." text is captured
        // in full and preserved verbatim. On the rare real-CI occasion where
        // `ProcessSupervisor`'s bounded post-exit drain wait cannot confirm
        // stdout/stderr were fully read before this exit was observed
        // (`ProcessResult.outputComplete == false`), the contract is instead
        // that the diagnosis says so explicitly rather than reporting
        // nothing useful. Both are real, meaningful, non-empty outcomes.
        #expect(
            detail.localizedCaseInsensitiveContains("invalid device")
                || detail.localizedCaseInsensitiveContains("subprocess output incomplete"),
            "expected either the real simctl error text or an explicit incomplete-output diagnosis, got: \(detail)"
        )

        let message = try #require(reported.first)
        #expect(reported.count == 1)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
    }

    /// The direct counterpart to `realUninstallFailureIsReportedAndFailsClosed`'s
    /// loosened assertion above: rather than accepting either outcome
    /// depending on real CI timing, this forces
    /// `ProcessResult.outputComplete == false` deterministically via the
    /// injected `processRunner` seam and pins the exact `.failed` detail a
    /// truncated capture must produce.
    @Test("An incomplete-but-failed simctl result returns .failed with the exact 'subprocess output incomplete' diagnosis")
    func incompleteOutputProducesTheExactFailedOutcome() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) },
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

        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        #expect(detail == "subprocess output incomplete (stdout/stderr could not be fully captured before the process exited)")

        let message = try #require(reported.first)
        #expect(reported.count == 1)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
    }

    /// The differential-pair counterpart to
    /// `incompleteOutputProducesTheExactFailedOutcome` above: forces
    /// `ProcessResult.outputComplete == true` with real, specific
    /// `combinedOutput` content through the identical injected
    /// `processRunner` seam, and pins that `.failed`'s own detail reports
    /// *that* content — never the incomplete-output message. Without this,
    /// `incompleteOutputProducesTheExactFailedOutcome` alone could not
    /// distinguish the real fix from a hypothetical implementation that
    /// always reports the incomplete-output message regardless of
    /// `outputComplete`; only having both prove the `true`/`false` branches
    /// are genuinely distinguished.
    @Test("A complete-but-failed simctl result returns .failed with the real captured detail, never the incomplete-output diagnosis")
    func completeOutputProducesTheRealFailedDetail() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) },
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

        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        #expect(detail == "Invalid device: \(Self.bogusUDID)")
        #expect(!detail.contains("subprocess output incomplete"))

        let message = try #require(reported.first)
        #expect(reported.count == 1)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
        #expect(message.contains("Invalid device: \(Self.bogusUDID)"))
    }

    @Test("A build with no .xctestrun reports nothing and returns .ready immediately")
    func noXCTestRunReturnsReady() async {
        var reported: [String] = []
        let outcome = await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: nil),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )
        #expect(outcome == .ready)
        #expect(reported.isEmpty)
    }

    /// The default `report:` argument is the one every real caller uses —
    /// confirmed here only to compile and run without crashing (writing to
    /// the real stderr of the test process is otherwise unobservable from
    /// inside the test itself, and does not need to be: the injected-callback
    /// tests above already pin the exact behavior this default wraps).
    @Test("The default report callback (real stderr) does not crash when invoked", .subprocessExclusive)
    func defaultReportCallbackDoesNotCrash() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter().uninstallStaleApp(artifact: artifact(xctestrunPath: xctestrun), from: lease(udid: Self.bogusUDID))
        guard case .failed = outcome else {
            Issue.record("expected .failed against the bogus UDID, got \(outcome)")
            return
        }
    }

    // MARK: - Launch suppression: a failed uninstall must never reach xcodebuild

    /// The regression this suite exists to close: before this fix, both
    /// `leaseAndRunTests` and `leaseAndRunSchemataToken` called
    /// `uninstallStaleApp` and then unconditionally proceeded to launch
    /// `xcodebuild test-without-building` regardless of what it returned.
    /// This drives the real, production `runTestsAfterUninstall` seam
    /// (the isolated path) directly, with a lease pointing at the same
    /// deliberately-invalid device the tests above already confirmed
    /// produces a real `.failed` outcome, and proves the result is
    /// `.infrastructureFailure` carrying the uninstall diagnosis — never a
    /// different diagnosis, which is what an xcodebuild launch against a
    /// nonexistent device would instead have produced.
    @Test("Isolated path: a failed uninstall reports infrastructureFailure, never launching xcodebuild", .subprocessExclusive)
    func isolatedPathSuppressesLaunchOnUninstallFailure() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let result = try await adapter().runTestsAfterUninstall(
            lease: lease(udid: Self.bogusUDID),
            artifact: artifact(xctestrunPath: xctestrun),
            in: FileManager.default.temporaryDirectory,
            label: "uninstall-suppression-isolated",
            timeoutSeconds: 30
        )

        #expect(result.status == .infrastructureFailure)
        #expect(result.resultArtifactPath == nil, "no .xcresult can exist — xcodebuild was never launched")
        #expect(result.diagnosis.contains(Self.bundleID))
        #expect(result.diagnosis.contains(Self.bogusUDID))
        #expect(
            result.diagnosis.localizedCaseInsensitiveContains("invalid device")
                || result.diagnosis.localizedCaseInsensitiveContains("subprocess output incomplete"),
            "the diagnosis must be the uninstall failure's own, not whatever xcodebuild would have said: \(result.diagnosis)"
        )
    }

    /// The schemata-path counterpart — drives `runSchemataTokenAfterUninstall`
    /// directly, same proof.
    @Test("Schemata path: a failed uninstall reports infrastructureFailure, never launching xcodebuild", .subprocessExclusive)
    func schemataPathSuppressesLaunchOnUninstallFailure() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let result = try await adapter().runSchemataTokenAfterUninstall(
            lease: lease(udid: Self.bogusUDID),
            artifact: artifact(xctestrunPath: xctestrun),
            in: FileManager.default.temporaryDirectory,
            timeoutSeconds: 30,
            environment: [:],
            testFilters: nil
        )

        #expect(result.status == .infrastructureFailure)
        #expect(result.resultArtifactPath == nil, "no .xcresult can exist — xcodebuild was never launched")
        #expect(result.diagnosis.contains(Self.bundleID))
        #expect(result.diagnosis.contains(Self.bogusUDID))
        #expect(
            result.diagnosis.localizedCaseInsensitiveContains("invalid device")
                || result.diagnosis.localizedCaseInsensitiveContains("subprocess output incomplete"),
            "the diagnosis must be the uninstall failure's own, not whatever xcodebuild would have said: \(result.diagnosis)"
        )
    }
}
