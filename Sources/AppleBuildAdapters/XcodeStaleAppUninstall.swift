import Foundation
import MutationExecution
import MutationModel

//
// Extracted from `XcodeBuildAdapter.swift` as part of this project's
// internal execution-engine restructuring (see its own, private planning
// notes, not part of this public repo, for the full rationale). A pure
// move of the stale-app-uninstall concern:
// its only stored dependency is `processRunner` (constructor-injected,
// matching `XcodeBuildAdapter.processRunner`'s own doc comment's stated
// rationale for why it is constructor- not call-site-injected). No behavior
// change: every branch, diagnosis string, and timeout below is identical to
// the code this replaced. Directly implements Structural Invariant 2's leaf
// (a failed uninstall must fail closed) — `XcodeBuildAdapter`'s two
// choke-point methods (`runTestsAfterUninstall`/
// `runSchemataTokenAfterUninstall`) stay unmoved and still enforce the
// sequencing decision themselves (plan §6.2); this type has no way to reach
// `xcodebuild` at all, only `simctl`.
//

/// Removes whatever a leased device already has installed under a mutant's
/// own bundle identifier before it is tested — see `XcodeBuildAdapter
/// .uninstallStaleApp`'s original doc comment (preserved there, now
/// forwarding here) for the full rationale and the fail-closed contract.
struct StaleAppUninstaller: Sendable {
    /// How this actually spawns `simctl` — `AdapterSupport.swift`'s
    /// `ProcessRunner` seam, constructor-injected so
    /// `XcodeBuildAdapterUninstallFailureTests` can script it deterministically.
    let processRunner: ProcessRunner

    enum Outcome: Sendable, Equatable {
        case ready
        case failed(bundleID: String, detail: String)
    }

    /// **Fail-closed: a genuine `simctl uninstall` failure blocks this
    /// mutant's run** — the caller must never proceed to launch `xcodebuild
    /// test-without-building` once this returns `.failed`. See
    /// `XcodeBuildAdapter.uninstallStaleApp`'s original doc comment for the
    /// full "nothing to uninstall exits 0 too" rationale this preserves
    /// verbatim.
    func uninstall(
        artifact: BuildArtifact, from lease: SimulatorLease,
        report: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async -> Outcome {
        guard let xctestrun = artifact.xctestrunPath else { return .ready }
        for bundleID in Self.bundleIdentifiers(inXCTestRun: xctestrun) {
            let result: ProcessResult?
            do {
                // `timeoutSeconds` was 30. Real public CI evidence
                // (2026-09-11) showed this `simctl uninstall` call
                // SIGTERM'd (exit 143) under real CI-load slowness —
                // `ProcessSupervisor.run`'s own timeout escalation firing
                // before `simctl` finished. Raised with real headroom
                // (30 -> 120), matching this session's other CI-load
                // timeout fixes.
                result = try await processRunner(
                    ToolPaths.xcrun,
                    ["simctl", "uninstall", lease.device.udid, bundleID],
                    FileManager.default.temporaryDirectory,
                    120
                )
            } catch {
                let detail = "\(error)"
                report(Self.uninstallFailureWarning(bundleID: bundleID, udid: lease.device.udid, detail: detail))
                return .failed(bundleID: bundleID, detail: detail)
            }
            if let result, !result.succeeded {
                let detail = Self.uninstallFailureDetail(result)
                report(Self.uninstallFailureWarning(bundleID: bundleID, udid: lease.device.udid, detail: detail))
                return .failed(bundleID: bundleID, detail: detail)
            }
        }
        return .ready
    }

    /// The `.failed` detail for a non-zero `simctl uninstall`, in the three
    /// shapes a real failure can arrive in — none of which may produce an
    /// empty string. A fail-closed outcome whose diagnosis says nothing is
    /// indistinguishable, to whoever later reads the report, from a check
    /// that never ran; "zero work" must not be able to look like an answer.
    ///
    /// - Capture incomplete (`ProcessResult.outputComplete == false`): say
    ///   so explicitly rather than pass a partial read off as the whole
    ///   story. See `ProcessResult.outputComplete`'s own doc comment.
    /// - Captured in full, with content: that content, redacted and
    ///   truncated. This is the ordinary case (`Invalid device: ...`).
    /// - Captured in full and genuinely empty: name the exit code, because
    ///   "simctl failed and wrote nothing" is itself the diagnosis. Before
    ///   this branch existed the detail was the empty string, and the
    ///   warning a human saw ended in a bare colon.
    ///
    /// A pure function over an already-observed `ProcessResult`, so the
    /// contract tests pin all three branches deterministically without a
    /// real `simctl` invocation.
    static func uninstallFailureDetail(_ result: ProcessResult) -> String {
        guard result.outputComplete else {
            return "subprocess output incomplete (stdout/stderr could not be fully captured before the process exited)"
        }
        let captured = OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard captured.isEmpty else { return captured }
        return "simctl exited \(result.exitCode) without writing any diagnostic output"
    }

    /// The exact text `uninstall` reports for a genuine failure — a pure
    /// function so `XcodeBuildAdapterUninstallFailureTests` can pin its
    /// wording directly, independent of whichever real `simctl` error text
    /// happened to be observed. Also called directly, as
    /// `XcodeBuildAdapter.uninstallFailureWarning` (a thin forwarder kept
    /// there — see that file), by that same suite's own
    /// "names the bundle, the device, and the real detail" test.
    static func uninstallFailureWarning(bundleID: String, udid: String, detail: String) -> String {
        "warning: could not uninstall stale app \(bundleID) from simulator \(udid) before this mutant's test run: \(detail)\n"
    }

    /// Every `TestHostBundleIdentifier` named in a `.xctestrun` plist — the app
    /// each test target is hosted inside, and so the app a stale simulator
    /// install of it could shadow. Same two on-disk shapes as
    /// `Diagnostics.testTargets(inXCTestRun:)`: format version 2 nests targets
    /// under `TestConfigurations`, version 1 puts them at the top level next to
    /// a metadata key.
    static func bundleIdentifiers(inXCTestRun url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any]
        else { return [] }

        let targets: [[String: Any]] = if let configurations = root["TestConfigurations"] as? [[String: Any]] {
            configurations.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            root.values.compactMap { $0 as? [String: Any] }
        }

        return Array(Set(targets.compactMap { $0["TestHostBundleIdentifier"] as? String })).sorted()
    }
}
