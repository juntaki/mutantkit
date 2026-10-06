import Foundation
import MutationModel

extension TrustCommand {
    /// The line `trust` prints when the report's results were verified by an
    /// older verifier than the current one, or `nil` when none were.
    ///
    /// Such a report can never be called trustworthy: `result.provenance` is a
    /// required check, and a result judged under another verifier version
    /// cannot be re-judged from the report. The required checks are not
    /// relaxed for it; the way out is a fresh run.
    static func olderVerifierNotice(for report: RunReport) -> String? {
        let current = MutationVerdictVerifier.currentVersion
        let older = Set(report.results.map(\.verificationVersion).filter { $0 != current }).sorted()
        guard !older.isEmpty else { return nil }
        let versions = older.map(String.init).joined(separator: ", ")
        let label = older.count == 1 ? "version \(versions)" : "versions \(versions)"
        return "This report was produced by an older verifier (\(label); current is \(current)); " +
            "re-run to obtain a verifiable report."
    }
}
