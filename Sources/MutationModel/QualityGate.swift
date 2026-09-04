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
    // swift-complexity:disable cognitive - known debt, also SwiftLint-baselined (complexity 16); split when touched
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

        var violations: [QualityGateViolation] = []

        if let minimum = thresholds.minimumTested {
            if let actual = score.tested {
                if actual < minimum {
                    violations.append(QualityGateViolation(
                        kind: .testedScore,
                        detail: String(
                            format: "Tested Mutation Score %.2f%% is below the required %.2f%%.",
                            actual * 100,
                            minimum * 100
                        )
                    ))
                }
            } else {
                violations.append(QualityGateViolation(
                    kind: .scoreUnavailable,
                    detail: "Tested Mutation Score has no denominator and cannot satisfy a configured threshold."
                ))
            }
        }

        if let minimum = thresholds.minimumEffective {
            if let actual = score.effective {
                if actual < minimum {
                    violations.append(QualityGateViolation(
                        kind: .effectiveScore,
                        detail: String(
                            format: "Effective Mutation Score %.2f%% is below the required %.2f%%.",
                            actual * 100,
                            minimum * 100
                        )
                    ))
                }
            } else {
                violations.append(QualityGateViolation(
                    kind: .scoreUnavailable,
                    detail: "Effective Mutation Score has no denominator and cannot satisfy a configured threshold."
                ))
            }
        }

        if let maximum = thresholds.maximumSurvivors, score.survived > maximum {
            violations.append(QualityGateViolation(
                kind: .survivorCount,
                detail: "\(score.survived) mutant(s) survived; configured maximum is \(maximum)."
            ))
        }

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

        if let maximumDrop = thresholds.regressionMaximumDrop {
            for (label, kindDetail) in [
                ("Tested", (current: score.tested, prior: baselineScore.tested)),
                ("Effective", (current: score.effective, prior: baselineScore.effective))
            ] {
                if let current = kindDetail.current, let prior = kindDetail.prior {
                    let drop = prior - current
                    if drop > maximumDrop {
                        violations.append(QualityGateViolation(
                            kind: .scoreRegression,
                            detail: String(
                                format: "%@ Mutation Score dropped %.2f%% versus baseline (%.2f%% -> %.2f%%); configured maximum drop is %.2f%%.",
                                label, drop * 100, prior * 100, current * 100, maximumDrop * 100
                            )
                        ))
                    }
                }
            }
        }

        if let maximum = thresholds.newSurvivorsMaximum {
            let baselineSurvivors = Set(baseline.results.filter { $0.outcome == .survived }.map(\.id))
            let currentSurvivors = report.results.filter { $0.outcome == .survived }
            let newSurvivors = currentSurvivors.filter { !baselineSurvivors.contains($0.id) }
            if newSurvivors.count > maximum {
                violations.append(QualityGateViolation(
                    kind: .newSurvivors,
                    detail: "\(newSurvivors.count) new surviving mutant(s) not present in the baseline "
                        + "(configured maximum is \(maximum)): "
                        + newSurvivors.map(\.id.rawValue).sorted().joined(separator: ", ")
                ))
            }
        }

        return QualityGateResult(passed: violations.isEmpty, violations: violations)
    }
}
