import Foundation

/// A broken invariant. Any of these means the run's numbers are not trustworthy.
public struct IntegrityViolation: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A mutant is in the report but never touched the source. The exact
        /// failure this tool exists to make impossible.
        case phantomMutant
        /// Counts do not reconcile across a pipeline stage.
        case countMismatch
        /// An ID in the plan does not recompute from its own components.
        case unstableMutationID
        /// The unmutated baseline did not behave as recorded.
        case baselineMismatch
        /// A mutant compiled to a binary identical to baseline: nothing was tested.
        case mutationNotActivated
        /// A result exists for a mutation that is not in the plan.
        case resultWithoutPlannedMutation
        /// A planned mutation has no result and no skip record.
        case plannedMutationWithoutResult
        /// Duplicate IDs — IDs must be unique within a plan.
        case duplicateMutationID
    }

    public let kind: Kind
    public let detail: String
    public let mutationID: MutationID?

    public init(kind: Kind, detail: String, mutationID: MutationID? = nil) {
        self.kind = kind
        self.detail = detail
        self.mutationID = mutationID
    }
}

/// How many skipped mutations trace back to a given reason. A flat count of
/// six-way-conflated reasons ("skipped: 840") cannot distinguish "budget cut
/// this run off deliberately" from "an operator was disabled" — one is
/// expected and load-bearing for a sampled run, the other is worth noticing.
public struct SkipReasonCount: Codable, Sendable, Hashable {
    public let reason: SkippedMutation.Reason
    public let count: Int

    public init(reason: SkippedMutation.Reason, count: Int) {
        self.reason = reason
        self.count = count
    }

    /// Tallies a plan's skipped mutations by reason, sorted for a
    /// deterministic report.
    public static func tally(_ skipped: [SkippedMutation]) -> [SkipReasonCount] {
        var counts: [SkippedMutation.Reason: Int] = [:]
        for skip in skipped { counts[skip.reason, default: 0] += 1 }
        return counts.keys.sorted { $0.rawValue < $1.rawValue }
            .map { SkipReasonCount(reason: $0, count: counts[$0]!) }
    }
}

/// The reconciliation of a run, and the gate on reporting a score.
public struct IntegrityReport: Codable, Sendable {
    public let discovered: Int
    public let planned: Int
    public let sourceApplied: Int
    public let buildObserved: Int
    public let buildFailures: Int
    public let executed: Int
    public let classified: Int
    public let reported: Int
    public let explicitlySkipped: Int
    /// `explicitlySkipped`, broken down by `SkippedMutation.Reason`. Sums to
    /// `explicitlySkipped`. Sorted by reason name so it renders and diffs
    /// deterministically.
    public let skippedByReason: [SkipReasonCount]
    public let violations: [IntegrityViolation]

    public var passed: Bool { violations.isEmpty }

    public init(
        discovered: Int,
        planned: Int,
        sourceApplied: Int,
        buildObserved: Int,
        buildFailures: Int,
        executed: Int,
        classified: Int,
        reported: Int,
        explicitlySkipped: Int,
        skippedByReason: [SkipReasonCount] = [],
        violations: [IntegrityViolation]
    ) {
        self.discovered = discovered
        self.planned = planned
        self.sourceApplied = sourceApplied
        self.buildObserved = buildObserved
        self.buildFailures = buildFailures
        self.executed = executed
        self.classified = classified
        self.reported = reported
        self.explicitlySkipped = explicitlySkipped
        self.skippedByReason = skippedByReason
        self.violations = violations
    }
}

/// Checks the design's invariants against a finished run.
///
/// This runs on every execution, not just in a debug mode. It is cheap, and it
/// is the only thing standing between a plausible-looking report and a wrong
/// one.
public enum IntegrityChecker {
    /// Verifies the plan is internally consistent before anything is executed.
    ///
    /// Catching an unstable ID here — rather than after an hour of builds — is
    /// the whole point of making IDs recomputable.
    public static func validatePlan(_ plan: MutationPlan) -> [IntegrityViolation] {
        var violations: [IntegrityViolation] = []

        var seen = Set<MutationID>()
        for point in plan.mutations {
            if !seen.insert(point.id).inserted {
                violations.append(IntegrityViolation(
                    kind: .duplicateMutationID,
                    detail: "\(point.id) appears more than once in the plan (\(point.displayLocation)).",
                    mutationID: point.id
                ))
            }

            let recomputed = point.recomputedID
            if recomputed != point.id {
                violations.append(IntegrityViolation(
                    kind: .unstableMutationID,
                    detail: """
                    \(point.displayLocation): plan declares \(point.id) but its own \
                    components recompute to \(recomputed).
                    """,
                    mutationID: point.id
                ))
            }
        }

        return violations
    }

