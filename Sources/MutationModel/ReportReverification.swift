import Foundation

/// One re-verification result for a finished report: what was checked, whether
/// it held, and which mutations (if any) it concerns.
///
/// `notVerifiable` is a first-class state, never a pass: it means the
/// report alone cannot prove or refute the claim (the observations that
/// decided the verdict are not stored in it). It is reported as such and never
/// counted towards "verified".
public struct ReverificationCheck: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case pass
        case fail
        case notVerifiable
    }

    public let name: String
    public let status: Status
    public let detail: String
    /// The mutation IDs this check concerns; empty for a whole-report check.
    public let mutationIDs: [String]

    public init(name: String, status: Status, detail: String, mutationIDs: [String] = []) {
        self.name = name
        self.status = status
        self.detail = detail
        self.mutationIDs = mutationIDs
    }
}

/// The outcome of re-verifying a report from what it contains.
public struct ReportReverification: Codable, Sendable {
    public let checks: [ReverificationCheck]
    /// Present only when an evidence archive was read and at least one result
    /// was re-judged from its raw observations (Tier B).
    public let tierB: TierBSummary?

    public init(checks: [ReverificationCheck], tierB: TierBSummary? = nil) {
        self.checks = checks
        self.tierB = tierB
    }

    /// Whether any result was re-verified from raw observations rather than
    /// only from what the report stores.
    public var tierBPerformed: Bool { tierB != nil }

    public var failureCount: Int { checks.filter { $0.status == .fail }.count }
    public var notVerifiableCount: Int { checks.filter { $0.status == .notVerifiable }.count }
    public var passCount: Int { checks.filter { $0.status == .pass }.count }

    /// `true` only when no check failed. A `notVerifiable` check does not make
    /// this `false` (the report simply cannot say), and it is never counted
    /// as a pass either: see `passCount`.
    public var passed: Bool { failureCount == 0 }

    /// `true` only when every check passed: none failed and none is
    /// `notVerifiable`. `passed` alone says "no mismatch found"; a report with
    /// any not-verifiable check is PARTIAL (`passed && !complete`) and must
    /// never be read as fully verified.
    public var complete: Bool { failureCount == 0 && notVerifiableCount == 0 }
}

/// Re-derives, from a decoded `RunReport` (and optionally its plan), every
/// claim that is a pure function of the fields the report actually stores.
///
/// This is a consistency check, not a second verdict authority:
/// `MutationVerdictVerifier` still decides verdicts from raw observations,
/// which a report does not carry. Everything here compares stored facts with
/// each other, or recomputes a value through the one existing implementation
/// (`IntegrityChecker`, `MutationScore.tally`, `ActivationEvidence
/// .provesActivation`, `MutationEvidence.provesSourceApplication`). It proves
/// internal consistency and re-derivability, not authenticity.
public enum ReportReverifier {
    struct Finding {
        let name: String
        let status: ReverificationCheck.Status
        let mutationID: String
        let reason: String
    }

    /// Runs every report-level check. `plan` is optional: without it the
    /// checks that need it are reported `notVerifiable`.
    public static func reverify(report: RunReport, plan: MutationPlan?) -> ReportReverification {
        reverify(report: report, plan: plan, evidence: nil)
    }

    /// As `reverify(report:plan:)`, and, when `evidence` is supplied, also
    /// re-runs the verifier over the archived raw observations (Tier B).
    /// Without it Tier A is exactly what it was.
    ///
    /// `expectedPolicy` is the confirmation policy derived independently of the
    /// archive (from the project configuration the plan's hash binds); without
    /// it Tier B's policy is the archive's own and is reported as such.
    public static func reverify(
        report: RunReport, plan: MutationPlan?, evidence: LoadedEvidenceArchive?,
        expectedPolicy: MutationVerdictVerifier.VerdictVerificationPolicy? = nil
    ) -> ReportReverification {
        var checks: [ReverificationCheck] = []

        checks.append(resultCountCheck(report))
        checks.append(contentsOf: planChecks(report: report, plan: plan))
        checks.append(contentsOf: resultChecks(report: report, plan: plan))
        checks.append(integrityCheck(report: report, plan: plan))
        checks.append(scoreCheck(report))
        let tierB = tierBChecks(report: report, evidence: evidence, expectedPolicy: expectedPolicy)
        checks.append(contentsOf: tierB.checks)
        return ReportReverification(checks: checks, tierB: tierB.summary)
    }

