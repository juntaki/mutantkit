import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner

/// Applies CI quality thresholds to an already-finished report.
/// Keeping the gate separate from `run` lets CI change policy without
/// invalidating or re-running an expensive mutation campaign.
///
/// Thresholds come from two places, merged with CLI flags winning: the
/// `qualityGate` section of `mutantkit.yml` (if a config file is found —
/// `gate` works with no config at all, CLI-only, unlike `plan`/`run`) and
/// the flags below. `--baseline` unlocks the two regression checks
/// (`regression.maximumDrop`, `survived.newMaximum`), which answer "did
/// this PR make things worse," not just "is the absolute number good
/// enough" — the question that actually blocks a merge day to day.
struct GateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate",
        abstract: "Fail CI when a trusted mutation report misses configured thresholds."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Path to a MutantKit JSON report.")
    var report = ".mutantkit/report.json"

    @Option(name: .long, help: "Path to a prior MutantKit JSON report to compare against for regression checks.")
    var baseline: String?

    @Option(name: .long, help: "Minimum Tested Mutation Score as a percent, e.g. 80.")
    var minimumTested: Double?

    @Option(name: .long, help: "Minimum Effective Mutation Score as a percent, e.g. 60.")
    var minimumEffective: Double?

    @Option(name: .long, help: "Maximum allowed surviving mutants.")
    var maximumSurvivors: Int?

    @Option(name: .long, help: "Fail if a score drops by more than this many percentage points versus --baseline.")
    var regressionMaximumDrop: Double?

    @Option(name: .long, help: "Fail if more than this many mutants survive now but not in --baseline.")
    var newSurvivorsMaximum: Int?

    /// `QualityGateResult` is already exactly the shape a CI script wants —
    /// `passed` plus a `kind`-tagged `violations` list, fully computed
    /// before either output path renders it — so this serializes it
    /// directly (with `schemaVersion` added, see `QualityGateResult`'s own
    /// doc comment) rather than mapping it into a separate envelope type.
    /// Exit codes stay identical to the text path: `--json` still throws
    /// `MutantKitExit.qualityGateFailure` on a failing gate, after emitting
    /// the JSON document, so a CI script can rely on the exit code alone
    /// without parsing output, or parse `--json` and get the same verdict.
    @Flag(name: .long, help: "Emit the quality-gate result as JSON instead of the text summary below.")
    var json = false

    func run() throws {
        let runReport = try decode(reportPath: report, role: "report")
        let baselineReport = try baseline.map { try decode(reportPath: $0, role: "baseline report") }
        if let baselineReport { Self.warnIfBaselineReferencesUnknownOperators(baselineReport) }

        let thresholds = try resolveThresholds()

        let result = QualityGate.evaluate(report: runReport, thresholds: thresholds, baseline: baselineReport)

        if json {
            try JSONOutput.emit(result)
        } else if result.passed {
            print("Mutation quality gate passed.")
        } else {
            print("Mutation quality gate failed:")
            for violation in result.violations {
                print("  - \(violation.detail)")
            }
        }

        if !result.passed {
            throw ExitCode(MutantKitExit.qualityGateFailure)
        }
    }

    /// Reads and decodes a report from disk, emitting a structured `--json`
    /// error document instead of throwing prose when the file is missing or
    /// malformed — `gate --json` must emit exactly one JSON document on
    /// every path, including this one, which is exactly the failure an
    /// agent driving `gate` most needs structured output on (a report path
    /// that does not exist, or one that is not valid MutantKit JSON). The
    /// text path is unchanged: `MutantKitExit.onFailure` still prints the
    /// same prose to stderr and maps to `operationalError` it always has.
    private func decode(reportPath: String, role: String) throws -> RunReport {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
            return try RunReport.decode(from: data)
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            let code = error is DecodingError ? "reportMalformed" : "reportUnreadable"
            try JSONOutput.emitError(
                code: code,
                message: "Could not read the \(role) at \"\(reportPath)\" as a MutantKit JSON report: \(error)",
                remedy: "Check --report/--baseline point at a real report.json written by `mutantkit run`."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    /// v0.5 Stable Contracts: a baseline referencing a mutation whose
    /// operator ID has since been removed or renamed does not fail loudly —
    /// `newSurvivorViolations` compares by `MutationID` alone, so a survivor
    /// that can no longer be produced (its operator is gone) simply never
    /// shows up in `report`'s results and reads as "fixed" rather than "not
    /// re-verified." This does not change that comparison's behavior; it
    /// only surfaces the gap as a warning, cross-checked against
    /// `MutationRegistry`'s own known operator IDs, exactly the way
    /// `RunHistoryStore.records()` warns on an unreadable history file
    /// rather than silently treating it as absent.
    private static func warnIfBaselineReferencesUnknownOperators(_ baselineReport: RunReport) {
        let known = Set(MutationRegistry().allDescriptors.map(\.id))
        let unknown = Set(baselineReport.results.map(\.point.operatorID)).subtracting(known)
        guard !unknown.isEmpty else { return }
        FileHandle.standardError.write(Data("""
        warning: --baseline references operator ID(s) not known to this build's registry: \
        \(unknown.sorted().joined(separator: ", ")). A baseline mutation produced by a since-removed \
        or renamed operator cannot reappear in the current report and will read as "fixed" rather \
        than "not re-verified" by regression/new-survivor checks.\n
        """.utf8))
    }

    /// Config thresholds (base) merged with CLI flags (winning), then
    /// validated as a whole. A policy that cannot be resolved is an
    /// operational error — never an empty policy that lets a report pass.
    private func resolveThresholds() throws -> QualityGateThresholds {
        do {
            var thresholds = try loadConfiguredThresholds()
            if let minimumTested { thresholds.minimumTested = minimumTested / 100 }
            if let minimumEffective { thresholds.minimumEffective = minimumEffective / 100 }
            if let maximumSurvivors { thresholds.maximumSurvivors = maximumSurvivors }
            if let regressionMaximumDrop { thresholds.regressionMaximumDrop = regressionMaximumDrop / 100 }
            if let newSurvivorsMaximum { thresholds.newSurvivorsMaximum = newSurvivorsMaximum }
            try thresholds.validate()
            return thresholds
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            try JSONOutput.emitError(
                code: (error is QualityGateThresholdError || error is QualityGateSettingsError)
                    ? "thresholdInvalid" : "policyUnavailable",
                message: "Could not resolve the quality-gate policy: \(error)",
                remedy: "Fix the --config path, the mutantkit.yml qualityGate section or the threshold flags. "
                    + "Flag-only use needs no --config and no mutantkit.yml in the project root."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    /// `gate` tolerates having no `mutantkit.yml` at all (CLI flags alone are
    /// enough to run it standalone against a report). Only that case — no
    /// `--config` and no default file — yields an empty policy. An explicit
    /// `--config` that is missing, or any found config that is unreadable or
    /// invalid, fails: a typo must not silently drop the quality policy.
    private func loadConfiguredThresholds() throws -> QualityGateThresholds {
        if common.configPath == nil {
            let defaultFile = common.resolvedProjectRoot.appendingPathComponent(ConfigurationLoader.fileName)
            guard FileManager.default.fileExists(atPath: defaultFile.path) else { return QualityGateThresholds() }
        }
        let configuration = try ConfigurationLoader.load(
            explicitPath: common.configPath, projectRoot: common.resolvedProjectRoot
        )
        return try configuration.qualityGate.resolvedThresholds()
    }
}
