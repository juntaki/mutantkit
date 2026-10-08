/// Report-only checks over the verifier-authored kill evidence: which tests
/// credited an assertion kill, and the chain of confirmations behind a
/// verdict. Like everything in `ReportReverifier` these compare stored facts
/// with each other; the judgement of what makes attribution coherent lives on
/// `AssertionKillAttribution`.
extension ReportReverifier {
    static func killEvidenceFindings(_ result: MutationResult) -> [Finding] {
        var findings: [Finding] = []
        if result.outcome == .killedByAssertion {
            findings.append(killAttributionFinding(result))
        }
        findings.append(contentsOf: confirmationConsistencyFindings(result))
        return findings
    }

    private static func killAttributionFinding(_ result: MutationResult) -> Finding {
        let id = result.id.rawValue
        let name = "evidence.killAttribution"
        guard let attribution = result.evidence?.assertionKillAttribution else {
            // A result judged by the current verifier always carries one; its
            // absence there is a stripped record, never "fine". Only a result
            // judged before the record existed may legitimately lack it, and
            // that is reported as not verifiable, never as a pass.
            if result.verificationVersion == MutationVerdictVerifier.currentVersion {
                return Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "killedByAssertion verified under the current rules but no kill attribution is recorded"
                )
            }
            return Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: "no kill attribution recorded (a result verified before it existed); which tests credited this kill is unknown"
            )
        }
        if let problem = attribution.inconsistency(resultFailingTests: result.testSummary?.failingTests) {
            return Finding(name: name, status: .fail, mutationID: id, reason: "killedByAssertion but \(problem)")
        }
        return Finding(name: name, status: .pass, mutationID: id, reason: "")
    }

    private static func confirmationConsistencyFindings(_ result: MutationResult) -> [Finding] {
        let id = result.id.rawValue
        let name = "evidence.confirmationChain"
        guard let evidence = result.evidence else { return [] }
        let current = result.verificationVersion == MutationVerdictVerifier.currentVersion

        if evidence.crashConfirmation?.crashedAgain == true, result.outcome != .killedByCrash {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "a crash confirmation claims the crash reproduced, but the result is \(result.outcome.rawValue)"
            )]
        }
        if evidence.timeoutConfirmation?.timedOutAgain == true, result.outcome != .verifiedTimeout {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "a timeout confirmation claims the timeout reproduced, but the result is \(result.outcome.rawValue)"
            )]
        }

        let chain = evidence.confirmationChain
        for (index, step) in chain.enumerated() where index > 0 && chain[index - 1].outcomeAfter != step.outcomeBefore {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "the confirmation chain is not contiguous at step \(index + 1) (\(step.kind))"
            )]
        }
        if let last = chain.last, last.outcomeAfter != result.outcome, result.outcome != .infrastructureFailure {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "the confirmation chain ends at \(last.outcomeAfter.rawValue) but the result is \(result.outcome.rawValue)"
            )]
        }

        if current {
            if evidence.crashConfirmation?.crashedAgain == true,
               !chain.contains(where: { $0.kind == "crash" && $0.outcomeAfter == .killedByCrash }) {
                return [Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "a crash confirmation is marked reproduced but the chain holds no confirming crash step"
                )]
            }
            if evidence.timeoutConfirmation?.timedOutAgain == true,
               !chain.contains(where: { $0.kind == "timeout" && $0.outcomeAfter == .verifiedTimeout }) {
                return [Finding(
                    name: name, status: .fail, mutationID: id,
                    reason: "a timeout confirmation is marked reproduced but the chain holds no confirming timeout step"
                )]
            }
        }
        return chain.isEmpty && evidence.crashConfirmation == nil && evidence.timeoutConfirmation == nil
            ? [] : [Finding(name: name, status: .pass, mutationID: id, reason: "")]
    }
}
