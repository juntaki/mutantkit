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

    public init(
        minimumTested: Double? = nil,
        minimumEffective: Double? = nil,
        maximumSurvivors: Int? = nil
    ) {
        self.minimumTested = minimumTested
        self.minimumEffective = minimumEffective
        self.maximumSurvivors = maximumSurvivors
    }
}

public struct QualityGateViolation: Codable, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case testedScore
        case effectiveScore
        case survivorCount
        case scoreUnavailable
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
        thresholds: QualityGateThresholds
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

        return QualityGateResult(passed: violations.isEmpty, violations: violations)
    }
}
