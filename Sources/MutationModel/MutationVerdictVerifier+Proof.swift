extension MutationVerdictVerifier {
    // MARK: - Classification -> VerdictProof

    static func proof(
        for classification: Classification, ref: PlannedMutationRef, evidence recorded: MutationEvidence,
        confirmationChain: [ConfirmationStep] = [], coverageSource: String? = nil
    ) -> VerdictProof {
        let evidence = recorded.verifierAuthored(for: classification, confirmationChain: confirmationChain)
        switch classification.outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived:
            return .executed(ExecutedMutationProof(
                mutationRef: ref, outcome: classification.outcome,
                evidence: evidence,
                testSummary: classification.decidingRun?.summary, diagnosis: classification.diagnosis
            ))
        case .noCoverage:
            return .noCoverage(NoCoverageProof(
                mutationRef: ref, sourceApplication: evidence, coverageSource: coverageSource, diagnosis: classification.diagnosis
            ))
        case .unviable:
            return .unviable(BuildFailureProof(mutationRef: ref, diagnosis: classification.diagnosis, evidence: evidence))
        case .timedOut, .flaky, .notApplied, .baselineMismatch, .infrastructureFailure, .notMaterialized, .skipped:
            return excluded(
                ref, outcome: classification.outcome, diagnosis: classification.diagnosis, evidence: evidence
            )
        }
    }

    static func excluded(
        _ ref: PlannedMutationRef, outcome: MutationOutcome, diagnosis: String, evidence: MutationEvidence? = nil
    ) -> VerdictProof {
        .excluded(ExclusionProof(mutationRef: ref, outcome: outcome, diagnosis: diagnosis, evidence: evidence))
    }
}
