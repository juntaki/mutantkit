import Foundation

extension ConfirmationObservation.Kind {
    /// The name a `ConfirmationStep` records for this confirmation kind.
    var stepName: String {
        switch self {
        case .kill: "kill"
        case .crash: "crash"
        case .timeout: "timeout"
        }
    }
}

extension MutationVerdictVerifier {
    /// Folds `confirmations` into `classification` in the order they were
    /// gathered, recording each round so a cascade keeps every step, not only
    /// the last.
    static func foldConfirmations(
        _ classification: Classification, confirmations: [ConfirmationObservation],
        primaryApplicationEvidence: MutationApplicationEvidence?
    ) -> (Classification, [ConfirmationStep]) {
        var folded = classification
        var chain: [ConfirmationStep] = []
        for confirmation in confirmations {
            let before = folded.outcome
            folded = confirm(folded, confirmation: confirmation, primaryApplicationEvidence: primaryApplicationEvidence)
            chain.append(ConfirmationStep(
                kind: confirmation.kind.stepName, outcomeBefore: before, outcomeAfter: folded.outcome,
                confirmingStatus: confirmation.run.status.rawValue
            ))
        }
        return (folded, chain)
    }

    /// Credits an assertion kill only when the tests that failed lie inside
    /// the selection the run was narrowed to, and records why either way.
    ///
    /// A failure outside the selection means the run was not confined to the
    /// tests chosen for this mutant, so the failure cannot be attributed to
    /// the mutated code; an observation that recorded no execution at all
    /// cannot show it was confined either. Both are `.infrastructureFailure`
    /// — visible and excluded from the score, never a silent survivor and
    /// never a kill. A kill whose run named no failing test is kept (the run's
    /// status is the only evidence there is) but is labelled so it stays
    /// visible. Applies to the final classification, so a kill reached through
    /// a confirmation is held to the same rule as a first-run kill.
    static func applyingKillAttribution(_ classification: Classification, execution: TestExecutionRecord?) -> Classification {
        guard classification.outcome == .killedByAssertion else { return classification }
        let attribution = AssertionKillAttribution.evaluate(
            execution: execution, failingTests: classification.decidingRun?.summary?.failingTests
        )
        guard attribution.disposition.admitsKill else {
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: "\(classification.diagnosis) \(rejectionExplanation(attribution))",
                decidingRun: classification.decidingRun,
                killConfirmation: classification.killConfirmation,
                killAttribution: attribution
            )
        }
        var credited = classification
        credited.killAttribution = attribution
        return credited
    }

    private static func rejectionExplanation(_ attribution: AssertionKillAttribution) -> String {
        switch attribution.disposition {
        case .executionNotRecorded:
            return """
            The observation recorded no test execution (which tests the run was narrowed to), so the failure \
            cannot be shown to come from tests chosen for this mutant. It is not credited as a kill.
            """
        case .outsideSelection:
            let named = attribution.unmatchedFailingTests.prefix(3).joined(separator: ", ")
            return """
            The run was narrowed to \(attribution.selectedTestCount ?? 0) selected test(s), but the failure was \
            reported by test(s) outside that selection\(named.isEmpty ? "" : " (\(named))"). A failure the \
            selection does not account for is not credited as a kill.
            """
        case .withinSelection, .wholeSuiteRan, .failingTestsUnnamed:
            return ""
        }
    }
}

extension MutationEvidence {
    /// A copy without any of the records only `MutationVerdictVerifier` may
    /// author. Applied to every stored evidence before judging it.
    func strippingVerifierAuthoredRecords() -> MutationEvidence {
        copy(
            killConfirmation: nil, attribution: nil, chain: [],
            crashConfirmation: crashConfirmation, timeoutConfirmation: timeoutConfirmation
        )
    }

    /// The evidence as the verifier reports it for `classification`: its own
    /// kill confirmation, kill attribution and confirmation chain, and the
    /// display flags of the runner-authored crash/timeout confirmations
    /// re-derived from the folded chain. A recorded `crashedAgain` /
    /// `timedOutAgain` therefore cannot claim a confirmation the verifier did
    /// not itself fold into the final verdict.
    func verifierAuthored(
        for classification: MutationVerdictVerifier.Classification, confirmationChain: [ConfirmationStep]
    ) -> MutationEvidence {
        let crashConfirmed = classification.outcome == .killedByCrash
            && confirmationChain.contains { $0.kind == "crash" && $0.outcomeAfter == .killedByCrash }
        let timeoutConfirmed = classification.outcome == .verifiedTimeout
            && confirmationChain.contains { $0.kind == "timeout" && $0.outcomeAfter == .verifiedTimeout }
        return copy(
            killConfirmation: classification.killConfirmation, attribution: classification.killAttribution,
            chain: confirmationChain,
            crashConfirmation: crashConfirmation.map {
                $0.crashedAgain == crashConfirmed ? $0 : $0.settingCrashedAgain(crashConfirmed)
            },
            timeoutConfirmation: timeoutConfirmation.map {
                $0.timedOutAgain == timeoutConfirmed ? $0 : $0.settingTimedOutAgain(timeoutConfirmed)
            }
        )
    }

    private func copy(
        killConfirmation: AssertionKillConfirmation?, attribution: AssertionKillAttribution?, chain: [ConfirmationStep],
        crashConfirmation: CrashConfirmation?, timeoutConfirmation: TimeoutConfirmation?
    ) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: sourceBeforeHash, sourceAfterHash: sourceAfterHash, sourceDiff: sourceDiff,
            buildProductHash: buildProductHash, applicationEvidence: applicationEvidence,
            buildCommand: buildCommand, testCommand: testCommand, resultArtifact: resultArtifact,
            crashConfirmation: crashConfirmation, timeoutConfirmation: timeoutConfirmation,
            testAttempts: testAttempts, assertionKillConfirmation: killConfirmation,
            assertionKillAttribution: attribution, confirmationChain: chain
        )
    }
}

private extension CrashConfirmation {
    func settingCrashedAgain(_ value: Bool) -> CrashConfirmation {
        CrashConfirmation(
            confirmingBuildCommand: confirmingBuildCommand, confirmingTestCommand: confirmingTestCommand,
            crashedAgain: value, diagnosis: diagnosis
        )
    }
}

private extension TimeoutConfirmation {
    func settingTimedOutAgain(_ value: Bool) -> TimeoutConfirmation {
        TimeoutConfirmation(
            confirmingBuildCommand: confirmingBuildCommand, confirmingTestCommand: confirmingTestCommand,
            timedOutAgain: value, diagnosis: diagnosis
        )
    }
}
