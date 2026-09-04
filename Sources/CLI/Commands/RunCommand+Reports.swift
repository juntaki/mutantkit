import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel
import Reporting

/// Report rendering and report-related resolution for `RunCommand`.
///
/// Moved verbatim out of `RunCommand.swift` (which sat 5 lines over this
/// project's `file_length` limit) following the same convention as
/// `RunCommand+DependencyResolutionPreflight.swift`: an `extension
/// RunCommand` in its own file, purely for size, not because reporting
/// belongs to a different feature. `emit` is `internal`, not `private`,
/// for exactly that reason — its only caller,
/// `runAfterSimulatorPoolProvisioned`, lives in `RunCommand.swift` — while
/// `filename` stays `private`: `emit` is its only caller and moved along.
extension RunCommand {
    func emit(_ report: RunReport, settings: Configuration, runDirectory: URL) throws {
        var rendered = try ReporterRegistry.renderAll(
            report,
            kinds: settings.reports.filter { $0 != .strykerJSON }
        )

        // Built here rather than through the registry because only the CLI knows
        // where the sources are. Without a provider the export carries no source,
        // and the Stryker viewer has nothing to highlight — which is most of the
        // reason to export in that format at all.
        if settings.reports.contains(.strykerJSON) {
            let root = common.resolvedProjectRoot
            rendered[.strykerJSON] = try StrykerReporter(
                sourceProvider: { relativePath in
                    try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
                }
            ).render(report)
        }

        if let console = rendered[.console] {
            print(console)
        }
        if let xcode = rendered[.xcode], !xcode.isEmpty {
            print(xcode)
        }
        if let githubActions = rendered[.githubActions], !githubActions.isEmpty {
            print(githubActions)
        }

        for (kind, contents) in rendered.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let filename = filename(for: kind) else { continue }
            let url = kind == .json && output != nil
                ? URL(fileURLWithPath: output!)
                : runDirectory.appendingPathComponent(filename)
            try Data(contents.utf8).write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    /// Console, Xcode, and GitHub Actions output go to the terminal, not to a
    /// file — writing them too would leave stray artifacts nobody asked for,
    /// and GitHub's own runner only recognizes `::warning::`/`::error::`
    /// workflow commands when they appear in a step's live stdout, never in
    /// a file it would have to be told to go read.
    private func filename(for kind: ReportKind) -> String? {
        switch kind {
        case .console, .xcode, .githubActions: nil
        case .json: "report.json"
        case .strykerJSON: "stryker-report.json"
        case .html: "report.html"
        case .ciSummary: "summary.md"
        case .sonar: "sonar-issues.json"
        case .sarif: "mutantkit.sarif.json"
        }
    }

    /// Records `report` to `store` — best-effort, like the checkpoint write
    /// inside `MutationRunner.finalize` (score integrity never depends on
    /// history), but a silently discarded failure would quietly break
    /// `mutantkit history` with nobody noticing until they went looking for a
    /// run that never showed up. A failure is written to `stderr` the same
    /// way `MutationRunner.finalize` surfaces a checkpoint write failure —
    /// `try?` alone would swallow it.
    ///
    /// Pulled out of `run()`, on the same terms as `resolveTestAdapter`/
    /// `lockIdentity` below, so the surfacing behavior itself is directly
    /// testable without a real project or adapter. `stderr` is injectable for
    /// exactly that reason; production always uses the real
    /// `FileHandle.standardError`.
    ///
    /// Returns the diagnosis written on failure, `nil` on success — mostly
    /// useful to a caller (a test) that wants to assert a failure was
    /// actually surfaced rather than just that some output happened.
    /// Pulled out of `run()` so this bad-input check is directly testable —
    /// the same reason `recordHistory`/`resolveTestAdapter`/`lockIdentity`
    /// below are their own functions rather than inlined. Bad input, not a
    /// usage-syntax error: every other bad-input case in this command
    /// already throws `MutantKitExit.operationalError` explicitly rather
    /// than `ArgumentParser`'s own `ValidationError` (exit 64), and this one
    /// should be no different (see `MutantKitExit`'s own exit-code
    /// contract).
    static func resolvedReports(from raw: [String]) throws -> [ReportKind] {
        try raw.map { value in
            guard let kind = ReportKind(rawValue: value) else {
                print("Unknown report '\(value)'. Expected one of: \(ReportKind.allCases.map(\.rawValue).joined(separator: ", ")).")
                throw ExitCode(MutantKitExit.operationalError)
            }
            return kind
        }
    }

    @discardableResult
    static func recordHistory(
        _ report: RunReport,
        to store: RunHistoryStore,
        stderr: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) -> String? {
        do {
            try store.record(report)
            return nil
        } catch {
            let diagnosis = "history write failed for \(report.planID): \(error)"
            stderr("warning: \(diagnosis)\n")
            return diagnosis
        }
    }

    /// Stryker-style early abort: selected tests run in historical
    /// kill-priority order, stopping after the first trustworthy detection.
    /// Two modes:
    ///
    /// 1. With `testBatchSize`, *and* an adapter that actually supports
    ///    batching: wave-based early kill — each wave batch-tests one
    ///    prioritised test per surviving mutant. The priority store is
    ///    handed to `MutationRunner` directly, which runs the wave loop
    ///    internally (see `MutationRunner.testInWaves`). No adapter
    ///    wrapping needed.
    ///
    /// 2. Otherwise (no `testBatchSize`, or an adapter — e.g. a plain
    ///    SwiftPM package's — that does not conform to `BatchTestable`):
    ///    per-invocation `PrioritizingTestAdapter` wrapping, which runs one
    ///    test per xcodebuild call. `testBatchSize` being configured is not
    ///    enough on its own to pick wave mode: `MutationRunner` only enters
    ///    the wave loop when its test adapter is genuinely `BatchTestable`,
    ///  and handing it a priority store the runner will never consult
    ///    would silently discard `earlyAbortSelectedTests` instead of
    ///    falling back here.
    static func resolveTestAdapter(
        _ settings: Configuration, base: any TestAdapter, priorityStoreURL: URL
    ) -> (testAdapter: any TestAdapter, runnerPriorityStore: TestPriorityStore?) {
        guard settings.execution.selectCoveringTests, settings.execution.earlyAbortSelectedTests else {
            return (base, nil)
        }
        guard PrioritizingTestAdapter.wouldWrap(settings, base: base) else {
            return (base, TestPriorityStore(url: priorityStoreURL))
        }
        return (PrioritizingTestAdapter(base: base, priorityStore: TestPriorityStore(url: priorityStoreURL)), nil)
    }

    /// The `RunIsolationLock`'s key: prefers the destination as actually
    /// *resolved* (`ResolvedDestination.destinationArgument` — a device UDID
    /// once one has been pinned) over the raw, as-configured destination
    /// string, so two runs whose `mutantkit.yml`s spell the same simulator
    /// differently still collide on the same lock key instead of sailing
    /// past each other onto the same device.
    ///
    /// Falls back to the raw configured string (`settings.project.destination
    /// ?? "auto"`) when there is genuinely nothing more specific to key on:
    /// a non-Xcode adapter (a plain SwiftPM macOS package has no destination
    /// concept at all), or an Xcode destination that never resolved to a
    /// concrete device (`ResolvedDestination.device == nil` — a generic
    /// placeholder like `generic/platform=iOS`, or a macOS/physical-device
    /// destination `DestinationResolver` never touches `simctl` for).
    static func lockIdentity(for adapter: any ProjectAdapter, configuredDestination: String?) -> String {
        if let resolvedDestination = (adapter as? XcodeBuildProjectAdapter)?.resolvedDestination,
           resolvedDestination.device != nil {
            return resolvedDestination.destinationArgument
        }
        return configuredDestination ?? "auto"
    }

    /// `report` (if given) replaces the config's own `reports:` outright,
    /// exactly as it always has; `alsoReport` (if given) is then folded on
    /// top *additively* — see `mergedReports` below. Called unconditionally
    /// from `run()`; both being empty is the plain "just use the config"
    /// case and returns `configured` untouched.
    static func resolvedFinalReports(configured: [ReportKind], report: [String], alsoReport: [String]) throws -> [ReportKind] {
        var reports = configured
        if !report.isEmpty {
            reports = try resolvedReports(from: report)
        }
        if !alsoReport.isEmpty {
            reports = mergedReports(base: reports, additional: try resolvedReports(from: alsoReport))
        }
        return reports
    }

    /// `--also-report`'s entire effect: `base` with `additional` appended in
    /// the order given, skipping any kind already present in `base` or
    /// already added earlier in `additional` — so a CI wrapper that always
    /// passes the same fixed list of kinds can never duplicate one the
    /// project's own config already requested.
    static func mergedReports(base: [ReportKind], additional: [ReportKind]) -> [ReportKind] {
        var seen = Set(base)
        var merged = base
        for kind in additional where !seen.contains(kind) {
            seen.insert(kind)
            merged.append(kind)
        }
        return merged
    }
}
