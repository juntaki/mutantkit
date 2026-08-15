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
    public let passed: Bool
    public let violations: [QualityGateViolation]

    public init(passed: Bool, violations: [QualityGateViolation]) {
        self.passed = passed
        self.violations = violations
    }
}

public enum QualityGate {
    /// Evaluates thresholds only against a trustworthy score. If integrity
    /// failed and no score exists, the gate fails closed rather than treating
    /// the missing number as zero or silently passing CI.
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

        var violations = absoluteThresholdViolations(score: score, thresholds: thresholds)

        let needsBaseline = thresholds.regressionMaximumDrop != nil || thresholds.newSurvivorsMaximum != nil
        guard needsBaseline else {
            return QualityGateResult(passed: violations.isEmpty, violations: violations)
        }

        guard let baseline, baseline.integrity.passed, let baselineScore = baseline.score else {
            violations.append(QualityGateViolation(
                kind: .baselineUnavailable,
                detail: "regression/newSurvivors thresholds are configured but no trustworthy baseline report was provided."
            ))
            return QualityGateResult(passed: violations.isEmpty, violations: violations)
        }

        violations.append(contentsOf: regressionViolations(
            score: score,
            baselineScore: baselineScore,
            thresholds: thresholds
        ))
        if let violation = newSurvivorsViolation(report: report, baseline: baseline, thresholds: thresholds) {
            violations.append(violation)
        }

        return QualityGateResult(passed: violations.isEmpty, violations: violations)
    }

    /// Evaluates the threshold checks that only need the current run's score
    /// (no baseline required): minimum Tested/Effective score and maximum
    /// survivor count.
    private static func absoluteThresholdViolations(
        score: MutationScore,
        thresholds: QualityGateThresholds
    ) -> [QualityGateViolation] {
        var violations: [QualityGateViolation] = []
        if let violation = scoreThresholdViolation(
            actual: score.tested,
            minimum: thresholds.minimumTested,
            kind: .testedScore,
            label: "Tested"
        ) {
            violations.append(violation)
        }
        if let violation = scoreThresholdViolation(
            actual: score.effective,
            minimum: thresholds.minimumEffective,
            kind: .effectiveScore,
            label: "Effective"
        ) {
            violations.append(violation)
        }
        if let maximum = thresholds.maximumSurvivors, score.survived > maximum {
            violations.append(QualityGateViolation(
                kind: .survivorCount,
                detail: "\(score.survived) mutant(s) survived; configured maximum is \(maximum)."
            ))
        }
        return violations
    }

    /// Shared implementation for the minimum-Tested and minimum-Effective
    /// score checks, which differ only in which score to read and which
    /// `QualityGateViolation.Kind` to report.
    private static func scoreThresholdViolation(
        actual: Double?,
        minimum: Double?,
        kind: QualityGateViolation.Kind,
        label: String
    ) -> QualityGateViolation? {
        guard let minimum else { return nil }
        guard let actual else {
            return QualityGateViolation(
                kind: .scoreUnavailable,
                detail: "\(label) Mutation Score has no denominator and cannot satisfy a configured threshold."
            )
        }
        guard actual < minimum else { return nil }
        return QualityGateViolation(
            kind: kind,
            detail: String(
                format: "\(label) Mutation Score %.2f%% is below the required %.2f%%.",
                actual * 100,
                minimum * 100
            )
        )
    }

    /// Evaluates the score-regression-versus-baseline check for both the
    /// Tested and Effective scores.
    private static func regressionViolations(
        score: MutationScore,
        baselineScore: MutationScore,
        thresholds: QualityGateThresholds
    ) -> [QualityGateViolation] {
        guard let maximumDrop = thresholds.regressionMaximumDrop else { return [] }

        var violations: [QualityGateViolation] = []
        if let violation = regressionViolation(
            label: "Tested",
            current: score.tested,
            prior: baselineScore.tested,
            maximumDrop: maximumDrop
        ) {
            violations.append(violation)
        }
        if let violation = regressionViolation(
            label: "Effective",
            current: score.effective,
            prior: baselineScore.effective,
            maximumDrop: maximumDrop
        ) {
            violations.append(violation)
        }
        return violations
    }

    /// Checks a single score's drop against `maximumDrop`, shared by the
    /// Tested and Effective regression checks above.
    private static func regressionViolation(
        label: String,
        current: Double?,
        prior: Double?,
        maximumDrop: Double
    ) -> QualityGateViolation? {
        guard let current, let prior else { return nil }
        let drop = prior - current
        guard drop > maximumDrop else { return nil }
        return QualityGateViolation(
            kind: .scoreRegression,
            detail: regressionDetail(label: label, drop: drop, prior: prior, current: current, maximumDrop: maximumDrop)
        )
    }

    private static func regressionDetail(
        label: String,
        drop: Double,
        prior: Double,
        current: Double,
        maximumDrop: Double
    ) -> String {
        String(
            format: "%@ Mutation Score dropped %.2f%% versus baseline (%.2f%% -> %.2f%%); "
                + "configured maximum drop is %.2f%%.",
            label, drop * 100, prior * 100, current * 100, maximumDrop * 100
        )
    }

    /// Evaluates the new-survivors-versus-baseline check.
    private static func newSurvivorsViolation(
        report: RunReport,
        baseline: RunReport,
        thresholds: QualityGateThresholds
    ) -> QualityGateViolation? {
        guard let maximum = thresholds.newSurvivorsMaximum else { return nil }
        let baselineSurvivors = Set(baseline.results.filter { $0.outcome == .survived }.map(\.id))
        let currentSurvivors = report.results.filter { $0.outcome == .survived }
        let newSurvivors = currentSurvivors.filter { !baselineSurvivors.contains($0.id) }
        guard newSurvivors.count > maximum else { return nil }
        return QualityGateViolation(
            kind: .newSurvivors,
            detail: "\(newSurvivors.count) new surviving mutant(s) not present in the baseline "
                + "(configured maximum is \(maximum)): "
                + newSurvivors.map(\.id.rawValue).sorted().joined(separator: ", ")
        )
    }
}
