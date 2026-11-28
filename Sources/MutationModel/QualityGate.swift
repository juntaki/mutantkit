import Foundation

/// CI-facing mutation score thresholds, modelled after Stryker's high/low/break
/// concept but split across MutantKit's two scores so coverage quality cannot hide
/// behind a strong tested-only score.
public struct QualityGateThresholds: Codable, Sendable, Hashable {
    /// Fail when Tested Mutation Score is below this fraction (0...1).
    public var minimumTested: Double?
    /// Fail when Effective Mutation Score is below this fraction (0...1).
    public var minimumEffective: Double?
    /// Fail when the number of surviving mutants exceeds this count.
    public var maximumSurvivors: Int?
    /// Fail when a score drops by more than this many fractional points
    /// (0...1) versus the baseline report. Requires `baseline` to be passed
    /// to `evaluate` — a plain absolute threshold cannot answer "did this
    /// PR make things worse," which is the question that actually blocks a
    /// merge in day-to-day CI use.
    public var regressionMaximumDrop: Double?
    /// Fail when a MutationID survives now but did not survive in the
    /// baseline report. Also requires `baseline`. Distinct from
    /// `maximumSurvivors`: a project can carry a stable, reviewed backlog
    /// of survivors while still failing CI the moment a *new* one appears.
    public var newSurvivorsMaximum: Int?

    public init(
        minimumTested: Double? = nil,
        minimumEffective: Double? = nil,
        maximumSurvivors: Int? = nil,
        regressionMaximumDrop: Double? = nil,
        newSurvivorsMaximum: Int? = nil
    ) {
        self.minimumTested = minimumTested
        self.minimumEffective = minimumEffective
        self.maximumSurvivors = maximumSurvivors
        self.regressionMaximumDrop = regressionMaximumDrop
        self.newSurvivorsMaximum = newSurvivorsMaximum
    }
}

public extension QualityGateThresholds {
    /// Rejects threshold values that can never describe a real policy
    /// (non-finite or out-of-range fractions, negative counts). Checked on the
    /// final merged config + CLI values, so a typo like `--minimum-tested 800`
    /// fails as a policy error instead of making every report fail (or, for a
    /// negative count, behaving unpredictably).
    func validate() throws {
        func fraction(_ name: String, _ value: Double?) throws {
            guard let value else { return }
            guard value.isFinite, (0 ... 1).contains(value) else {
                throw QualityGateThresholdError.invalid(name: name, detail: "must be a finite percentage from 0 to 100 (found \(value * 100))")
            }
        }
        func count(_ name: String, _ value: Int?) throws {
            guard let value else { return }
            guard value >= 0 else {
                throw QualityGateThresholdError.invalid(name: name, detail: "must be a non-negative count (found \(value))")
            }
        }
        try fraction("minimum tested score", minimumTested)
        try fraction("minimum effective score", minimumEffective)
        try fraction("regression maximum drop", regressionMaximumDrop)
        try count("maximum survivors", maximumSurvivors)
        try count("new survivors maximum", newSurvivorsMaximum)
    }
}

public enum QualityGateThresholdError: Error, CustomStringConvertible, Equatable {
    case invalid(name: String, detail: String)

    public var description: String {
        switch self {
        case let .invalid(name, detail): "Invalid quality-gate threshold: \(name) \(detail)."
        }
    }
}

public struct QualityGateViolation: Codable, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case testedScore
        case effectiveScore
        case survivorCount
        case scoreUnavailable
        case scoreRegression
        case newSurvivors
        case baselineUnavailable
        /// A configured regression axis could not be compared: one side has
        /// no denominator for it.
        case regressionUnavailable
        /// The baseline and current reports mutated no file in common, so a
        /// score comparison would compare unrelated populations.
        case baselineIncompatible
        /// The current report contradicts itself (stored score, integrity,
        /// or duplicate results do not agree), so none of its
        /// numbers can be used.
        case reportInconsistent
        /// As `reportInconsistent`, for the `--baseline` report.
        case baselineInconsistent
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String { detail }
}

public struct QualityGateResult: Codable, Sendable, Hashable {
    /// Set internally to `SchemaVersion.qualityGateResult`, never a caller-
    /// supplied parameter — the same discipline `MutationPlan`/`RunReport`/
    /// `AgentEvidenceReport` already follow for their own `schemaVersion`,
    /// so nothing that builds a result can accidentally stamp it with the
    /// wrong version. This type is never decoded from disk today (`gate`
    /// only ever constructs it fresh from `evaluate`), but stamping it now
    /// means `mutantkit gate --json` carries the same versioning contract
    /// every other agent-facing `--json` output already does.
    public let schemaVersion: Int
    public let passed: Bool
    public let violations: [QualityGateViolation]

    public init(passed: Bool, violations: [QualityGateViolation]) {
        schemaVersion = SchemaVersion.qualityGateResult
        self.passed = passed
        self.violations = violations
    }
}

