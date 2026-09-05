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
/// diagnosed, never silently proceeded past).
///
/// The hardened contract, proven here: `uninstallStaleApp` returns
/// `.ready`/`.failed` rather than `Void`; a `.failed` outcome always
/// carries a non-empty detail; and both `runTestsAfterUninstall`
/// (isolated) and `runSchemataTokenAfterUninstall` (schemata) report
/// `.infrastructureFailure` and never reach `xcodebuild
/// test-without-building` at all when it returns `.failed`.
///
/// **Why this suite no longer invokes real `simctl`.** It used to, on the
/// stated premise that `xcrun simctl uninstall <bogus-udid> <bundle-id>`
/// produces "a real, deterministic, non-zero-exit failure — exits 148 with
/// `Invalid device: ...`", and that only a real invocation could prove the
/// contract. CI disproved the determinism half: the same failing
/// invocation reached the caller with the real error text captured in full
/// on one run and with nothing captured at all on another (see
/// `ProcessResult.outputComplete`'s own doc comment, which records exactly
/// this observation). Assertions pinned to the exit code, the error
/// wording, or the completeness of the capture therefore flake, and the
/// suite had already started papering over that with
/// `"invalid device" || "subprocess output incomplete"` disjunctions —
/// assertions that pass whichever branch runs and so pin neither.
///
/// None of that non-determinism is in the contract. Which detail a given
/// `ProcessResult` shape must produce, and whether a `.failed` uninstall
/// suppresses the launch, are properties of this adapter's own code. They
/// are pinned here against a scripted `ProcessRunner`, one test per shape,
/// with no subprocess involved at all — so the suite is deterministic,
/// fast, and no longer needs `.subprocessExclusive`.
///
/// The real-`simctl` half is not deleted, just demoted to what it can
/// honestly prove: `XcodeBuildAdapterUninstallSmokeTests` (acceptance-
/// gated) runs the real tool, pins no wording and no exit code, and
/// asserts only the implication "a non-zero exit fails closed".
@Suite("XcodeBuildAdapter: uninstallStaleApp fail-closed contract")
struct XcodeBuildAdapterUninstallFailureTests {
    private static let bogusUDID = "NONEXISTENT-UDID-0000-000000000000"
    private static let bundleID = "com.example.definitely.not.installed.app"

    /// The exact string `uninstallFailureDetail` must produce when the
    /// capture could not be proven complete. Written out here, not read
    /// from production, so a change to the message is a test failure rather
    /// than something both sides agree on silently.
    private static let incompleteOutputDetail =
        "subprocess output incomplete (stdout/stderr could not be fully captured before the process exited)"

    // MARK: - Doubles