    // MARK: - Whole-report checks

    private static func resultCountCheck(_ report: RunReport) -> ReverificationCheck {
        if report.results.isEmpty {
            return ReverificationCheck(
                name: "report.results", status: .fail,
                detail: "The report contains no results; zero verified work is not a pass."
            )
        }
        return ReverificationCheck(
            name: "report.results", status: .pass, detail: "\(report.results.count) result(s) present."
        )
    }

    private static func planChecks(report: RunReport, plan: MutationPlan?) -> [ReverificationCheck] {
        guard let plan else {
            return [
                ReverificationCheck(
                    name: "plan.identity", status: .notVerifiable,
                    detail: "No plan was supplied, so the report's planID cannot be matched to a plan."
                ),
                ReverificationCheck(
                    name: "plan.mutationIDs", status: .notVerifiable,
                    detail: "No plan was supplied; only the IDs of mutations stored in the report were recomputed (see result.identity)."
                )
            ]
        }

        var checks: [ReverificationCheck] = []
        if report.planID == plan.planID {
            checks.append(ReverificationCheck(
                name: "plan.identity", status: .pass, detail: "planID \(plan.planID) matches the supplied plan."
            ))
        } else {
            checks.append(ReverificationCheck(
                name: "plan.identity", status: .fail,
                detail: "The report's planID is \(report.planID) but the supplied plan's is \(plan.planID)."
            ))
        }

        let violations = IntegrityChecker.validatePlan(plan)
        if violations.isEmpty {
            checks.append(ReverificationCheck(
                name: "plan.mutationIDs", status: .pass,
                detail: "Every planned mutation ID recomputes from its own components (\(plan.mutations.count) checked)."
            ))
        } else {
            checks.append(ReverificationCheck(
                name: "plan.mutationIDs", status: .fail,
                detail: violations.map(\.detail).joined(separator: " "),
                mutationIDs: violations.compactMap { $0.mutationID?.rawValue }
            ))
        }
        return checks
    }

    private static func integrityCheck(report: RunReport, plan: MutationPlan?) -> ReverificationCheck {
        guard let plan else {
            return ReverificationCheck(
                name: "integrity.recompute", status: .notVerifiable,
                detail: "Reconciliation against the plan needs the plan, and none was supplied."
            )
        }

        var ledger = ResultLedger<MutationResult>()
        for result in report.results {
            do {
                try ledger.insert(result)
            } catch {
                return ReverificationCheck(
                    name: "integrity.recompute", status: .fail,
                    detail: "The report's results do not form a valid ledger: \(error)", mutationIDs: [result.id.rawValue]
                )
            }
        }

        let recomputed = IntegrityChecker.check(plan: plan, ledger: ledger, baselinePassed: report.baseline.passed)
        let differences = integrityDifferences(stored: report.integrity, recomputed: recomputed)
        if differences.isEmpty {
            return ReverificationCheck(
                name: "integrity.recompute", status: .pass,
                detail: "Recomputed integrity equals the stored integrity (\(recomputed.violations.count) violation(s))."
            )
        }
        return ReverificationCheck(
            name: "integrity.recompute", status: .fail,
            detail: "Stored integrity differs from the recomputed one: " + differences.joined(separator: "; ") + "."
        )
    }