public enum QualityGate {
    /// Evaluates thresholds only against a trustworthy score. If integrity
    /// failed and no score exists, the gate fails closed rather than treating
    /// the missing number as zero or silently passing CI.
    ///
    /// Split into one collector per threshold *family* rather than one long
    /// sequence of `if let`s: every collector below returns the violations it
    /// found and never a `Bool`, so "this check could not be performed" has
    /// somewhere to go other than an implicit pass. The order violations are
    /// appended in is the order the thresholds are documented in
    /// `QualityGateThresholds`, and is preserved deliberately — `mutantkit
    /// gate` prints them in list order.
    public static func evaluate(
        report: RunReport,
        thresholds: QualityGateThresholds,
        baseline: RunReport? = nil
    ) -> QualityGateResult {
        let contradictions = contradictionViolations(report, kind: .reportInconsistent, role: "report")
        guard contradictions.isEmpty else {
            return QualityGateResult(passed: false, violations: contradictions)
        }
        guard report.integrity.passed, let score = report.score else {
            return QualityGateResult(
                passed: false,
                violations: [
                    QualityGateViolation(
                        kind: .scoreUnavailable,
                        detail: "Mutation score is unavailable because run integrity did not pass."
                    )
                ]
            )
        }

        var violations = absoluteViolations(score: score, thresholds: thresholds)

        // The baseline is consulted only when a configured threshold actually
        // needs one, so a run using absolute thresholds alone never has to
        // supply a baseline — and never fails for not having supplied one.
        if thresholds.regressionMaximumDrop != nil || thresholds.newSurvivorsMaximum != nil {
            violations += baselineViolations(
                report: report,
                baseline: baseline,
                thresholds: thresholds
            )
        }

        return QualityGateResult(passed: violations.isEmpty, violations: violations)
    }

    // MARK: Report validation

    /// One violation per failed report-only check, from the same checks
    /// `ReportReverifier` runs (never a second validator). Absent or legacy
    /// evidence (`.notVerifiable`) is not a contradiction and is ignored here.
    private static func contradictionViolations(
        _ report: RunReport, kind: QualityGateViolation.Kind, role: String
    ) -> [QualityGateViolation] {
        ReportReverifier.reportOnlyChecks(report)
            .filter { $0.status == .fail }
            .map { QualityGateViolation(kind: kind, detail: "The \(role) is inconsistent (\($0.name)): \($0.detail)") }
    }

    // MARK: Absolute thresholds

    /// The thresholds answerable from this run alone.
    private static func absoluteViolations(
        score: MutationScore,
        thresholds: QualityGateThresholds
    ) -> [QualityGateViolation] {
        var violations: [QualityGateViolation] = []

        if let minimum = thresholds.minimumTested {
            violations += minimumScoreViolations(
                label: "Tested", kind: .testedScore, actual: score.tested, minimum: minimum
            )
        }

        if let minimum = thresholds.minimumEffective {
            violations += minimumScoreViolations(
                label: "Effective", kind: .effectiveScore, actual: score.effective, minimum: minimum
            )
        }

        if let maximum = thresholds.maximumSurvivors, score.survived > maximum {
            violations.append(QualityGateViolation(
                kind: .survivorCount,
                detail: "\(score.survived) mutant(s) survived; configured maximum is \(maximum)."
            ))
        }

        return violations
    }

    /// One configured minimum against one score. A `nil` `actual` is a missing
    /// denominator, not a zero: reported as `.scoreUnavailable` so a threshold
    /// is never satisfied — or failed — against a number that does not exist.
    private static func minimumScoreViolations(
        label: String,
        kind: QualityGateViolation.Kind,
        actual: Double?,
        minimum: Double
    ) -> [QualityGateViolation] {
        guard let actual else {
            return [QualityGateViolation(
                kind: .scoreUnavailable,
                detail: "\(label) Mutation Score has no denominator and cannot satisfy a configured threshold."
            )]
        }
        guard actual < minimum else { return [] }
        return [QualityGateViolation(
            kind: kind,
            detail: String(
                format: "%@ Mutation Score %.2f%% is below the required %.2f%%.",
                label, actual * 100, minimum * 100
            )
        )]
    }

    // MARK: Baseline-relative thresholds

    /// The thresholds that can only be answered against a prior run. A
    /// configured-but-unanswerable threshold is itself a violation: an absent
    /// or untrustworthy baseline fails the gate rather than quietly skipping
    /// the checks that depend on it.
    private static func baselineViolations(
        report: RunReport,
        baseline: RunReport?,
        thresholds: QualityGateThresholds
    ) -> [QualityGateViolation] {
        if let baseline {
            let contradictions = contradictionViolations(baseline, kind: .baselineInconsistent, role: "baseline report")
            if !contradictions.isEmpty { return contradictions }
        }
        guard let baseline, baseline.integrity.passed, baseline.score != nil else {
            return [QualityGateViolation(
                kind: .baselineUnavailable,
                detail: "regression/newSurvivors thresholds are configured but no trustworthy baseline report was provided."
            )]
        }

        var violations: [QualityGateViolation] = []

        if let maximumDrop = thresholds.regressionMaximumDrop {
            violations += regressionViolations(
                report: report, baseline: baseline, maximumDrop: maximumDrop
            )
        }

        if let maximum = thresholds.newSurvivorsMaximum {
            violations += newSurvivorViolations(report: report, baseline: baseline, maximum: maximum)
        }

        return violations
    }

