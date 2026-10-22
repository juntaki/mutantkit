import Foundation

extension MutationVerdictVerifier {
    // MARK: - Confirmation (ported from ResultClassifier.confirmKill/confirmCrash/confirmTimeout)

    /// Each confirmation kind only means something applied on top of the
    /// specific outcome its own primary classification would have produced
    /// — `.kill` confirms a `.killedByAssertion`, `.crash` a `.killedByCrash`,
    /// `.timeout` a `.timedOut`. `MutationObservations` is public `Codable`
    /// and re-decoded as an untrusted envelope by the cache/checkpoint, so a
    /// hand-edited or corrupted `confirmations` array — a `.kill`
    /// confirmation attached to what actually classified as `.survived` or
    /// `.infrastructureFailure` — must not be able to promote an
    /// unconfirmed/wrong-shaped classification to a kill just by being
    /// present in the list. Folding them unconditionally in order (the
    /// previous behavior) let it do exactly that.
    static func confirm(
        _ original: Classification, confirmation: ConfirmationObservation, primaryApplicationEvidence: MutationApplicationEvidence?
    ) -> Classification {
        let expected: MutationOutcome
        switch confirmation.kind {
        case .kill: expected = .killedByAssertion
        case .crash: expected = .killedByCrash
        case .timeout: expected = .timedOut
        }

        guard original.outcome == expected else {
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: """
                A \(confirmation.kind) confirmation was recorded, but the run it confirms \
                classified as \(original.outcome.rawValue), not \(expected.rawValue) — this \
                observation is inconsistent and cannot be trusted.
                """,
                decidingRun: original.decidingRun
            )
        }

