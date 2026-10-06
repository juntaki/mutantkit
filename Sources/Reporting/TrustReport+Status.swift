extension TrustReport {
    /// The fail-closed verdict. Anything contradictory is a `mismatch`; a
    /// report with no failure that still has an unverified required check, or
    /// that was never re-verified at all, is `notFullyVerified`. Only a
    /// re-verified report with every required check passed is `trustworthy`.
    static func trustStatus(integrityPassed: Bool, verification: VerificationSection?) -> Status {
        guard integrityPassed else { return .mismatch }
        guard let verification else { return .notFullyVerified }
        guard verification.passed else { return .mismatch }
        return verification.unverifiedRequiredChecks.isEmpty ? .trustworthy : .notFullyVerified
    }
}
