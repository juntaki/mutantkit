import Foundation

/// How much a `BenchmarkCostEstimate` should be trusted — always
/// `lowerBound` today: it is built from exactly one calibration run
/// (Stage 1, `swift-numerics`/`GCD.swift`) and does not model per-project
/// source complexity, toolchain variance, or CI-runner noise. Exists so a
/// consumer of the estimate can never mistake it for a measured value.
public enum EstimateConfidence: String, Codable, Sendable {
    case lowerBound
}

/// A pre-dispatch cost estimate — computed from a real candidate count
/// (MutantKit's own `plan` step, run before any mutation execution starts)
/// and one real per-mutant cost observed in a prior calibration run, never
/// from a static formula invented without measurement. Muter's own
/// candidate count is not knowable ahead of a real run (Muter has no
/// discovery-only mode separate from `run`), so `muterCandidates` and
/// `estimatedMuterSeconds` stay `nil` unless a caller supplies a real
/// count from a prior run of the same scope — never guessed.
public struct BenchmarkCostEstimate: Codable, Sendable {
    public let projectID: String
    public let sourceScope: [String]
    public let mutantKitCandidates: Int?
    public let muterCandidates: Int?
    public let estimatedSetupSeconds: Double
    public let estimatedMutantKitSeconds: Double?
    public let estimatedMuterSeconds: Double?
    public let estimatedTotalSeconds: Double?
    public let confidence: EstimateConfidence

    public init(
        projectID: String, sourceScope: [String], mutantKitCandidates: Int?, muterCandidates: Int?,
        estimatedSetupSeconds: Double, estimatedMutantKitSeconds: Double?, estimatedMuterSeconds: Double?,
        confidence: EstimateConfidence = .lowerBound
    ) {
        self.projectID = projectID
        self.sourceScope = sourceScope
        self.mutantKitCandidates = mutantKitCandidates
        self.muterCandidates = muterCandidates
        self.estimatedSetupSeconds = estimatedSetupSeconds
        self.estimatedMutantKitSeconds = estimatedMutantKitSeconds
        self.estimatedMuterSeconds = estimatedMuterSeconds
        estimatedTotalSeconds = [estimatedMutantKitSeconds, estimatedMuterSeconds].compactMap { $0 }
            .reduce(estimatedSetupSeconds, +)
        self.confidence = confidence
    }
}

/// Reference per-mutant costs observed in the Stage 1 calibration run
/// (Benchmarks/results/compatibility/xcode-15.2-swift-5.9-macos-14/
/// stage1-calibration/baseline.json, run 31023117878) — the only real
/// measurement this benchmark has today. `secondsPerCandidate` is the
/// isolated-mode, one-repetition, GCD.swift-scope figure; a real project
/// with different source complexity will differ, which is exactly why
/// `EstimateConfidence` is always `.lowerBound`.
public enum BenchmarkCostModel {
    /// (85.9 + 92.4) / 6 mutants, incremental mode, Stage 1 baseline.
    public static let mutantKitSecondsPerCandidate = 29.72
    /// A representative baseline build+test cost from Stage 1 (warm mode,
    /// the cheapest of the three observed).
    public static let mutantKitBaselineSeconds = 32.5
    /// 92.2 / 3 mutants, cold mode, Stage 1 baseline — Muter's own
    /// candidate count for a NEW scope is not known ahead of a real run,
    /// so this is only usable when a caller already has a real count from
    /// a prior run of that exact scope.
    public static let muterSecondsPerCandidate = 30.7
    /// Observed fixed per-job setup cost (checkout, both toolchain builds,
    /// Muter clone+build) across Stage 1's real runs.
    public static let fixedSetupSeconds = 960.0

    public static func estimate(
        projectID: String, sourceScope: [String], mutantKitCandidates: Int?, muterCandidates: Int? = nil
    ) -> BenchmarkCostEstimate {
        let mutantKitSeconds = mutantKitCandidates.map { mutantKitBaselineSeconds + Double($0) * mutantKitSecondsPerCandidate }
        let muterSeconds = muterCandidates.map { Double($0) * muterSecondsPerCandidate }
        return BenchmarkCostEstimate(
            projectID: projectID, sourceScope: sourceScope, mutantKitCandidates: mutantKitCandidates,
            muterCandidates: muterCandidates, estimatedSetupSeconds: fixedSetupSeconds,
            estimatedMutantKitSeconds: mutantKitSeconds, estimatedMuterSeconds: muterSeconds
        )
    }
}

public enum BenchmarkBudgetError: Error, CustomStringConvertible {
    case estimateExceedsBudget(estimate: BenchmarkCostEstimate, maxMinutes: Double)
    case candidateCountExceedsBudget(candidates: Int, maxCandidates: Int, tool: String)

    public var description: String {
        switch self {
        case let .estimateExceedsBudget(estimate, maxMinutes):
            let totalMinutes = (estimate.estimatedTotalSeconds ?? .infinity) / 60
            return "estimated total \(String(format: "%.1f", totalMinutes)) min exceeds the budget of \(maxMinutes) min "
                + "for project \(estimate.projectID) (lower-bound estimate, based on one prior calibration run)"
        case let .candidateCountExceedsBudget(candidates, maxCandidates, tool):
            return "\(tool) candidate count \(candidates) exceeds the budget of \(maxCandidates)"
        }
    }
}

/// Fails closed before any mutation run starts — never after the fact.
/// `allowOverride` must be explicit (never a silent default) to bypass
/// either check.
public enum BenchmarkBudgetGuard {
    public static func requireWithinBudget(
        _ estimate: BenchmarkCostEstimate, maxEstimatedMinutes: Double?, maxMutantKitCandidates: Int?,
        maxMuterCandidates: Int?, allowOverride: Bool = false
    ) throws {
        guard !allowOverride else { return }

        if let maxEstimatedMinutes, let totalSeconds = estimate.estimatedTotalSeconds,
           totalSeconds / 60 > maxEstimatedMinutes {
            throw BenchmarkBudgetError.estimateExceedsBudget(estimate: estimate, maxMinutes: maxEstimatedMinutes)
        }
        if let maxMutantKitCandidates, let candidates = estimate.mutantKitCandidates, candidates > maxMutantKitCandidates {
            throw BenchmarkBudgetError.candidateCountExceedsBudget(
                candidates: candidates, maxCandidates: maxMutantKitCandidates, tool: "mutantkit"
            )
        }
        if let maxMuterCandidates, let candidates = estimate.muterCandidates, candidates > maxMuterCandidates {
            throw BenchmarkBudgetError.candidateCountExceedsBudget(
                candidates: candidates, maxCandidates: maxMuterCandidates, tool: "muter"
            )
        }
    }
}
