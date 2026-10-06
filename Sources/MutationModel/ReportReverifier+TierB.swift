import Foundation

/// What Tier B (re-judging from archived raw observations) covered.
public struct TierBSummary: Codable, Sendable, Equatable {
    public let runID: String
    /// Results whose archived observations were re-run through the verifier.
    public let reverifiedCount: Int
    /// Of those, results whose re-derived outcome equals the stored one.
    public let matchedCount: Int
    public let mismatchedCount: Int
    /// Results the archive holds no usable observations for.
    public let notVerifiableCount: Int
    /// Problems found in the archive itself (hash mismatches, missing files).
    public let archiveProblemCount: Int
    /// Verifier version the run was produced under, and the one that re-judged it.
    public let recordedVerifierVersion: Int
    public let currentVerifierVersion: Int
    public let policy: MutationVerdictVerifier.VerdictVerificationPolicy
}

extension ReportReverifier {
    struct TierBResult {
        var checks: [ReverificationCheck]
        var summary: TierBSummary?
    }

    /// Tier B: with the archive's raw observations, re-run
    /// `MutationVerdictVerifier.verify` under the policy the run recorded and
    /// compare the outcome with the stored one. No new judgement lives here:
    /// the verifier decides, this compares. Absent or unreadable evidence is
    /// `notVerifiable` or a failure, never a pass.
    ///
    /// Two bindings keep this from being read as more than it is. An archive
    /// the report does not reference is not bound to it by a hash, so it is
    /// checked for its own consistency only and nothing is re-judged from it
    /// (`tierBPerformed` stays `false`). And the re-judging policy is read
    /// from the archive's own manifest; it is compared with `expectedPolicy`,
    /// the policy derived from the project configuration the plan's
    /// configuration hash binds, when the caller has one, and is otherwise
    /// reported as not independently bound. Tier B checks are never among the
    /// required checks, so a pass here cannot stand in for one. All of this
    /// is a consistency check, not a signature.
    static func tierBChecks(
        report: RunReport, evidence: LoadedEvidenceArchive?,
        expectedPolicy: MutationVerdictVerifier.VerdictVerificationPolicy? = nil
    ) -> TierBResult {
        guard let evidence else {
            guard let reference = report.evidenceArchive else { return TierBResult(checks: [], summary: nil) }
            return TierBResult(checks: [ReverificationCheck(
                name: "archive.present", status: .notVerifiable,
                detail: """
                The report records an evidence archive (run \(reference.runID)) but none was found; \
                Tier B was not performed. Pass --evidence <dir> to point at it.
                """
            )], summary: nil)
        }
        var checks = [archiveIntegrityCheck(report: report, evidence: evidence)]
        if report.evidenceArchive == nil {
            checks.append(ReverificationCheck(
                name: "archive.binding", status: .notVerifiable,
                detail: """
                Unbound archive: the report records no evidence archive, so this one is not tied to it by a hash. \
                Only its own consistency was checked; no result was re-judged from it and Tier B was not performed.
                """
            ))
            return TierBResult(checks: checks, summary: nil)
        }
        guard let manifest = evidence.manifest, manifest.planID == report.planID else {
            return TierBResult(checks: checks, summary: nil)
        }
        checks.append(policyCheck(manifest: manifest, expected: expectedPolicy))
        let current = MutationVerdictVerifier.currentVersion
        if manifest.verifierVersion != current {
            checks.append(ReverificationCheck(
                name: "archive.versions", status: .notVerifiable,
                detail: """
                The run used verifier version \(manifest.verifierVersion); observations are re-judged under the current \
                version \(current), and any outcome difference is reported as a mismatch.
                """
            ))
        }

        var findings: [Finding] = []
        var reverified = 0
        var matched = 0
        let reportedIDs = Set(report.results.map(\.id.rawValue))
        for result in report.results {
            let finding = tierBFinding(result, evidence: evidence, manifest: manifest)
            findings.append(finding.finding)
            if finding.reverified { reverified += 1 }
            if finding.finding.status == .pass { matched += 1 }
        }
        for id in evidence.entries.keys.sorted() where !reportedIDs.contains(id) {
            findings.append(Finding(
                name: "tierB.outcome", status: .fail, mutationID: id,
                reason: "the archive holds observations for a mutation the report does not contain"
            ))
        }
        let tierBChecks = aggregate(findings)
        checks.append(contentsOf: tierBChecks)
        guard reverified > 0 else { return TierBResult(checks: checks, summary: nil) }
        let summary = TierBSummary(
            runID: manifest.runID, reverifiedCount: reverified, matchedCount: matched,
            mismatchedCount: findings.filter { $0.status == .fail }.count,
            notVerifiableCount: findings.filter { $0.status == .notVerifiable }.count,
            archiveProblemCount: evidence.problems.count,
            recordedVerifierVersion: manifest.verifierVersion, currentVerifierVersion: current, policy: manifest.policy
        )
        return TierBResult(checks: checks, summary: summary)
    }