    private static func integrityDifferences(stored: IntegrityReport, recomputed: IntegrityReport) -> [String] {
        var differences: [String] = []
        func compare(_ name: String, _ lhs: Int, _ rhs: Int) {
            if lhs != rhs { differences.append("\(name) stored \(lhs), recomputed \(rhs)") }
        }
        compare("discovered", stored.discovered, recomputed.discovered)
        compare("planned", stored.planned, recomputed.planned)
        compare("sourceApplied", stored.sourceApplied, recomputed.sourceApplied)
        compare("buildObserved", stored.buildObserved, recomputed.buildObserved)
        compare("buildFailures", stored.buildFailures, recomputed.buildFailures)
        compare("executed", stored.executed, recomputed.executed)
        compare("classified", stored.classified, recomputed.classified)
        compare("reported", stored.reported, recomputed.reported)
        compare("explicitlySkipped", stored.explicitlySkipped, recomputed.explicitlySkipped)
        if stored.skippedByReason != recomputed.skippedByReason {
            differences.append("skippedByReason differs")
        }
        if Set(stored.violations) != Set(recomputed.violations) || stored.violations.count != recomputed.violations.count {
            differences.append("violations stored \(stored.violations.count), recomputed \(recomputed.violations.count)")
        }
        return differences
    }

    private static func scoreCheck(_ report: RunReport) -> ReverificationCheck {
        let recomputed = MutationScore.tally(report.results.map(\.outcome))
        switch (report.score, report.integrity.passed) {
        case let (stored?, true):
            if stored == recomputed {
                return ReverificationCheck(
                    name: "score.recompute", status: .pass,
                    detail: """
                    Stored score equals MutationScore.tally over the stored outcomes (\(recomputed.killed) killed, \
                    \(recomputed.survived) survived, \(recomputed.noCoverage) no coverage).
                    """
                )
            }
            return ReverificationCheck(
                name: "score.recompute", status: .fail,
                detail: """
                Stored score (\(stored.killed) killed, \(stored.survived) survived, \(stored.noCoverage) no coverage) \
                differs from the recomputed one (\(recomputed.killed), \(recomputed.survived), \(recomputed.noCoverage)).
                """
            )
        case (_?, false):
            return ReverificationCheck(
                name: "score.recompute", status: .fail,
                detail: "The report states a score although its integrity did not pass; a score may only exist when integrity passed."
            )
        case (nil, false):
            return ReverificationCheck(
                name: "score.recompute", status: .pass,
                detail: "No score is stored and the stored integrity did not pass, so withholding the score is expected."
            )
        case (nil, true):
            return ReverificationCheck(
                name: "score.recompute", status: .notVerifiable,
                detail: "The report stores no score although its integrity passed; there is nothing to compare."
            )
        }
    }
}

// MARK: - Per-result checks

extension ReportReverifier {
    private static func resultChecks(report: RunReport, plan: MutationPlan?) -> [ReverificationCheck] {
        let planDigests: [MutationID: String]? = plan.map { plan in
            Dictionary(plan.mutations.map { ($0.id, PlannedMutationRef.pointDigest(for: $0)) }, uniquingKeysWith: { first, _ in first })
        }

        var findings: [Finding] = []
        for result in report.results {
            findings += identityFindings(result, report: report, planDigests: planDigests)
            findings += provenanceFindings(result)
            findings += sourceApplicationFindings(result)
            findings += activationFindings(result)
            findings += buildProductFindings(result, baselineHash: report.baseline.buildProductHash)
            findings += sourceDiffFindings(result)
            findings += confirmationFindings(result)
            findings += killEvidenceFindings(result)
        }
        return aggregate(findings)
    }

