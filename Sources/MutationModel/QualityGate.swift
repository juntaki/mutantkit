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

public struct QualityGateViolation: Codable, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case testedScore
        case effectiveScore
        case survivorCount
        case scoreUnavailable
        case scoreRegression
        case newSurvivors
        case baselineUnavailable
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
                score: score,
                baseline: baseline,
                thresholds: thresholds
            )
        }

        return QualityGateResult(passed: violations.isEmpty, violations: violations)
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
        score: MutationScore,
        baseline: RunReport?,
        thresholds: QualityGateThresholds
    ) -> [QualityGateViolation] {
        guard let baseline, baseline.integrity.passed, let baselineScore = baseline.score else {
            return [QualityGateViolation(
                kind: .baselineUnavailable,
                detail: "regression/newSurvivors thresholds are configured but no trustworthy baseline report was provided."
            )]
        }

        var violations: [QualityGateViolation] = []

        if let maximumDrop = thresholds.regressionMaximumDrop {
            violations += regressionViolations(
                score: score, baselineScore: baselineScore, maximumDrop: maximumDrop
            )
        }

        if let maximum = thresholds.newSurvivorsMaximum {
            violations += newSurvivorViolations(report: report, baseline: baseline, maximum: maximum)
        }

        return violations
    }

    /// Both scores compared against their own counterpart in the baseline.
    /// Keyed by `KeyPath` rather than by pre-read pairs so the current and
    /// prior value being compared are the same axis by construction, not by a
    /// caller remembering to line them up.
    private static func regressionViolations(
        score: MutationScore,
        baselineScore: MutationScore,
        maximumDrop: Double
    ) -> [QualityGateViolation] {
        let axes: [(label: String, value: KeyPath<MutationScore, Double?>)] = [
            ("Tested", \.tested),
            ("Effective", \.effective)
        ]

        return axes.compactMap { axis in
            // A missing denominator on either side is "cannot compare", not a
            // drop of zero — the absolute-threshold checks above already
            // report an unusable current score, and inventing a regression
            // verdict here from a number that does not exist is exactly the
            // false-failure this gate must not manufacture.
            guard let current = score[keyPath: axis.value],
                  let prior = baselineScore[keyPath: axis.value] else { return nil }
            let drop = prior - current
            guard drop > maximumDrop else { return nil }
            return QualityGateViolation(
                kind: .scoreRegression,
                detail: String(
                    format: "%@ Mutation Score dropped %.2f%% versus baseline (%.2f%% -> %.2f%%); configured maximum drop is %.2f%%.",
                    axis.label, drop * 100, prior * 100, current * 100, maximumDrop * 100
                )
            )
        }
    }

    /// Survivors present now and absent from the baseline. Compared by
    /// `MutationID`, so a survivor that merely moved line does not read as new.
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