        if case let .schemata(confirmingObservation)? = confirmation.applicationEvidence {
            let problem = schemataConfirmationChainProblem(
                confirmingObservation, primaryApplicationEvidence: primaryApplicationEvidence
            )
            if let problem {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) A confirmation was recorded, but \(problem)",
                    decidingRun: confirmation.run,
                    killConfirmation: confirmation.kind == .kill
                        ? killConfirmationRecord(
                            .chainUnproven, original: original, confirmingRun: confirmation.run
                        )
                        : nil
                )
            }
        }

        switch confirmation.kind {
        case .kill: return confirmKill(original, confirmation: confirmation)
        case .crash: return confirmCrash(original, confirmation: confirmation)
        case .timeout: return confirmTimeout(original, confirmation: confirmation)
        }
    }

    /// Every way a schemata confirmation's own chain fails to independently
    /// prove itself — checked before any kind-specific confirm rule ever
    /// sees it, so a confirmation is never credited on the strength of the
    /// run it is confirming (the re-enabled schemata scoring): it must carry its own
    /// unique STARTUP -> HIT chain, under a `RunID` that is genuinely
    /// different from the primary observation's, never a replay.
    private static func schemataConfirmationChainProblem(
        _ confirmingObservation: SchemataExecutionObservation, primaryApplicationEvidence: MutationApplicationEvidence?
    ) -> String? {
        if case let .schemata(primary)? = primaryApplicationEvidence, primary.expectation.runID == confirmingObservation.expectation.runID {
            return """
            the confirmation reused the original run's own RunID — a confirmation must be a genuinely independent \
            run, never a replay.
            """
        }
        let chain = Result { try verifySchemataChain(confirmingObservation) }
        guard case .success = chain else {
            return "the confirmation's own schemata chain could not be verified: \(schemataChainDiagnosis(chain))"
        }
        return nil
    }

    /// `confirmation.originalFailingTests` is not consulted here: it is a
    /// caller-supplied duplicate of the primary run's own facts, and
    /// `MutationObservations` decodes it as untrusted — a corrupted or
    /// hand-edited entry could set it to whatever it wants without touching
    /// the primary run at all. `original.decidingRun`'s own `summary` is the
    /// actual primary run this confirmation is confirming, so that is what
    /// gets compared against.
    private static func confirmKill(_ original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        guard confirmingRun.status == .failed else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run of the identical, already-built mutant did \
                not fail the same way (\(confirmingRun.status.rawValue)): \(confirmingRun.diagnosis) \
                The suite disagrees with itself, so this is not a proven kill.
                """,
                decidingRun: confirmingRun,
                killConfirmation: killConfirmationRecord(.retestNotFailed, original: original, confirmingRun: confirmingRun)
            )
        }

        guard
            let originalFailingTests = original.decidingRun?.summary?.failingTests,
            let confirmingFailingTests = confirmingRun.summary?.failingTests
        else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run of the identical, already-built mutant also \
                failed, but which test caught it could not be compared between the two runs — \
                the runner reported no per-test breakdown for at least one of them, so there is \
                no way to prove the retest caught the same test rather than a different, \
                unrelated flake. Without that proof this is not a confirmed kill.
                """,
                decidingRun: confirmingRun,
                killConfirmation: killConfirmationRecord(.perTestBreakdownMissing, original: original, confirmingRun: confirmingRun)
            )
        }

        guard Set(originalFailingTests) == Set(confirmingFailingTests) else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run of the identical, already-built mutant also \
                failed, but not on exactly the same test(s) as the first run \
                (originally caught by \(originalFailingTests.joined(separator: ", ")); the retest \
                was caught by \(confirmingFailingTests.joined(separator: ", "))) — the suite is \
                flaking rather than consistently catching this mutation the same way, so this is \
                not a confirmed kill.
                """,
                decidingRun: confirmingRun,
                killConfirmation: killConfirmationRecord(.failingSetDiffers, original: original, confirmingRun: confirmingRun)
            )
        }

        return applyingBaselineControl(
            confirmedKill: Classification(
                outcome: .killedByAssertion,
                diagnosis: "\(original.diagnosis) Confirmed by a second run of the identical mutant, failing the same test(s). The unmutated build passed the same test(s).",
                decidingRun: confirmingRun
            ),
            original: original, confirmation: confirmation
        )
    }

    /// The primary list is read from `original.decidingRun`, never from the
    /// untrusted `originalFailingTests` field (see `confirmKill`). Unknown
    /// lists stay `nil` rather than `[]`.
    static func killConfirmationRecord(
        _ disposition: AssertionKillConfirmation.Disposition, original: Classification, confirmingRun: TestRunResult,
        control: AssertionKillConfirmation.Control? = nil
    ) -> AssertionKillConfirmation {
        AssertionKillConfirmation(
            disposition: disposition,
            primaryFailingTests: original.decidingRun?.summary?.failingTests,
            confirmingFailingTests: confirmingRun.summary?.failingTests,
            confirmingStatus: confirmingRun.status.rawValue,
            control: control
        )
    }

    /// `confirmation.originalDiagnosis` is not consulted here, for the same
    /// reason `confirmKill` does not read `originalFailingTests` — see its
    /// own doc comment. `original.decidingRun`'s own `diagnosis` is used
    /// instead.
    private static func confirmCrash(_ original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        guard confirmingRun.status == .crashed else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) An independent rebuild of the identical mutant did not \
                crash the same way (\(confirmingRun.status.rawValue)): \(confirmingRun.diagnosis) \
                The pipeline disagrees with itself, so this is not a proven kill.
                """,
                decidingRun: confirmingRun
            )
        }

        let originalDiagnosis = original.decidingRun?.diagnosis ?? ""
        let normalizedOriginal = originalDiagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfirming = confirmingRun.diagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedOriginal == normalizedConfirming else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) An independent rebuild of the identical mutant crashed \
                again, but not for the same reason (originally: \(originalDiagnosis); the rebuild: \
                \(confirmingRun.diagnosis)) — the pipeline is crashing inconsistently rather than \
                reproducing the same failure, so this is not a proven kill.
                """,
                decidingRun: confirmingRun
            )
        }

        return Classification(
            outcome: .killedByCrash,
            diagnosis: "\(original.diagnosis) Confirmed by an independent rebuild of the identical mutant, crashing the same way.",
            decidingRun: confirmingRun
        )
    }

    /// `confirmation.activation` is self-reported the same way the primary
    /// path's `SingleTestObservation.applicationEvidence` is, but unlike
    /// the primary path — cross-checked against an independently-observed
    /// `BuildObservation` by `executionEvidenceProblem` — nothing tied a
    /// timeout confirmation's activation to a build this confirmation's own
    /// rebuild was actually observed to produce. A forged `activation`
    /// naming a self-consistent (non-empty, distinct) hash pair that never
    /// came from any real build could still read as proven. This is that
    /// missing cross-check, using `confirmation.confirmingBuildProductHash`
    /// the same way the primary path uses `BuildObservation`'s hash.
    private static func confirmationActivationBuildProblem(_ confirmation: ConfirmationObservation) -> String? {
        guard let activation = confirmation.activation else { return nil }
        return isolatedActivationBuildProblem(activation, buildProductHash: confirmation.confirmingBuildProductHash)
    }

    private static func confirmTimeout(_ original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        if let problem = confirmationActivationBuildProblem(confirmation) {
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: "\(original.diagnosis) An independent rebuild's activation evidence is inconsistent with its own build: \(problem)",
                decidingRun: confirmingRun
            )
        }
        switch confirmingRun.status {
        case .timedOut:
            if let unproven = unprovenActivation(confirmation.applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) An independent rebuild timed out again, but \(unproven) — a timeout cannot be credited as a verified kill without proof the mutation caused it.",
                    decidingRun: confirmingRun
                )
            }
            return Classification(
                outcome: .verifiedTimeout,
                diagnosis: "\(original.diagnosis) Confirmed by an independent rebuild of the identical mutant: timed out again under the same limit.",
                decidingRun: confirmingRun
            )
        case .infrastructureFailure:
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: "\(original.diagnosis) The timeout could not be confirmed: the independent rebuild could not execute (\(confirmingRun.diagnosis)).",
                decidingRun: confirmingRun
            )
        case .passed, .failed, .crashed:
            // Not `confirmation.wasBatchAttributed`: that is a caller-
            // supplied duplicate of the primary run's own
            // `isBatchAttributedTimeout`, decoded as untrusted the same way
            // `originalFailingTests`/`originalDiagnosis` were — a corrupted
            // or hand-edited entry could flip it to `true` for a primary
            // run that was never batch-attributed, promoting what should
            // stay `.flaky` into a trusted kill/survived/crash outcome via
            // `trustedTimeoutOutcome`. The primary run's own status and
            // flag are the only trustworthy source for this.
            guard original.decidingRun?.status == .timedOut, original.decidingRun?.isBatchAttributedTimeout == true else {
                return Classification(
                    outcome: .flaky,
                    diagnosis: """
                    \(original.diagnosis) An independent rebuild of the identical mutant did not \
                    time out the same way (\(confirmingRun.status.rawValue)): \(confirmingRun.diagnosis) \
                    The pipeline disagrees with itself, so this is not a proven kill.
                    """,
                    decidingRun: confirmingRun
                )
            }
            return trustedTimeoutOutcome(original: original, confirmation: confirmation)
        }
    }

    private static func trustedTimeoutOutcome(original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        switch confirmingRun.status {
        case .passed:
            let passing = classifyPassing(run: confirmingRun, applicationEvidence: confirmation.applicationEvidence, coverage: nil)
            return Classification(
                outcome: passing.outcome,
                diagnosis: "\(original.diagnosis) Not confirmed as a timeout: an independent rebuild of the identical mutant ran to completion instead. \(passing.diagnosis)",
                decidingRun: confirmingRun
            )
        case .failed:
            if let unproven = unprovenActivation(confirmation.applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) An independent rebuild's tests failed (\(confirmingRun.diagnosis)), but \(unproven) — a failure cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: confirmingRun
                )
            }
            return Classification(
                outcome: .killedByAssertion,
                diagnosis: "\(original.diagnosis) Not confirmed as a timeout: an independent rebuild of the identical mutant ran to completion instead. \(killedByAssertionDiagnosis(confirmingRun))",
                decidingRun: confirmingRun
            )
        case .crashed:
            if let unproven = unprovenActivation(confirmation.applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) An independent rebuild's test runner crashed (\(confirmingRun.diagnosis)), but \(unproven) — a crash cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: confirmingRun
                )
            }
            return Classification(
                outcome: .killedByCrash,
                diagnosis: "\(original.diagnosis) Not confirmed as a timeout: an independent rebuild of the identical mutant crashed the test runner instead of hanging: \(confirmingRun.diagnosis)",
                decidingRun: confirmingRun
            )
        case .timedOut, .infrastructureFailure:
            preconditionFailure("trustedTimeoutOutcome is only reached for .passed/.failed/.crashed")
        }
    }
}
