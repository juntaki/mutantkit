/// A strict check for runs whose purpose is to *measure* schemata mode (operator qualification,
/// acceptance tests), as opposed to using it.
///
/// For an ordinary user, schemata mode falls back to isolated execution whenever it cannot prove a
/// result, and that is correct: the verdicts stay right, only the speed-up is lost. For a
/// measurement it is a trap. A run that requested schemata but silently executed everything
/// isolated exits 0, looks healthy, and an isolated-vs-schemata comparison of it compares
/// isolated with isolated. Qualification mode turns that into a failure.
public struct SchemataQualification: Sendable, Equatable {
    /// Fallbacks tolerated before the run is invalid. Zero by default: a qualification run uses
    /// operators and corpora chosen so that schemata applies.
    public let maximumUnexpectedFallbacks: Int

    public init(maximumUnexpectedFallbacks: Int = 0) {
        self.maximumUnexpectedFallbacks = maximumUnexpectedFallbacks
    }

    /// Dynamic fallback reasons that mean the schemata machinery itself failed, as opposed to a
    /// mutation that legitimately was not reached. They are never tolerated, whatever
    /// `maximumUnexpectedFallbacks` says.
    public static let infrastructureFallbackReasons: [String] = ["buildReceiptUnavailable", "sharedChunkBuildFailure"]

    /// Why the run is not a valid schemata measurement. Empty means valid.
    public func violations(in report: RunReport) -> [String] {
        guard let strategy = report.executionStrategy, strategy.requested == .schemata else {
            return ["the run did not request schemata execution (execution.strategy is not schemata)"]
        }
        var problems: [String] = []
        if let degradation = strategy.degradationReason {
            problems.append("the whole run degraded to isolated execution: \(degradation)")
        }
        if strategy.effectiveCount <= 0 {
            problems.append("no mutation was executed through schemata (effective count \(strategy.effectiveCount))")
        }
        let schemataVerified = report.results.filter { result in
            if case .schemata? = result.evidence?.applicationEvidence { return true }
            return false
        }.count
        if schemataVerified == 0 {
            problems.append("no result carries schemata-verified activation evidence")
        }
        for reason in Self.infrastructureFallbackReasons {
            let count = strategy.fallbackReasonCounts?[reason] ?? 0
            if count > 0 { problems.append("\(count) mutation(s) fell back for \(reason)") }
        }
        if strategy.fallbackCount > maximumUnexpectedFallbacks {
            problems.append(
                "\(strategy.fallbackCount) mutation(s) fell back to isolated execution; at most \(maximumUnexpectedFallbacks) allowed"
            )
        }
        return problems
    }
}