    /// How one configured regression axis relates the current run to the
    /// baseline. (A baseline whose scope shares nothing with the current run
    /// is `.baselineIncompatible` for every axis at once and is reported
    /// before any axis is looked at.) Explicit so "could not compare" can never be spelled as
    /// "no drop": every case either yields a number or a violation.
    enum AxisComparison: Equatable {
        case comparable(current: Double, prior: Double)
        case unavailable(String)
    }

    /// Both scores compared against their own counterpart in the baseline,
    /// with the baseline narrowed to the mutated files the two reports share (scope evidence taken
    /// from the reports' own results, not from the caller or a shell
    /// heuristic; plan IDs are deliberately not compared, so a baseline from
    /// an earlier commit stays usable). Identical scopes — the normal case —
    /// reduce to the whole-report score. A regression policy that cannot be
    /// answered is a violation, never a pass.
    private static func regressionViolations(
        report: RunReport,
        baseline: RunReport,
        maximumDrop: Double
    ) -> [QualityGateViolation] {
        let currentFiles = Set(report.results.map(\.point.file))
        let baselineFiles = Set(baseline.results.map(\.point.file))
        let common = currentFiles.intersection(baselineFiles)
        // The current report counts in full, so a weak new file lowers the
        // score instead of being ignored. As with any whole-report score, a
        // strong new file can dilute a regression in an existing one; that
        // limit predates this comparison. Only the baseline is narrowed, to
        // the files the current run also mutated.
        let currentScore = MutationScore.tally(report.results.map(\.outcome))
        let baselineScore = MutationScore.tally(baseline.results.filter { common.contains($0.point.file) }.map(\.outcome))

        let axes: [(label: String, value: KeyPath<MutationScore, Double?>)] = [
            ("Tested", \.tested),
            ("Effective", \.effective)
        ]

        if !currentFiles.isEmpty, !baselineFiles.isEmpty, common.isEmpty {
            return [QualityGateViolation(
                kind: .baselineIncompatible,
                detail: "Regression checks cannot be answered: current and baseline reports mutated no file in common."
            )]
        }

        return axes.flatMap { axis -> [QualityGateViolation] in
            let comparison: AxisComparison
            if let current = currentScore[keyPath: axis.value],
               let prior = baselineScore[keyPath: axis.value] {
                comparison = .comparable(current: current, prior: prior)
            } else {
                comparison = .unavailable("no denominator in the current report, the baseline, or both")
            }
            switch comparison {
            case let .unavailable(reason):
                return [QualityGateViolation(
                    kind: .regressionUnavailable,
                    detail: "\(axis.label) regression check cannot be answered: \(reason)."
                )]
            case let .comparable(current, prior):
                let drop = prior - current
                guard drop > maximumDrop else { return [] }
                return [QualityGateViolation(
                    kind: .scoreRegression,
                    detail: String(
                        format: "%@ Mutation Score dropped %.2f%% versus baseline (%.2f%% -> %.2f%%); configured maximum drop is %.2f%%.",
                        axis.label, drop * 100, prior * 100, current * 100, maximumDrop * 100
                    )
                )]
            }
        }
    }

    /// Survivors present now and absent from the baseline. Compared by
    /// `MutationID`, so a survivor that merely moved line does not read as new.
    ///
    /// Deliberately `MutationID` equality alone, not `PlannedMutationRef
    /// .pointDigest` (the authoritative verdict pipeline) — the stronger, untruncated content-binding
    /// layer that exists elsewhere for evidence-trust purposes. `MutationID`
    /// truncates to 64 bits, an accepted collision risk for a human-facing
    /// label (see `SchemataPlan.swift`'s own doc comment on that trade-off);
    /// a false ID collision here would, in principle, read a genuinely new
    /// survivor as "already known." This has no evidence of happening in
    /// practice and is not being treated as a live concern — noted so a
    /// future reader reasoning about this comparison's collision exposure
    /// does not have to rediscover the authoritative verdict pipeline from scratch.
    private static func newSurvivorViolations(
        report: RunReport,
        baseline: RunReport,
        maximum: Int
    ) -> [QualityGateViolation] {
        let baselineSurvivors = Set(baseline.results.filter { $0.outcome == .survived }.map(\.id))
        let newSurvivors = report.results
            .filter { $0.outcome == .survived }
            .filter { !baselineSurvivors.contains($0.id) }

        guard newSurvivors.count > maximum else { return [] }
        return [QualityGateViolation(
            kind: .newSurvivors,
            detail: "\(newSurvivors.count) new surviving mutant(s) not present in the baseline "
                + "(configured maximum is \(maximum)): "
                + newSurvivors.map(\.id.rawValue).sorted().joined(separator: ", ")
        )]
    }
}
