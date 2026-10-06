import ArgumentParser
import Foundation
import MutationModel
import Reporting

/// Prints an evidence-grounded trust summary of an already-produced
/// `report.json` — and fails loudly, with a non-zero exit code, when that
/// report cannot be trusted.
///
/// The verdict never rests on the report's stored `integrity.passed` alone:
/// `TrustReport.build(from:verifyingAgainst:)` re-verifies the report through
/// `ReportReverifier` (the checks `verify-run` runs, which stays the detailed
/// view) and any failed check makes the report untrustworthy. Claims a report
/// cannot prove by itself are listed as not verifiable and never counted as
/// verified. Pass `--plan` so the plan-dependent checks, including the
/// integrity recompute, can run; without `--plan` the plan the report names is
/// looked for next to the report and in the project root. A report whose
/// required checks cannot all be verified is never `trustworthy`: it exits
/// `MutantKitExit.notFullyVerified`, distinct from the `integrityFailure` of a
/// mismatch. Nothing here re-runs a test or decides a
/// verdict; that authority stays with `MutationVerdictVerifier`.
struct TrustCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Print an evidence-grounded trust summary of a finished report, and fail if it cannot be trusted."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "A report to summarize and check.")
    var report = ".mutantkit/report.json"

    @Option(
        name: .long,
        help: """
        The plan the report was produced from. Without it the plan named by the report is looked for next \
        to the report and in the project root; if none is found the report is not fully verified.
        """
    )
    var plan: String?

    @Option(
        name: .long,
        help: "The evidence archive directory. Default: the archive the report records, under .mutantkit/evidence/."
    )
    var evidence: String?

    @Flag(name: .long, help: "Emit the trust summary as JSON instead of the text summary below.")
    var json = false

    func run() throws {
        let runReport = try load(path: report, role: "report", code: "report") { try RunReport.decode(from: $0) }
        var loadedPlan = try plan.map { path in try load(path: path, role: "plan", code: "plan") { try MutationPlan.decode(from: $0) } }
        var planSource = loadedPlan == nil ? TrustReport.VerificationSection.PlanSource.none : .supplied
        var planPath = plan
        if loadedPlan == nil,
           let found = PlanLocator.discover(for: runReport, reportPath: report, root: common.resolvedProjectRoot) {
            loadedPlan = found.plan
            planSource = .discovered
            planPath = found.path
        }
        let archive = try EvidenceArchiveLocator.resolve(
            for: runReport, explicit: evidence, root: common.resolvedProjectRoot, json: json
        )
        let trust = TrustReport.build(
            from: runReport, verifyingAgainst: loadedPlan, evidence: archive, planSource: planSource, planPath: planPath,
            expectedPolicy: archive == nil ? nil : EvidenceArchiveLocator.policyBoundToPlan(
                loadedPlan, configPath: common.configPath, root: common.resolvedProjectRoot
            )
        )

        if json {
            try JSONOutput.emit(trust)
        } else {
            printText(trust, report: runReport)
        }

        switch trust.trustStatus {
        case .trustworthy: return
        case .mismatch: throw ExitCode(MutantKitExit.integrityFailure)
        case .notFullyVerified: throw ExitCode(MutantKitExit.notFullyVerified)
        }
    }

    private func printText(_ trust: TrustReport, report: RunReport) {
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

        if let verification = trust.verification {
            printVerification(verification)
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
        if let assertionKills = trust.assertionKills {
            printConfirmation(assertionLabel, assertionKills)
            print("  \(String(repeating: " ", count: Self.confirmationLabelWidth))\(trust.assertionKillConfirmationLimitation)")
        } else {
            print("  \(assertionLabel + String(repeating: " ", count: Self.confirmationLabelWidth - assertionLabel.count))\(trust.assertionKillConfirmationLimitation)")
        }

        if let kills = trust.killEvidence {
            printKillEvidence(kills)
        }

        print("")
        if let score = trust.score {
            let tested = score.killed + score.survived
            let effective = tested + score.noCoverage
            print("Score (as stored in the report; see re-verification above)")
            print(
                "  Tested Mutation Score     \(score.killed)/\(tested) = " +
                    (score.tested.map { String(format: "%.2f%%", $0 * 100) } ?? "n/a")
            )
            print(
                "  Effective Mutation Score  \(score.killed)/\(effective) = " +
                    (score.effective.map { String(format: "%.2f%%", $0 * 100) } ?? "n/a")
            )
        } else {
            print("Score                    WITHHELD — the report did not hold up, so it makes no score claim")
        }

        if trust.operationalIssueCount > 0 {
            print("\n\(trust.operationalIssueCount) operational issue(s) recorded (best-effort; never affected score or integrity) — see report.json's operationalIssues.")
        }

        print("")
        printVerdict(trust)
        if trust.trustStatus != .trustworthy, let notice = Self.olderVerifierNotice(for: report) {
            print(notice)
        }
    }

    private func printVerdict(_ trust: TrustReport) {
        switch trust.trustStatus {
        case .mismatch:
            print("This report is NOT trustworthy: at least one check above failed. No score claim stands.")
        case .notFullyVerified:
            let missing = trust.verification?.unverifiedRequiredChecks ?? []
            print(
                "This report is NOT FULLY VERIFIED, so it is not called trustworthy. No mismatch was found, but required " +
                    "check(s) could not be verified" + (missing.isEmpty ? "" : ": " + missing.joined(separator: ", ")) +
                    ". Pass --plan (or keep plan.json next to the report) to verify them."
            )
        case .trustworthy:
            print("This report is trustworthy: every required check re-verified and its own invariants reconciled.")
            if let verification = trust.verification, verification.notVerifiableCount > 0 {
                print(
                    "\(verification.notVerifiableCount) other check(s) could not be verified and are not counted as verified."
                )
            }
        }
    }

    private func printVerification(_ verification: TrustReport.VerificationSection) {
        print("")
        print("Re-verification (recomputed from the report, not read from its own claims)")
        if let path = verification.planPath {
            print("  Plan (\(verification.planSource.rawValue)): \(path)")
        }
        print("  \(verification.passCount) passed, \(verification.failCount) failed, \(verification.notVerifiableCount) not verifiable" +
            (verification.passed && !verification.complete ? " (PARTIAL: not fully verified)" : ""))
        for check in verification.checks where check.status != .pass {
            let mark = check.status == .fail ? "✗" : "?"
            print("  \(mark) \(check.name): \(check.detail)")
        }
        if let tierB = verification.tierB {
            print(
                "  Tier B (archived raw observations re-run through the verifier): \(tierB.reverifiedCount) re-verified, " +
                    "\(tierB.matchedCount) matched, \(tierB.mismatchedCount) mismatched, " +
                    "\(tierB.notVerifiableCount) without usable observations"
            )
        } else {
            let archiveChecked = verification.checks.contains { $0.name.hasPrefix("archive.") }
            print(
                archiveChecked
                    ? "  Tier B not performed: the evidence archive was not usable or is not bound to the report (see above)."
                    : "  Tier B not performed: no usable evidence archive (set evidence.archive for a run to write one)."
            )
        }
        if !verification.planSupplied {
            print("  No plan found: integrity was not recomputed. `mutantkit verify-run` shows every check.")
        }
    }

    private func printKillEvidence(_ kills: TrustReport.KillEvidenceSection) {
        print("")
        print("Which tests credited the assertion kills (\(kills.assertionKills) total)")
        print("  inside the run's selection        \(kills.withinSelection)")
        print("  whole suite ran, tests named      \(kills.wholeSuiteRan)")
        print("  no failing test named             \(kills.failingTestsUnnamed)  (accepted on the run status alone)")
        print("  attribution not recorded          \(kills.attributionNotRecorded)  (not shown to be inside the selection)")
        print("  failure from a shared batch run   \(kills.batchAttributed)")
        if kills.cascadeConfirmations > 0 {
            print("  results with a cascade of confirmations: \(kills.cascadeConfirmations)")
        }
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

    /// Same shape as `GateCommand`/`SurvivorsCommand`'s own decode: a
    /// structured `--json` error instead of thrown prose when an input is
    /// missing or malformed, and the same operational-error exit code on the
    /// text path.
    private func load<T>(path: String, role: String, code: String, decode: (Data) throws -> T) throws -> T {
        do {
            return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            try JSONOutput.emitError(
                code: error is DecodingError ? "\(code)Malformed" : "\(code)Unreadable",
                message: "Could not read the \(role) at \"\(path)\" as a MutantKit JSON \(role): \(error)",
                remedy: "Check --\(role) points at a real \(role) written by `mutantkit`."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