    /// The confirmation policy Tier B re-judges under comes from the archive's
    /// own manifest. Compared with the one derived independently when there is
    /// one; otherwise said plainly to be taken from the archive itself.
    private static func policyCheck(
        manifest: EvidenceArchiveManifest, expected: MutationVerdictVerifier.VerdictVerificationPolicy?
    ) -> ReverificationCheck {
        guard let expected else {
            return ReverificationCheck(
                name: "archive.policy", status: .notVerifiable,
                detail: """
                Policy taken from the archive itself, not independently bound: the plan records only a configuration hash \
                and no project configuration matching it was available to derive the confirmation policy from.
                """
            )
        }
        guard expected == manifest.policy else {
            return ReverificationCheck(
                name: "archive.policy", status: .fail,
                detail: """
                The archive's confirmation policy (\(describe(manifest.policy))) differs from the one the project \
                configuration bound to the plan implies (\(describe(expected))).
                """
            )
        }
        return ReverificationCheck(
            name: "archive.policy", status: .pass,
            detail: "The archive's confirmation policy equals the one derived from the project configuration bound to the plan."
        )
    }

    private static func describe(_ policy: MutationVerdictVerifier.VerdictVerificationPolicy) -> String {
        "retestKilledMutants \(policy.retestKilledMutants), confirmCrashKills \(policy.confirmCrashKills), " +
            "confirmTimedOutMutants \(policy.confirmTimedOutMutants)"
    }

    private static func archiveIntegrityCheck(report: RunReport, evidence: LoadedEvidenceArchive) -> ReverificationCheck {
        var problems = evidence.problems.map { problem in
            (problem.mutationID.map { "\($0): " } ?? "") + problem.detail
        }
        var affected = evidence.problems.compactMap(\.mutationID)
        if let manifest = evidence.manifest {
            if manifest.planID != report.planID {
                problems.append("the archive is for plan \(manifest.planID), the report for \(report.planID)")
            }
            if let reference = report.evidenceArchive {
                if reference.runID != manifest.runID {
                    problems.append("the report records run \(reference.runID) but the archive is for run \(manifest.runID)")
                }
                if reference.manifestHash != evidence.manifestHash {
                    problems.append("the manifest does not match the hash the report records for it")
                }
            }
        }
        affected = Array(Set(affected)).sorted()
        guard problems.isEmpty else {
            let shown = problems.prefix(3).joined(separator: "; ")
            let more = problems.count > 3 ? "; and \(problems.count - 3) more" : ""
            return ReverificationCheck(
                name: "archive.integrity", status: .fail, detail: "\(problems.count) problem(s): \(shown)\(more).",
                mutationIDs: affected
            )
        }
        return ReverificationCheck(
            name: "archive.integrity", status: .pass,
            detail: "Manifest and all \(evidence.entries.count) observation file(s) match their recorded hashes and this run."
        )
    }

    private static func tierBFinding(
        _ result: MutationResult, evidence: LoadedEvidenceArchive, manifest: EvidenceArchiveManifest
    ) -> (finding: Finding, reverified: Bool) {
        let id = result.id.rawValue
        let name = "tierB.outcome"
        guard let entry = evidence.entries[id] else {
            let reason = evidence.problems.contains { $0.mutationID == id }
                ? "its archived observations failed the archive checks"
                : "no observations archived for it (resumed from \(result.origin.rawValue), or evaluated outside this archive)"
            return (Finding(name: name, status: .notVerifiable, mutationID: id, reason: reason), false)
        }
        let observed = entry.observations.plannedMutation
        guard observed.pointDigest == result.mutationRef.pointDigest, observed.planID == result.mutationRef.planID else {
            return (Finding(
                name: name, status: .fail, mutationID: id,
                reason: "its archived observations are for a different point or plan than the report's result"
            ), false)
        }
        let rederivedRecord = MutationVerdictVerifier.verify(entry.observations, policy: manifest.policy)
        let rederived = rederivedRecord.outcome
        if rederived == result.outcome, rederived == .killedByAssertion,
           result.evidence?.assertionKillConfirmation?.control?.status
           != rederivedRecord.proof.evidence?.assertionKillConfirmation?.control?.status {
            return (Finding(
                name: name, status: .fail, mutationID: id,
                reason: "the stored baseline control status differs from the one its archived observations re-derive"
            ), true)
        }
        guard rederived == result.outcome else {
            return (Finding(
                name: name, status: .fail, mutationID: id,
                reason: "stored \(result.outcome.rawValue) but its observations re-derive \(rederived.rawValue)"
            ), true)
        }
        return (Finding(name: name, status: .pass, mutationID: id, reason: ""), true)
    }
}
