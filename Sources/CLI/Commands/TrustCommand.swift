import ArgumentParser
import Foundation
import MutationModel
import Reporting

/// Prints an evidence-grounded trust summary of an already-produced
/// `report.json` — and fails loudly, with a non-zero exit code, when that
/// report cannot be trusted.
///
/// This is a NEW SUMMARY VIEW over data `mutantkit run` already computed and
/// wrote, not a new execution path: every line comes from `TrustReport.build`
/// reading `RunReport`'s own `integrity`/`results`/`score` fields (see that
/// type's own doc comment for exactly which fields, and why none of them are
/// re-derived rather than reused). Nothing here re-verifies a mutant, re-runs
/// a test, or recomputes a score — that authority stays exactly where
/// `MutationVerdictVerifier` already put it.
///
/// Named `trust`, not `verify`: `VerifyCommand` (`mutantkit verify`) already
/// exists and does a different, pre-run job — checking a `plan.json`'s IDs
/// and source anchors before a run ever starts. This command is the post-run
/// counterpart people actually mean by "can I trust this score" — reading a
/// finished `report.json`, not a plan. Reusing the `verify` name for both
/// would collide two real, different jobs onto one command; see this
/// command's own commit message and `Research/trust-corpus-2026-09/README.md`
/// for the full naming discussion, left as an explicit, named finding for
/// the maintainer rather than a unilateral rename of an existing, tested
/// command.
struct TrustCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Print an evidence-grounded trust summary of a finished report, and fail if it cannot be trusted."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "A report to summarize and check.")
    var report = ".mutantkit/report.json"

    @Flag(name: .long, help: "Emit the trust summary as JSON instead of the text summary below.")
    var json = false

    func run() throws {
        let runReport = try decode(reportPath: report)
        let trust = TrustReport.build(from: runReport)

        if json {
            try JSONOutput.emit(trust)
        } else {
            printText(trust)
        }

        guard trust.trustworthy else {
            throw ExitCode(MutantKitExit.integrityFailure)
        }
    }

    private func printText(_ trust: TrustReport) {
        print("Trust summary for \(trust.planID) — \(trust.mutationCount) mutation(s)\n")

        if trust.integrity.passed {
            print("✓ Integrity              no violations — every invariant reconciled")
        } else {
            print("✗ Integrity              FAILED (\(trust.integrity.violationCount) violation(s))")
            for violation in trust.integrity.violations {
                let location = violation.mutationID.map { " [\($0)]" } ?? ""
                print("  └─ \(violation.kind.rawValue)\(location): \(violation.detail)")
            }
        }

        let sa = trust.sourceApplication
        if sa.withoutEvidence == 0 {
            print("✓ Source application     \(sa.withEvidence)/\(sa.total) mutation(s) carry real source-diff evidence")
        } else {
            print("✗ Source application     \(sa.withEvidence)/\(sa.total) — \(sa.withoutEvidence) mutation(s) have no proof of a real source edit")
        }

        if trust.phantomMutantCount == 0 {
            print("✓ Phantom mutants        0 — no reported result claims a mutation that never touched the source")
        } else {
            print("✗ Phantom mutants        \(trust.phantomMutantCount) — see Integrity violations above")
        }

        let ae = trust.activationEvidence
        print("")
        print("Activation evidence (does each mutant's edit provably reach the tested binary?)")
        print("  isolated, proven          \(ae.isolatedProven)")
        print("  isolated, NOT proven      \(ae.isolatedNotProven)  (build product identical to baseline — no-op)")
        print("  schemata (verified)       \(ae.schemataPresent)")
        print("  no evidence recorded      \(ae.noEvidence)  (e.g. build failure before any binary existed)")

        print("")
        print("Independent re-confirmation of a kill")
        printConfirmation("killed by crash", trust.crashKills)
        printConfirmation("killed by verified timeout", trust.timeoutKills)
        let assertionLabel = "killed by assertion"
        print("  \(assertionLabel + String(repeating: " ", count: Self.confirmationLabelWidth - assertionLabel.count))\(trust.assertionKillConfirmationLimitation)")

        print("")
        if let score = trust.score {
            let tested = score.killed + score.survived
            let effective = tested + score.noCoverage
            print("Score (reused from the report, not recomputed)")
            print(
                "  Tested Mutation Score     \(score.killed)/\(tested) = " +
                    (score.tested.map { String(format: "%.2f%%", $0 * 100) } ?? "n/a")
            )
            print(
                "  Effective Mutation Score  \(score.killed)/\(effective) = " +
                    (score.effective.map { String(format: "%.2f%%", $0 * 100) } ?? "n/a")
            )
        } else {
            print("Score                    WITHHELD — integrity failed, so this report makes no score claim")
        }

        if trust.operationalIssueCount > 0 {
            print("\n\(trust.operationalIssueCount) operational issue(s) recorded (best-effort; never affected score or integrity) — see report.json's operationalIssues.")
        }

        print("")
        print(
            trust.trustworthy
                ? "This report is trustworthy: its own invariants reconciled."
                : "This report is NOT trustworthy: at least one invariant above failed to reconcile. No score claim stands."
        )
    }

    private func printConfirmation(_ label: String, _ section: TrustReport.ConfirmationSection) {
        let padded = label.count < Self.confirmationLabelWidth
            ? label + String(repeating: " ", count: Self.confirmationLabelWidth - label.count)
            : label + " "
        guard section.killed > 0 else {
            print("  \(padded)none this run")
            return
        }
        print(
            "  \(padded)\(section.killed) total — " +
                "\(section.confirmed) independently reconfirmed, \(section.unconfirmed) accepted on a single observation"
        )
    }

    /// Wide enough for the longest confirmation label this command prints
    /// ("killed by verified timeout", 27 characters) plus a separating
    /// space — `String.padding(toLength:)` would instead *truncate* a
    /// longer label to fit, which silently mangled that exact line before
    /// this was measured explicitly rather than guessed.
    private static let confirmationLabelWidth = 28

    /// Same shape as `GateCommand`/`SurvivorsCommand`'s own `decode(reportPath:)`:
    /// a structured `--json` error instead of thrown prose when the report is
    /// missing or malformed, and the same operational-error exit code on the
    /// text path.
    private func decode(reportPath: String) throws -> RunReport {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
            return try MutationPlan.decoder().decode(RunReport.self, from: data)
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            let code = error is DecodingError ? "reportMalformed" : "reportUnreadable"
            try JSONOutput.emitError(
                code: code,
                message: "Could not read the report at \"\(reportPath)\" as a MutantKit JSON report: \(error)",
                remedy: "Check --report points at a real report.json written by `mutantkit run`."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
