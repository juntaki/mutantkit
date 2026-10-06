import Foundation

public extension ReportReverifier {
    /// The checks a strong "trustworthy" verdict needs to have passed, not
    /// merely not failed. Each one is a pure function of the report and its
    /// plan, so none may be left `notVerifiable`: without the plan the
    /// integrity recompute, plan identity and plan ID checks cannot run, and a
    /// hand-edited integrity self-report would otherwise go unchallenged.
    ///
    /// Evidence-level checks (activation of a schemata mutant, a kill's
    /// confirmation record) are deliberately not listed: a report written with
    /// retest off or by the schemata strategy legitimately cannot show them
    /// from the report alone, and the Tier B archive is what covers them.
    static let requiredCheckNames: [String] = [
        "report.results",
        "plan.identity",
        "plan.mutationIDs",
        "result.identity",
        "result.provenance",
        "integrity.recompute",
        "score.recompute"
    ]
}

public extension ReportReverification {
    /// The required checks (`ReportReverifier.requiredCheckNames`) that did
    /// not pass: missing, failed, or not verifiable. Empty only when every
    /// required check ran and passed.
    var unverifiedRequiredChecks: [String] {
        ReportReverifier.requiredCheckNames.filter { name in
            let matching = checks.filter { $0.name == name }
            return matching.isEmpty || matching.contains { $0.status != .pass }
        }
    }

    /// `true` when every required check is verifiable and passed.
    var requiredChecksVerified: Bool { unverifiedRequiredChecks.isEmpty }
}