    private static func identityFindings(
        _ result: MutationResult, report: RunReport, planDigests: [MutationID: String]?
    ) -> [Finding] {
        let id = result.id.rawValue
        let name = "result.identity"
        if result.point.recomputedID != result.point.id {
            return [Finding(name: name, status: .fail, mutationID: id, reason: "its ID does not recompute from its own components")]
        }
        if result.mutationRef.mutationID != result.point.id {
            return [Finding(name: name, status: .fail, mutationID: id, reason: "its mutationRef names a different mutation")]
        }
        if result.mutationRef.pointDigest != PlannedMutationRef.pointDigest(for: result.point) {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "its point content does not match the digest in its mutationRef"
            )]
        }
        if let planDigests {
            guard let planned = planDigests[result.id] else {
                return [Finding(name: name, status: .fail, mutationID: id, reason: "it is not in the supplied plan")]
            }
            if planned != PlannedMutationRef.pointDigest(for: result.point) {
                return [Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "its point differs from the plan's point with the same ID"
                )]
            }
        }
        if result.mutationRef.planID != report.planID {
            return [Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: "its mutationRef carries a different plan identity (a report written before per-result identity was recorded)"
            )]
        }
        return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
    }

    private static func provenanceFindings(_ result: MutationResult) -> [Finding] {
        let id = result.id.rawValue
        let name = "result.provenance"
        let current = MutationVerdictVerifier.currentVersion
        if result.verificationVersion != current {
            switch result.origin {
            case .fresh:
                return [Finding(
                    name: name, status: .notVerifiable, mutationID: id,
                    reason: """
                    verified under verifier version \(result.verificationVersion), current is \(current); \
                    a report cannot be re-judged without its observations
                    """
                )]
            case .checkpoint, .crossRunCache:
                return [Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: """
                    reused (\(result.origin.rawValue)) from verifier version \(result.verificationVersion), \
                    current is \(current); such a result is not reusable
                    """
                )]
            }
        }
        if result.origin == .crossRunCache,
           !(result.outcome.isCacheableResult && result.evidence?.provesSourceApplication == true) {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "a cache-reused result whose outcome or evidence is not reusable"
            )]
        }
        return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
    }

    /// Outcomes the verifier reaches only after a source edit was proven, and
    /// therefore always stores real application evidence for.
    public static func requiresSourceApplication(_ outcome: MutationOutcome) -> Bool {
        switch outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived, .noCoverage, .unviable, .timedOut, .flaky:
            true
        case .notApplied, .baselineMismatch, .infrastructureFailure, .skipped:
            false
        }
    }

    private static func sourceApplicationFindings(_ result: MutationResult) -> [Finding] {
        guard requiresSourceApplication(result.outcome) else { return [] }
        let id = result.id.rawValue
        let name = "evidence.sourceApplication"
        guard let evidence = result.evidence else {
            return [Finding(name: name, status: .fail, mutationID: id, reason: "\(result.outcome.rawValue) with no evidence recorded")]
        }
        guard evidence.provesSourceApplication else {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "\(result.outcome.rawValue) but the before/after hashes and diff do not prove an edit"
            )]
        }
        guard evidence.sourceBeforeHash == result.point.sourceFileHash else {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "the edited file's before-hash is not the file hash the plan anchored to"
            )]
        }
        return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
    }

    private static func activationFindings(_ result: MutationResult) -> [Finding] {
        switch result.outcome {
        case .killedByAssertion, .killedByCrash, .survived:
            break
        default:
            return []
        }
        let id = result.id.rawValue
        let name = "evidence.activation"
        switch result.evidence?.applicationEvidence {
        case let .isolated(activation)?:
            if activation.provesActivation {
                return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
            }
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "\(result.outcome.rawValue) without proven build-product activation"
            )]
        case .schemata?:
            return [Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: "schemata activation chain needs the run's raw observations, which a report does not store"
            )]
        case nil:
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "\(result.outcome.rawValue) with no activation evidence recorded"
            )]
        }
    }

    private static func confirmationFindings(_ result: MutationResult) -> [Finding] {
        let id = result.id.rawValue
        switch result.outcome {
        case .killedByAssertion:
            return [assertionConfirmationFinding(result, id: id)]
        case .killedByCrash:
            let name = "evidence.crashConfirmation"
            guard let confirmation = result.evidence?.crashConfirmation else {
                return [Finding(
                    name: name, status: .notVerifiable, mutationID: id,
                    reason: "no crash confirmation recorded (the run may not have required one)"
                )]
            }
            guard confirmation.crashedAgain else {
                return [Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "killedByCrash but its confirmation did not crash again"
                )]
            }
            return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
        case .verifiedTimeout:
            let name = "evidence.timeoutConfirmation"
            guard let confirmation = result.evidence?.timeoutConfirmation, confirmation.timedOutAgain else {
                return [Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "verifiedTimeout without a recorded confirmation that timed out again"
                )]
            }
            return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
        default:
            return []
        }
    }

    private static func assertionConfirmationFinding(_ result: MutationResult, id: String) -> Finding {
        let name = "evidence.assertionConfirmation"
        guard let confirmation = result.evidence?.assertionKillConfirmation else {
            return Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: "no confirmation recorded; this kill is not shown to have been independently confirmed"
            )
        }
        guard confirmation.disposition.isConfirmed else {
            return Finding(
                name: name, status: .fail, mutationID: id,
                reason: "killedByAssertion although its confirmation is \(confirmation.disposition.rawValue)"
            )
        }
        guard
            confirmation.confirmingStatus == "failed",
            let primary = confirmation.primaryFailingTests,
            let confirming = confirmation.confirmingFailingTests,
            Set(primary) == Set(confirming)
        else {
            return Finding(
                name: name, status: .fail, mutationID: id,
                reason: "marked confirmed but the recorded failing-test sets do not support it"
            )
        }
        guard let control = confirmation.control else {
            // A kill judged by the current verifier is confirmed only with a
            // baseline control; a record without one is stripped. One judged
            // before controls existed is reported as not verifiable, never as
            // controlled.
            if result.verificationVersion == MutationVerdictVerifier.currentVersion {
                return Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "marked confirmed under the current rules but no baseline control is recorded"
                )
            }
            return Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: """
                no baseline control recorded (a kill verified before controls existed); the unmutated build is not \
                shown to pass these tests
                """
            )
        }
        guard control.status == .passedOnBaseline else {
            return Finding(
                name: name, status: .fail, mutationID: id,
                reason: "marked confirmed but its baseline control is \(control.status.rawValue)"
            )
        }
        return Finding(name: name, status: .pass, mutationID: id, reason: "")
    }

    /// Folds per-mutation findings into one check per (name, status), so a
    /// report with thousands of results yields a short, readable list.
    static func aggregate(_ findings: [Finding]) -> [ReverificationCheck] {
        var order: [String] = []
        var grouped: [String: [Finding]] = [:]
        for finding in findings {
            if grouped[finding.name] == nil { order.append(finding.name) }
            grouped[finding.name, default: []].append(finding)
        }

        var checks: [ReverificationCheck] = []
        for name in order {
            let group = grouped[name] ?? []
            for status in [ReverificationCheck.Status.fail, .notVerifiable, .pass] {
                let matching = group.filter { $0.status == status }
                guard !matching.isEmpty else { continue }
                checks.append(ReverificationCheck(
                    name: name, status: status,
                    detail: summary(matching, status: status),
                    mutationIDs: status == .pass ? [] : matching.map(\.mutationID).sorted()
                ))
            }
        }
        return checks
    }

    private static func summary(_ findings: [Finding], status: ReverificationCheck.Status) -> String {
        guard status != .pass else { return "\(findings.count) result(s) consistent." }
        var reasons: [String] = []
        for finding in findings where !reasons.contains(finding.reason) {
            reasons.append(finding.reason)
        }
        let shown = reasons.prefix(3).joined(separator: "; ")
        let more = reasons.count > 3 ? "; and \(reasons.count - 3) other reason(s)" : ""
        return "\(findings.count) result(s): \(shown)\(more)."
    }
}