    /// Reconciles a finished run against its plan.
    ///
    /// ADR-0006 Stage 1: narrowed to reconciliation only — counts,
    /// duplicates, and set-matching against the plan. The evidence-
    /// interpretation checks this function used to run itself
    /// (`phantomMutant`'s "does this result actually have a source diff",
    /// `mutationNotActivated`'s "does this scorable outcome actually have
    /// proven activation") are deleted, not weakened: `MutationVerdictVerifier`
    /// is now the *only* place a `VerifiedMutationRecord` is constructed,
    /// and its own logic already gates every scorable outcome on proven
    /// activation and every non-`.notApplied`/`.excluded` outcome on real
    /// evidence — those states are no longer constructible, so re-checking
    /// for them here would only ever find nothing, forever. That is the
    /// PR B / schemata-migration deferral this stage finally closes: it
    /// could not close before because `MutationResult`'s public initializer
    /// meant a corrupted or hand-built record could still reach this check
    /// without ever passing through the verifier. That initializer is gone.
    ///
    /// - Parameters:
    ///   - plan: the plan that was executed.
    ///   - ledger: one verified result per planned mutation. `MutationResult`
    ///     is a verified projection (see its own doc comment) and conforms
    ///     to `MutationLedgerEntry` directly via its own `mutationRef`, so
    ///     no separate `VerifiedMutationRecord` needs to be kept alive
    ///     alongside it just to populate the ledger. `ResultLedger.insert`
    ///     already refuses a duplicate key at insertion time, so there is
    ///     no duplicate-result case left for this function to detect.
    ///   - baselinePassed: whether the unmutated baseline behaved as recorded.
    public static func check(
        plan: MutationPlan,
        ledger: ResultLedger<MutationResult>,
        baselinePassed: Bool
    ) -> IntegrityReport {
        var violations = validatePlan(plan)

        if !baselinePassed {
            violations.append(IntegrityViolation(
                kind: .baselineMismatch,
                detail: "The unmutated baseline did not pass. No mutant outcome can be trusted against it."
            ))
        }

        // Not `Dictionary(uniqueKeysWithValues:)`: `violations` above may
        // already include `.duplicateMutationID`, and this dictionary must
        // not trap before that violation is actually returned to the
        // caller. Reconciliation degrades gracefully (first-seen point per
        // ID) — a plan with duplicates never produces a passing report
        // anyway, since the violation collected above always survives into
        // the returned `IntegrityReport`.
        var pointsByID: [MutationID: MutationPoint] = [:]
        for point in plan.mutations where pointsByID[point.id] == nil {
            pointsByID[point.id] = point
        }
        let plannedIDs = Set(pointsByID.keys)
        let resultIDs = Set(ledger.mutationIDs)

        // Invariant: reported ⊆ planned.
        for id in resultIDs.subtracting(plannedIDs).sorted() {
            violations.append(IntegrityViolation(
                kind: .resultWithoutPlannedMutation,
                detail: "Result \(id) has no corresponding mutation in the plan.",
                mutationID: id
            ))
        }

        // Invariant: planned = classified + skipped. A planned mutation that
        // silently vanished is exactly the failure mode we refuse to tolerate.
        for id in plannedIDs.subtracting(resultIDs).sorted() {
            violations.append(IntegrityViolation(
                kind: .plannedMutationWithoutResult,
                detail: "Planned mutation \(id) produced no result and no skip record.",
                mutationID: id
            ))
        }

        // `notApplied` is never silently absorbed: it is loud by
        // construction, even though it is otherwise a legitimate,
        // non-defect `.excluded` verdict.
        for result in ledger.entries where result.outcome == .notApplied {
            violations.append(IntegrityViolation(
                kind: .phantomMutant,
                detail: "\(result.point.displayLocation): source anchor did not match, so the mutation was never applied. \(result.diagnosis)",
                mutationID: result.id
            ))
        }

        let sourceApplied = ledger.entries.filter { $0.evidence?.provesSourceApplication == true }.count
        let buildFailures = ledger.entries.filter { $0.outcome == .unviable }.count
        let buildObserved = ledger.entries.filter { $0.evidence?.buildProductHash != nil }.count
        // Not `testSummary != nil` alone: a serial SwiftPM test run can reach a
        // real, test-execution-backed outcome without a per-test summary (see
        // `MutationOutcome.impliesTestWasExecuted`), which `testSummary` alone
        // would misreport as "never executed."
        let executed = ledger.entries.filter { $0.testSummary != nil || $0.outcome.impliesTestWasExecuted }.count
        let reported = ledger.entries.filter(isReportable).count

        return IntegrityReport(
            discovered: plan.discoveredCount,
            planned: plan.mutations.count,
            sourceApplied: sourceApplied,
            buildObserved: buildObserved,
            buildFailures: buildFailures,
            executed: executed,
            classified: ledger.count,
            reported: reported,
            explicitlySkipped: plan.skipped.count,
            skippedByReason: SkipReasonCount.tally(plan.skipped),
            violations: violations
        )
    }

    /// A result may only be reported if we can prove the mutation was
    /// applied. Outcomes that never touched the source (`.skipped`,
    /// `.notApplied`) are exempt because for them the absence of a diff
    /// *is* the honest record. Stats-only now (see `check`'s doc comment)
    /// — this can never be `false` for a scorable outcome, since the
    /// verifier only ever attaches real evidence to one.
    private static func isReportable(_ result: MutationResult) -> Bool {
        switch result.outcome {
        case .skipped, .notApplied:
            true
        default:
            result.evidence?.provesSourceApplication == true
        }
    }
}
