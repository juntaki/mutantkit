import ArgumentParser
import Foundation
import MutationModel

/// Re-verifies what a finished `report.json` can prove on its own.
///
/// An orchestrator only: the judgements live in `ReportReverifier`
/// (MutationModel), next to the verifier, and the anchor check is the same one
/// `verify` runs. Nothing here decides a verdict, writes a report, or
/// corrects a record.
///
/// What this proves is internal consistency and re-derivability, not
/// authenticity: the report is still trusted to be the one the run produced.
/// Verdicts that depend on raw observations (which a report does not store)
/// are reported as not verifiable, never as passed.
struct VerifyRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-run",
        abstract: "Re-verify a finished report: plan identity, anchors, evidence consistency, integrity and score."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "The report.json to re-verify.")
    var report: String

    @Option(name: .long, help: "The plan the report was produced from. Without it, plan-dependent checks are reported as not verifiable.")
    var plan: String?

    @Option(
        name: .long,
        help: "The evidence archive directory. Default: the archive the report records, under .mutantkit/evidence/."
    )
    var evidence: String?

    @Flag(name: .long, help: "Emit the re-verification result as JSON instead of the text report.")
    var json = false

    func run() async throws {
        let runReport = try load(path: report, role: "report", code: "report") { try RunReport.decode(from: $0) }
        let loadedPlan = try plan.map { path in
            try load(path: path, role: "plan", code: "plan") { try MutationPlan.decode(from: $0) }
        }

        let archive = try EvidenceArchiveLocator.resolve(
            for: runReport, explicit: evidence, root: common.resolvedProjectRoot, json: json
        )
        let result = Self.evaluate(
            report: runReport, plan: loadedPlan, root: common.resolvedProjectRoot, evidence: archive,
            expectedPolicy: archive == nil ? nil : EvidenceArchiveLocator.policyBoundToPlan(
                loadedPlan, configPath: common.configPath, root: common.resolvedProjectRoot
            )
        )

        if json {
            try JSONOutput.emit(result)
        } else {
            Self.printText(result)
        }
        guard result.passed else { throw ExitCode(MutantKitExit.integrityFailure) }
    }

    /// Pure of console output, so tests can drive it directly.
    static func evaluate(
        report: RunReport, plan: MutationPlan?, root: URL, evidence: LoadedEvidenceArchive? = nil,
        expectedPolicy: MutationVerdictVerifier.VerdictVerificationPolicy? = nil
    ) -> VerifyRunResult {
        let reverification = ReportReverifier.reverify(
            report: report, plan: plan, evidence: evidence, expectedPolicy: expectedPolicy
        )
        var checks = reverification.checks
        checks.insert(anchorCheck(report: report, plan: plan, root: root), at: Self.anchorInsertionIndex(in: checks))
        checks.insert(
            sourceEvidenceCheck(report: report, root: root), at: Self.anchorInsertionIndex(in: checks) + 1
        )
        return VerifyRunResult(
            planID: report.planID,
            resultCount: report.results.count,
            planSupplied: plan != nil,
            verifierVersion: MutationVerdictVerifier.currentVersion,
            checks: checks,
            tierB: reverification.tierB
        )
    }

    /// Right after the plan checks, so the output reads plan, anchors, per-result, integrity, score.
    private static func anchorInsertionIndex(in checks: [ReverificationCheck]) -> Int {
        checks.lastIndex { $0.name.hasPrefix("plan.") }.map { $0 + 1 } ?? 0
    }

    private static func anchorCheck(report: RunReport, plan: MutationPlan?, root: URL) -> ReverificationCheck {
        let points = plan?.mutations ?? report.results.map(\.point)
        let anchors = VerifyCommand.checkAnchors(of: points, root: root, verbose: false)
        let missing = Set(anchors.unreadable).sorted()
        if anchors.rejected.isEmpty, missing.isEmpty {
            return ReverificationCheck(
                name: "source.anchors", status: .pass,
                detail: "All \(points.count) anchor(s) match the current source under \(root.path)."
            )
        }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing file(s): " + missing.joined(separator: ", ")) }
        if !anchors.rejected.isEmpty {
            parts.append("\(anchors.rejected.count) anchor(s) no longer match: " + anchors.rejected.prefix(3).map {
                "\($0.0.displayLocation) (\($0.1.diagnosis))"
            }.joined(separator: "; "))
        }
        return ReverificationCheck(
            name: "source.anchors", status: .fail, detail: parts.joined(separator: "; ") + ".",
            mutationIDs: anchors.rejected.map { $0.0.id.rawValue }.sorted()
        )
    }

    private static func printText(_ result: VerifyRunResult) {
        print("Re-verifying report for plan \(result.planID): \(result.resultCount) result(s), verifier version \(result.verifierVersion)\n")
        for check in result.checks {
            let mark = switch check.status {
            case .pass: "✓"
            case .fail: "✗"
            case .notVerifiable: "?"
            }
            let label = check.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            print("\(mark) \(label) \(check.detail)")
            if check.status != .pass, !check.mutationIDs.isEmpty {
                let shown = check.mutationIDs.prefix(5).joined(separator: ", ")
                let more = check.mutationIDs.count > 5 ? ", and \(check.mutationIDs.count - 5) more" : ""
                print("  \(String(repeating: " ", count: 30))mutations: \(shown)\(more)")
            }
        }
        print("")
        print("\(result.passCount) passed, \(result.failCount) failed, \(result.notVerifiableCount) not verifiable from a report.")
        if let tierB = result.tierB {
            print(
                "Tier B (raw observations re-run through the verifier, run \(tierB.runID)): \(tierB.reverifiedCount) re-verified, " +
                    "\(tierB.matchedCount) matched, \(tierB.mismatchedCount) mismatched, " +
                    "\(tierB.notVerifiableCount) without usable observations. Not-verifiable items are not counted as passed."
            )
        } else {
            print("Tier B (re-verification from raw observations) was not performed; not-verifiable items are not counted as passed.")
        }
        print("This checks internal consistency and re-derivability, not who produced the report.")
        print("\n" + summaryLine(for: result))
    }

    /// The closing verdict line: a mismatch, a full verification, or PARTIAL
    /// (no mismatch, but something could not be verified).
    static func summaryLine(for result: VerifyRunResult) -> String {
        if !result.passed { return "MISMATCH: this report does not re-verify." }
        if result.complete { return "Fully verified: every check passed." }
        return "PARTIAL: no mismatch found, but \(result.notVerifiableCount) check(s) could not be verified. " +
            "This is not a full verification."
    }

    /// Same shape as `TrustCommand`'s own decode: one JSON error document on
    /// the `--json` path, `operationalError` either way.
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
                remedy: "Check the \(role) path points at a real \(role) written by `mutantkit`."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}