    /// An adapter whose `simctl` invocations are scripted. Every test below
    /// uses this; none reaches a real simulator, a real `simctl`, or a real
    /// `xcodebuild`.
    private func adapter(processRunner: @escaping ProcessRunner) -> XcodeBuildAdapter {
        let root = FileManager.default.temporaryDirectory
        return XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: root,
            resolvedDestination: nil,
            simulators: SimulatorPool(workingDirectory: root),
            processRunner: processRunner
        )
    }

    /// One scripted `simctl` outcome. The three failure shapes these tests
    /// pin differ only in `exitCode`/`stderr`/`outputComplete`, so they are
    /// spelled out at each call site rather than hidden behind defaults.
    private func scriptedRunner(
        exitCode: Int32, stderr: String, outputComplete: Bool
    ) -> ProcessRunner {
        { _, _, _, _ in
            ProcessResult(
                exitCode: exitCode,
                standardOutput: Data(),
                standardError: Data(stderr.utf8),
                durationSeconds: 1,
                timedOut: false,
                terminatingSignal: nil,
                outputComplete: outputComplete
            )
        }
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
        SimulatorLease(device: SimulatorDevice(
            udid: udid, name: "Bogus", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", state: "Shutdown"
        ))
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

    // MARK: - The three failure shapes, pinned one per test

    /// Shape 1 — the ordinary case: the process failed and its output was
    /// captured in full, so the detail is that output verbatim.
    @Test("A failed simctl whose output was captured in full reports that output as the detail")
    func completeOutputWithContentReportsThatContent() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter(
            processRunner: scriptedRunner(exitCode: 148, stderr: "Invalid device: \(Self.bogusUDID)", outputComplete: true)
        ).uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )

        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        #expect(detail == "Invalid device: \(Self.bogusUDID)")
        #expect(detail != Self.incompleteOutputDetail)

        #expect(reported.count == 1)
        let message = try #require(reported.first)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
        #expect(message.contains("Invalid device: \(Self.bogusUDID)"))
    }

    /// Shape 2 — the capture could not be proven complete. Reporting the
    /// partial bytes as if they were the whole story is exactly what
    /// `ProcessResult.outputComplete` exists to prevent, so the detail says
    /// so instead.
    @Test("A failed simctl whose output could not be fully captured says so explicitly")
    func incompleteOutputSaysSoExplicitly() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter(
            // Partial bytes present *and* the capture unproven: the detail
            // must still refuse them rather than quote half an error.
            processRunner: scriptedRunner(exitCode: 148, stderr: "Invalid dev", outputComplete: false)
        ).uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )

        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        #expect(detail == Self.incompleteOutputDetail)
        #expect(!detail.contains("Invalid dev"), "a partial capture must not be quoted as if it were the whole error")

        #expect(reported.count == 1)
        let message = try #require(reported.first)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
    }

    /// Shape 3 — the regression this suite could not previously catch: the
    /// process failed, the capture *was* complete, and there was genuinely
    /// nothing to capture. This reached the caller as an empty detail
    /// string on a real CI run (see `ProcessResult.outputComplete`'s doc
    /// comment); a fail-closed outcome whose diagnosis is empty is
    /// indistinguishable, to whoever reads the report, from a check that
    /// never ran.
    @Test("A failed simctl that wrote nothing at all still produces a non-empty detail naming the exit code")
    func completeButEmptyOutputNamesTheExitCode() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter(
            processRunner: scriptedRunner(exitCode: 148, stderr: "", outputComplete: true)
        ).uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )

        guard case let .failed(bundleID, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(bundleID == Self.bundleID)
        #expect(!detail.isEmpty, "a fail-closed outcome must never carry an empty diagnosis")
        #expect(detail == "simctl exited 148 without writing any diagnostic output")
        #expect(detail != Self.incompleteOutputDetail, "the capture was complete — this is not the truncation case")

        #expect(reported.count == 1)
        let message = try #require(reported.first)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
        #expect(!message.hasSuffix(": \n"), "the warning must not end in a bare colon")
    }

    /// Whitespace-only output is the same finding as no output: there is
    /// nothing to report, so the exit code has to carry the diagnosis.
    @Test("Whitespace-only output is treated as no output, not as a detail")
    func whitespaceOnlyOutputNamesTheExitCode() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter(
            processRunner: scriptedRunner(exitCode: 64, stderr: "  \n\t\n ", outputComplete: true)
        ).uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { _ in }
        )

        guard case let .failed(_, detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(detail == "simctl exited 64 without writing any diagnostic output")
    }

    // MARK: - The success and no-op paths

    /// The branch is on exit status, not on whether anything was written:
    /// a successful uninstall that printed nothing is still `.ready`.
    @Test("A successful simctl uninstall returns .ready and reports nothing")
    func zeroExitReturnsReady() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        let outcome = await adapter(
            processRunner: scriptedRunner(exitCode: 0, stderr: "", outputComplete: true)
        ).uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )

        #expect(outcome == .ready)
        #expect(reported.isEmpty)
    }

    @Test("A build with no .xctestrun reports nothing and returns .ready immediately")
    func noXCTestRunReturnsReady() async {
        var reported: [String] = []
        let outcome = await adapter(
            processRunner: { _, _, _, _ in
                Issue.record("simctl must not be invoked at all when there is no .xctestrun")
                return ProcessResult(
                    exitCode: 0, standardOutput: Data(), standardError: Data(),
                    durationSeconds: 0, timedOut: false, terminatingSignal: nil, outputComplete: true
                )
            }
        ).uninstallStaleApp(
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
    @Test("The default report callback (real stderr) does not crash when invoked")
    func defaultReportCallbackDoesNotCrash() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let outcome = await adapter(
            processRunner: scriptedRunner(exitCode: 148, stderr: "Invalid device", outputComplete: true)
        ).uninstallStaleApp(artifact: artifact(xctestrunPath: xctestrun), from: lease(udid: Self.bogusUDID))
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    // MARK: - Launch suppression: a failed uninstall must never reach xcodebuild

    /// The regression this suite exists to close: before the fix, both
    /// `leaseAndRunTests` and `leaseAndRunSchemataToken` called
    /// `uninstallStaleApp` and then unconditionally proceeded to launch
    /// `xcodebuild test-without-building` regardless of what it returned.
    ///
    /// Driven through the real, production `runTestsAfterUninstall` seam
    /// with a scripted failing `simctl`. If the suppression regressed, this
    /// would reach a real `xcodebuild` against a nonexistent device and
    /// produce a different diagnosis — so the assertion on *which*
    /// diagnosis comes back is what proves the launch never happened.
    @Test("Isolated path: a failed uninstall reports infrastructureFailure, never launching xcodebuild")
    func isolatedPathSuppressesLaunchOnUninstallFailure() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let result = try await adapter(
            processRunner: scriptedRunner(exitCode: 148, stderr: "Invalid device: \(Self.bogusUDID)", outputComplete: true)
        ).runTestsAfterUninstall(
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
            result.diagnosis.contains("Invalid device: \(Self.bogusUDID)"),
            "the diagnosis must be the uninstall failure's own, not whatever xcodebuild would have said: \(result.diagnosis)"
        )
    }

    /// The schemata-path counterpart — drives `runSchemataTokenAfterUninstall`
    /// directly, same proof.
    @Test("Schemata path: a failed uninstall reports infrastructureFailure, never launching xcodebuild")
    func schemataPathSuppressesLaunchOnUninstallFailure() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let result = try await adapter(
            processRunner: scriptedRunner(exitCode: 148, stderr: "Invalid device: \(Self.bogusUDID)", outputComplete: true)
        ).runSchemataTokenAfterUninstall(
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
            result.diagnosis.contains("Invalid device: \(Self.bogusUDID)"),
            "the diagnosis must be the uninstall failure's own, not whatever xcodebuild would have said: \(result.diagnosis)"
        )
    }

    /// The suppression must not depend on *which* failure shape came back:
    /// an empty-output failure suppresses the launch exactly the same way,
    /// carrying its own non-empty diagnosis.
    @Test("Launch suppression holds for an empty-output failure too, with a non-empty diagnosis")
    func suppressionHoldsForEmptyOutputFailure() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        let result = try await adapter(
            processRunner: scriptedRunner(exitCode: 148, stderr: "", outputComplete: true)
        ).runTestsAfterUninstall(
            lease: lease(udid: Self.bogusUDID),
            artifact: artifact(xctestrunPath: xctestrun),
            in: FileManager.default.temporaryDirectory,
            label: "uninstall-suppression-empty-output",
            timeoutSeconds: 30
        )

        #expect(result.status == .infrastructureFailure)
        #expect(result.resultArtifactPath == nil)
        #expect(result.diagnosis.contains("simctl exited 148 without writing any diagnostic output"))
    }
}
