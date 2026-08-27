@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Phase C1.2 follow-up (competitive-parity program): `uninstallStaleApp`
/// used to swallow a real `simctl uninstall` failure entirely via a bare
/// `try?`, with no diagnostic reaching anyone — a real, static asymmetry
/// against how this codebase treats the analogous `boot`/`bootstatus`
/// failure class (retried, diagnosed, never silently swallowed). Named in
/// `Research/known-issues/schemata-confirm-timeout-image-uuid-mismatch.md`
/// as a plausible, unconfirmed contributor to that issue.
///
/// These tests exercise the real fix against a real `simctl` invocation
/// (an intentionally-invalid device UDID, confirmed empirically to produce
/// a real, deterministic, non-zero-exit failure — `xcrun simctl uninstall
/// <bogus-udid> <bundle-id>` exits 148 with "Invalid device: ..."), not a
/// scripted double: the whole point is what real `simctl` actually does,
/// which is exactly what a scripted `ProcessRunner` could not prove.
@Suite("XcodeBuildAdapter: uninstallStaleApp failure reporting")
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

    // MARK: - Real simctl failure is reported, never thrown

    @Test(
        "A real simctl uninstall failure is reported through the injected callback, and the call still completes without throwing",
        .subprocessExclusive
    )
    func realUninstallFailureIsReported() async throws {
        let xctestrun = try makeXCTestRun()
        defer { try? FileManager.default.removeItem(at: xctestrun) }

        var reported: [String] = []
        // `uninstallStaleApp` is `async -> Void`, never `throws` — this call
        // completing at all (reaching the assertions below) is itself part
        // of the proof that a real failure never blocks or fails the run.
        await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: xctestrun),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )

        let message = try #require(reported.first)
        #expect(reported.count == 1)
        #expect(message.contains(Self.bundleID))
        #expect(message.contains(Self.bogusUDID))
        #expect(message.localizedCaseInsensitiveContains("invalid device"), "expected the real simctl error text to be preserved: \(message)")
    }

    @Test("A build with no .xctestrun reports nothing and returns immediately")
    func noXCTestRunReportsNothing() async {
        var reported: [String] = []
        await adapter().uninstallStaleApp(
            artifact: artifact(xctestrunPath: nil),
            from: lease(udid: Self.bogusUDID),
            report: { reported.append($0) }
        )
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

        await adapter().uninstallStaleApp(artifact: artifact(xctestrunPath: xctestrun), from: lease(udid: Self.bogusUDID))
    }
}