/// `mutantkit verify-run --json`.
struct VerifyRunResult: Codable {
    let schemaVersion: Int
    let planID: String
    let resultCount: Int
    let planSupplied: Bool
    let verifierVersion: Int
    /// `true` only when an evidence archive was read and at least one result
    /// was re-judged from its raw observations.
    let tierBPerformed: Bool
    /// Present exactly when `tierBPerformed`.
    let tierB: TierBSummary?
    /// `true` when no check failed. A report with not-verifiable checks still
    /// has `passed == true`; read `complete` to tell it from a full verification.
    let passed: Bool
    /// `true` only when every check passed (none failed, none not verifiable).
    /// `passed && !complete` is a PARTIAL verification.
    let complete: Bool
    let passCount: Int
    let failCount: Int
    let notVerifiableCount: Int
    let checks: [ReverificationCheck]

    init(
        planID: String, resultCount: Int, planSupplied: Bool, verifierVersion: Int, checks: [ReverificationCheck],
        tierB: TierBSummary? = nil
    ) {
        let summary = ReportReverification(checks: checks)
        schemaVersion = SchemaVersion.verifyRunResult
        self.planID = planID
        self.resultCount = resultCount
        self.planSupplied = planSupplied
        self.verifierVersion = verifierVersion
        tierBPerformed = tierB != nil
        self.tierB = tierB
        passed = summary.passed
        complete = summary.complete
        passCount = summary.passCount
        failCount = summary.failureCount
        notVerifiableCount = summary.notVerifiableCount
        self.checks = checks
    }
}
