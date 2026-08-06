import Foundation

/// One project's aggregated measurements — the medians across its repeated
/// runs, per mode, plus whatever correctness checks ran against its
/// MutantKit output.
public struct AggregateProjectResult: Sendable {
    public let projectID: String
    public let mutantKitMeasurements: [BenchmarkMode: MutationBenchmarkMeasurement]
    public let muterMeasurements: [BenchmarkMode: MutationBenchmarkMeasurement]
    public let comparison: CrossToolComparison?
    /// `false` whenever `MutantKitCorrectnessValidator` found a
    /// discrepancy between the report's own claimed counts and what the
    /// report actually contains — independent of whether `report.integrity
    /// .passed` itself was `true`, since that flag is exactly one of the
    /// things being cross-checked, not trusted at face value.
    public let mutantKitCorrectnessPassed: Bool

    public init(
        projectID: String, mutantKitMeasurements: [BenchmarkMode: MutationBenchmarkMeasurement],
        muterMeasurements: [BenchmarkMode: MutationBenchmarkMeasurement], comparison: CrossToolComparison?,
        mutantKitCorrectnessPassed: Bool
    ) {
        self.projectID = projectID
        self.mutantKitMeasurements = mutantKitMeasurements
        self.muterMeasurements = muterMeasurements
        self.comparison = comparison
        self.mutantKitCorrectnessPassed = mutantKitCorrectnessPassed
    }
}

public struct AggregateBenchmarkResult: Sendable {
    public let projects: [AggregateProjectResult]

    public init(projects: [AggregateProjectResult]) {
        self.projects = projects
    }
}

public struct BenchmarkViolation: Sendable, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// MutantKit's own correctness bar for this benchmark — checked
/// independently of, and prioritized over, every speed/resource
/// comparison against Muter. A fast wrong answer is worse than a slow
/// right one; this gate exists to make sure the benchmark itself never
/// reports a speed win earned by an incorrect result.
public struct BenchmarkGate: Sendable {
    public let maximumMutantKitPhantoms: Int
    public let maximumMutantKitFalseScored: Int
    public let maximumBackendDisagreements: Int
    public let minimumDefaultOperatorCompileRate: Double

    public init(
        maximumMutantKitPhantoms: Int = 0, maximumMutantKitFalseScored: Int = 0,
        maximumBackendDisagreements: Int = 0, minimumDefaultOperatorCompileRate: Double = 0.99
    ) {
        self.maximumMutantKitPhantoms = maximumMutantKitPhantoms
        self.maximumMutantKitFalseScored = maximumMutantKitFalseScored
        self.maximumBackendDisagreements = maximumBackendDisagreements
        self.minimumDefaultOperatorCompileRate = minimumDefaultOperatorCompileRate
    }

    public func evaluate(_ aggregate: AggregateBenchmarkResult) -> [BenchmarkViolation] {
        var violations: [BenchmarkViolation] = []

        for project in aggregate.projects {
            if !project.mutantKitCorrectnessPassed {
                violations.append(BenchmarkViolation("\(project.projectID): MutantKit correctness validation failed"))
            }
            for (mode, measurement) in project.mutantKitMeasurements.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let phantoms = measurement.phantom, phantoms > maximumMutantKitPhantoms {
                    violations.append(BenchmarkViolation("\(project.projectID)/\(mode.rawValue): \(phantoms) phantom mutant(s), max allowed \(maximumMutantKitPhantoms)"))
                }
                if let falseScored = measurement.falseScored, falseScored > maximumMutantKitFalseScored {
                    violations.append(BenchmarkViolation("\(project.projectID)/\(mode.rawValue): \(falseScored) false-scored mutant(s), max allowed \(maximumMutantKitFalseScored)"))
                }
                if let disagreements = measurement.backendDisagreements, disagreements > maximumBackendDisagreements {
                    violations.append(BenchmarkViolation("\(project.projectID)/\(mode.rawValue): \(disagreements) backend disagreement(s), max allowed \(maximumBackendDisagreements)"))
                }
                if let built = measurement.built, measurement.applied ?? 0 > 0 {
                    let compileRate = Double(built) / Double(measurement.applied ?? 1)
                    if compileRate < minimumDefaultOperatorCompileRate {
                        violations.append(BenchmarkViolation(
                            "\(project.projectID)/\(mode.rawValue): compile rate \(String(format: "%.3f", compileRate)) below minimum \(minimumDefaultOperatorCompileRate)"
                        ))
                    }
                }
            }
        }
        return violations
    }
}
