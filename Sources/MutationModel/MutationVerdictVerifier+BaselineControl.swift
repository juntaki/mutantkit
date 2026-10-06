extension MutationVerdictVerifier {
    /// Applies the baseline control to a kill whose retest reproduced the same
    /// failing tests. A kill is confirmed only when the unmutated build passed
    /// the same tests; every other control state keeps it out of the kill
    /// column, and an absent control is never read as a pass:
    ///
    /// - the unmutated build failed too: `.flaky` (the failure is not shown to
    ///   come from the mutation);
    /// - the control is missing or did not reach a usable verdict:
    ///   `.infrastructureFailure` (excluded from the score, visible).
    static func applyingBaselineControl(
        confirmedKill: Classification, original: Classification, confirmation: ConfirmationObservation
    ) -> Classification {
        let confirmingRun = confirmation.run
        let failing = original.decidingRun?.summary?.failingTests
        let control = confirmation.baselineControl?.judge(killFailingTests: failing)

        switch control?.status {
        case .passedOnBaseline?:
            var confirmed = confirmedKill
            confirmed.killConfirmation = killConfirmationRecord(
                .confirmed, original: original, confirmingRun: confirmingRun, control: control
            )
            return confirmed
        case .failedOnBaseline?:
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run reproduced the failure, but the unmutated build also failed \
                (\(control?.runStatus ?? "failed")) in the baseline control run, so the failure is not shown to \
                come from the mutation. This is not a confirmed kill.
                """,
                decidingRun: confirmingRun,
                killConfirmation: killConfirmationRecord(
                    .baselineControlFailed, original: original, confirmingRun: confirmingRun, control: control
                )
            )
        case .notEstablished?, nil:
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: """
                \(original.diagnosis) A second run reproduced the failure, but no baseline control showed the same \
                tests passing on the unmutated build\(control == nil ? " (none was recorded)" : ""). A failure that \
                could come from the environment is not credited as a kill.
                """,
                decidingRun: confirmingRun,
                killConfirmation: killConfirmationRecord(
                    .baselineControlNotEstablished, original: original, confirmingRun: confirmingRun, control: control
                )
            )
        }
    }
}
