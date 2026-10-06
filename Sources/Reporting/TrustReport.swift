import MutationModel

/// The evidence-grounded trust summary `mutantkit trust` prints — a new
/// view over an already-produced `report.json`, not a new execution path.
///
/// Every field here is read straight off `RunReport`'s own already-computed
/// facts (`integrity`, `results[].evidence`, `score`) or a direct, narrow
/// tally over them. Nothing here re-derives a verdict `MutationVerdictVerifier`
/// already decided — this project's own standing rule is that verdict
/// authority lives in exactly one place (the verifier, at result-construction
/// time), and a reporting layer that re-implements any part of that judgment
/// is exactly the failure mode this type must not become. In particular:
///
/// - `activationEvidence.schemataPresent` counts mutants whose evidence
///   carries a `.schemata` application-evidence case; it does **not**
///   re-walk `SchemataExecutionObservation`'s STARTUP/HIT chain to
///   re-decide whether that evidence actually proves activation — that
///   chain was already built and checked, once, authoritatively, by
///   `MutationVerdictVerifier.verifySchemataChain` when this result's
///   outcome was first produced (mirrors `InspectCommand.agentEvidenceInfo`'s
///   identical restraint for the same reason — see that function's own
///   comment).
/// - `score` is `report.score`, verbatim, gated on `integrity.passed` —
///   never recomputed from `results`. See `score`'s own doc comment for why
///   that gate is re-enforced here rather than trusted from the decoded
///   `RunReport`.
///
/// These definitions (phantom mutant, activation evidence, ...) are checked
/// against a dedicated corpus of test fixtures in this project's test suite.
public struct TrustReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let planID: String
    public let mutationCount: Int
    /// Whether this report holds up, fail-closed: `true` only when its stored
    /// `integrity.passed` is true, no re-verification check failed, and every
    /// required check (`ReportReverifier.requiredCheckNames`) was verifiable
    /// and passed. A stored `integrity.passed` alone never makes a report
    /// trustworthy, and a report that could not be fully verified (for
    /// example because no plan was available) is not trustworthy either; see
    /// `trustStatus` for which of the two it is.
    public let trustworthy: Bool

    /// Why `trustworthy` is what it is. `mismatch` means the report
    /// contradicts itself or its plan; `notFullyVerified` means nothing was
    /// found wrong but a required check could not be verified
    /// (`verification.unverifiedRequiredChecks` names them). A consumer must
    /// treat anything other than `trustworthy` as not trusted.
    public enum Status: String, Codable, Sendable, Equatable {
        case trustworthy
        case mismatch
        case notFullyVerified
    }

    public let trustStatus: Status

    public struct IntegritySection: Codable, Sendable, Equatable {
        public let passed: Bool
        public let violationCount: Int
        /// Tallied by `IntegrityViolation.Kind.rawValue` — every kind this
        /// run's violations actually used, sorted for a deterministic
        /// report. Empty when `passed` is `true`.
        public let violationsByKind: [String: Int]
        public let violations: [IntegrityViolation]

        public init(passed: Bool, violationCount: Int, violationsByKind: [String: Int], violations: [IntegrityViolation]) {
            self.passed = passed
            self.violationCount = violationCount
            self.violationsByKind = violationsByKind
            self.violations = violations
        }
    }

    public let integrity: IntegritySection

    /// What re-verifying the report from its own contents found.
    ///
    /// `failCount > 0` means at least one stored claim does not re-derive, and
    /// the report is not trustworthy. `notVerifiableCount` counts claims a
    /// report alone cannot prove or refute; they are never counted in
    /// `passCount`. Without a plan (`planSupplied == false`) the plan-dependent
    /// checks, including the integrity recompute, are among them.
    public struct VerificationSection: Codable, Sendable, Equatable {
        public let planSupplied: Bool
        /// `true` only when an evidence archive was supplied and read and at
        /// least one result was re-judged from its raw observations. A report
        /// alone never contains them, so it is `false` without an archive.
        public let tierBPerformed: Bool
        /// What Tier B covered; present exactly when `tierBPerformed`.
        public let tierB: TierBSummary?
        /// Where the plan came from: handed in (`supplied`), found by the plan
        /// ID the report names (`discovered`), or not available (`none`).
        public enum PlanSource: String, Codable, Sendable, Equatable {
            case supplied
            case discovered
            case none
        }

        public let planSource: PlanSource
        /// The plan file read, when `planSource` is `supplied` or `discovered`.
        public let planPath: String?
        /// Required checks (`ReportReverifier.requiredCheckNames`) that did not
        /// pass: failed, not verifiable or missing. Non-empty means the report
        /// is not fully verified and `trustworthy` is `false`.
        public let unverifiedRequiredChecks: [String]
        /// `true` only when no check failed.
        public let passed: Bool
        /// `true` only when every check passed: none failed and none is not
        /// verifiable. `passed && !complete` is a PARTIAL verification.
        public let complete: Bool
        public let passCount: Int
        public let failCount: Int
        public let notVerifiableCount: Int
        public let checks: [ReverificationCheck]

        public init(
            planSupplied: Bool, reverification: ReportReverification,
            planSource: PlanSource? = nil, planPath: String? = nil
        ) {
            self.planSupplied = planSupplied
            self.planSource = planSource ?? (planSupplied ? .supplied : .none)
            self.planPath = planPath
            unverifiedRequiredChecks = reverification.unverifiedRequiredChecks
            tierBPerformed = reverification.tierBPerformed
            tierB = reverification.tierB
            passed = reverification.passed
            complete = reverification.complete
            passCount = reverification.passCount
            failCount = reverification.failureCount
            notVerifiableCount = reverification.notVerifiableCount
            checks = reverification.checks
        }
    }

    /// Present when the report was re-verified (`build(from:verifyingAgainst:)`);
    /// `nil` for a plain `build(from:)`, which only reads stored facts.
    public let verification: VerificationSection?

    /// Total mutations with real source-application evidence vs. without —
    /// `withEvidence` is `report.integrity.sourceApplied`, reused verbatim
    /// (that field already IS this count; see `IntegrityChecker.check`).
    public struct SourceApplicationSection: Codable, Sendable, Equatable {
        public let withEvidence: Int
        public let withoutEvidence: Int
        public let total: Int

        public init(withEvidence: Int, withoutEvidence: Int, total: Int) {
            self.withEvidence = withEvidence
            self.withoutEvidence = withoutEvidence
            self.total = total
        }
    }

    public let sourceApplication: SourceApplicationSection

    /// Every reported mutant's own `evidence.applicationEvidence`, broken
    /// down by what it actually is — not by what it proves for schemata
    /// mutants (see this type's own doc comment for why).
    public struct ActivationEvidenceSection: Codable, Sendable, Equatable {
        /// Isolated-mode evidence whose two hashes actually differ —
        /// `ActivationEvidence.provesActivation == true`.
        public let isolatedProven: Int
        /// Isolated-mode evidence whose mutant binary hashed identical to
        /// baseline — proof the mutation never reached the running code,
        /// not proof of anything positive.
        public let isolatedNotProven: Int
        /// Schemata-mode evidence present. Already verified (or the result
        /// would not have reached a scorable outcome) — see this type's own
        /// doc comment.
        public let schemataPresent: Int
        /// No application evidence recorded at all — e.g. a build failure
        /// before any binary existed to compare, or an outcome that never
        /// reaches this stage (`.skipped`, `.notApplied`).
        public let noEvidence: Int

        public init(isolatedProven: Int, isolatedNotProven: Int, schemataPresent: Int, noEvidence: Int) {
            self.isolatedProven = isolatedProven
            self.isolatedNotProven = isolatedNotProven
            self.schemataPresent = schemataPresent
            self.noEvidence = noEvidence
        }
    }

    public let activationEvidence: ActivationEvidenceSection

    /// Count of `IntegrityViolation.Kind.phantomMutant` violations — the
    /// exact same definition `IntegrityChecker.check` and
    /// `PhantomMutantTests` already use (a `.notApplied` result: the anchor
    /// did not match, so the mutation was never applied to source). Should
    /// be `0` in a healthy report; a nonzero count already means
    /// `trustworthy == false`, since every `phantomMutant` violation is
    /// also counted in `integrity.violationCount`.
    public let phantomMutantCount: Int

    /// One manifestation's confirmation story — how many mutants reached
    /// this outcome, and how many of those carry the structured, independent-
    /// rebuild confirmation evidence (`CrashConfirmation`/`TimeoutConfirmation`)
    /// this codebase attaches when `confirmCrashKills`/`confirmTimedOutMutants`
    /// was on. A `killedByCrash`/`verifiedTimeout` result with no such
    /// evidence was still legitimately proven (see `ADR-0006`) — it was
    /// simply never asked to reproduce a second time, because that run's
    /// configuration did not request it.
    public struct ConfirmationSection: Codable, Sendable, Equatable {
        public let killed: Int
        public let confirmed: Int
        public let unconfirmed: Int

        public init(killed: Int, confirmed: Int, unconfirmed: Int) {
            self.killed = killed
            self.confirmed = confirmed
            self.unconfirmed = unconfirmed
        }
    }

    public let crashKills: ConfirmationSection
    public let timeoutKills: ConfirmationSection

    /// Honest, deliberate limitation, always present so this never silently
    /// reads as "zero unconfirmed assertion kills": `retestKilledMutants`'s
    /// own same-artifact confirmation retest (`MutationVerdictVerifier
    /// .confirmKill`) decides whether a `killedByAssertion` verdict is
    /// trusted, but — unlike the crash/timeout paths — its result is folded
    /// only into the verdict's `diagnosis` prose, never into a structured
    /// field on `MutationEvidence` the way `crashConfirmation`/
    /// `timeoutConfirmation` are. There is today no `killConfirmation`
    /// field to read a confirmed-vs-unconfirmed count back from — see
    /// `MutationEvidence`'s field list. Reporting a fabricated count here
    /// instead of this note would be exactly the kind of false "verified"
    /// claim this tool's own trust philosophy refuses to make.
    public let assertionKillConfirmationLimitation: String

    /// Assertion-kill confirmation counts, present only when at least one
    /// result in the report carries a structured
    /// `MutationEvidence.assertionKillConfirmation`. `nil` means "no result
    /// carries one" (an older report, or a run with retest off), never "all
    /// confirmed": `unconfirmed` counts every assertion kill without a
    /// `.confirmed` record, including those with none at all.
    public let assertionKills: ConfirmationSection?

    /// Which tests credited the assertion kills (selection, naming, batch or
    /// standalone attribution) and how many results went through a cascade of
    /// confirmations. `nil` when the report has neither.
    public let killEvidence: KillEvidenceSection?

    /// `report.score`, verbatim, but only when `integrity.passed` is `true`
    /// — `TrustReport.build(from:)` itself withholds it otherwise, rather
    /// than trusting `report.score` to already be `nil`. `RunReport.init`
    /// enforces that same rule when a report is freshly produced, but a
    /// *decoded* `RunReport` (the only path `mutantkit trust` actually
    /// takes) skips that initializer entirely and just deserializes
    /// whatever `score` value the JSON on disk happens to carry — so a
    /// hand-edited or corrupted `report.json` with real integrity
    /// violations and a populated `score` must not be allowed to print a
    /// score summary here. Never recomputed from `results`, either way.
    public let score: MutationScore?

    /// `report.operationalIssues.count` — best-effort infrastructure
    /// problems that never affected score or integrity, included because a
    /// reader auditing trust may still want to know a checkpoint write
    /// failed or a schemata chunk fell back, even though neither one
    /// weakens this report's own proof.
    public let operationalIssueCount: Int

    public init(
        planID: String, mutationCount: Int, trustworthy: Bool, integrity: IntegritySection,
        sourceApplication: SourceApplicationSection, activationEvidence: ActivationEvidenceSection,
        phantomMutantCount: Int, crashKills: ConfirmationSection, timeoutKills: ConfirmationSection,
        assertionKillConfirmationLimitation: String, score: MutationScore?, operationalIssueCount: Int,
        assertionKills: ConfirmationSection? = nil, verification: VerificationSection? = nil,
        killEvidence: KillEvidenceSection? = nil, trustStatus: Status? = nil
    ) {
        self.trustStatus = trustStatus ?? (trustworthy ? .trustworthy : .mismatch)
        self.killEvidence = killEvidence
        schemaVersion = SchemaVersion.trustReport
        self.planID = planID
        self.mutationCount = mutationCount
        self.trustworthy = trustworthy
        self.integrity = integrity
        self.sourceApplication = sourceApplication
        self.activationEvidence = activationEvidence
        self.phantomMutantCount = phantomMutantCount
        self.crashKills = crashKills
        self.timeoutKills = timeoutKills
        self.assertionKillConfirmationLimitation = assertionKillConfirmationLimitation
        self.score = score
        self.operationalIssueCount = operationalIssueCount
        self.assertionKills = assertionKills
        self.verification = verification
    }

    /// Every field derived from `report` alone, nothing guessed and nothing
    /// re-verified. See this type's own doc comment for why each derivation is
    /// a tally over already-decided facts, never a fresh judgment. Because
    /// nothing was re-verified, a report whose stored integrity passed is
    /// `notFullyVerified`, never `trustworthy`.
    public static func build(from report: RunReport) -> TrustReport {
        build(from: report, verification: nil)
    }

    /// Like `build(from:)`, but first re-verifies `report` with
    /// `ReportReverifier` (the same checks `verify-run` runs, minus the
    /// source-anchor check, which needs a checkout), so the result no longer
    /// rests on the report's stored `integrity.passed` alone. `plan` may be
    /// `nil`; the plan-dependent checks are then `notVerifiable`.
    public static func build(
        from report: RunReport, verifyingAgainst plan: MutationPlan?, evidence: LoadedEvidenceArchive? = nil,
        planSource: VerificationSection.PlanSource? = nil, planPath: String? = nil,
        expectedPolicy: MutationVerdictVerifier.VerdictVerificationPolicy? = nil
    ) -> TrustReport {
        let reverification = ReportReverifier.reverify(
            report: report, plan: plan, evidence: evidence, expectedPolicy: expectedPolicy
        )
        let section = VerificationSection(
            planSupplied: plan != nil, reverification: reverification, planSource: planSource, planPath: planPath
        )
        return build(from: report, verification: section)
    }

    private static func build(from report: RunReport, verification: VerificationSection?) -> TrustReport {
        let status = trustStatus(integrityPassed: report.integrity.passed, verification: verification)
        let trustworthy = status == .trustworthy
        let integrity = report.integrity
        var violationsByKind: [String: Int] = [:]
        for violation in integrity.violations {
            violationsByKind[violation.kind.rawValue, default: 0] += 1
        }

        let sourceApplication = SourceApplicationSection(
            withEvidence: integrity.sourceApplied,
            withoutEvidence: report.results.count - integrity.sourceApplied,
            total: report.results.count
        )

        var isolatedProven = 0, isolatedNotProven = 0, schemataPresent = 0, noEvidence = 0
        for result in report.results {
            switch result.evidence?.applicationEvidence {
            case let .isolated(activation)?:
                if activation.provesActivation { isolatedProven += 1 } else { isolatedNotProven += 1 }
            case .schemata?:
                schemataPresent += 1
            case nil:
                noEvidence += 1
            }
        }

        func confirmationSection(
            outcome: MutationOutcome, confirmed: (MutationResult) -> Bool
        ) -> ConfirmationSection {
            let matching = report.results.filter { $0.outcome == outcome }
            let confirmedCount = matching.filter(confirmed).count
            return ConfirmationSection(killed: matching.count, confirmed: confirmedCount, unconfirmed: matching.count - confirmedCount)
        }

        let assertionKills = confirmationSection(outcome: .killedByAssertion) {
            // Confirmed means the retest reproduced the failure and the unmutated
            // build passed the same tests; a record without a control is not
            // confirmed, whatever its disposition says.
            $0.evidence?.assertionKillConfirmation.map { $0.disposition == .confirmed && $0.isControlled } ?? false
        }
        let recordedAssertionConfirmations = report.results.filter { $0.evidence?.assertionKillConfirmation != nil }.count
        let assertionLimitation: String
        if recordedAssertionConfirmations > 0 {
            assertionLimitation = """
            \(assertionKills.confirmed) of \(assertionKills.killed) assertion kills carry a structured confirmed \
            retest with a passing baseline control; the rest predate those fields or ran with retest off, so \
            an unconfirmed count here does not by itself say which.
            """
        } else {
            assertionLimitation = """
            retestKilledMutants' own assertion-kill confirmation detail is not present as a structured \
            field in report.json today, so this command cannot report a confirmed or unconfirmed count \
            for assertion kills — only for crash and timeout kills, whose confirmation evidence is structured.
            """
        }

        return TrustReport(
            planID: report.planID,
            mutationCount: report.results.count,
            trustworthy: trustworthy,
            integrity: IntegritySection(
                passed: integrity.passed, violationCount: integrity.violations.count,
                violationsByKind: violationsByKind, violations: integrity.violations
            ),
            sourceApplication: sourceApplication,
            activationEvidence: ActivationEvidenceSection(
                isolatedProven: isolatedProven, isolatedNotProven: isolatedNotProven,
                schemataPresent: schemataPresent, noEvidence: noEvidence
            ),
            phantomMutantCount: integrity.violations.count { $0.kind == .phantomMutant },
            crashKills: confirmationSection(outcome: .killedByCrash) { $0.evidence?.crashConfirmation?.crashedAgain == true },
            timeoutKills: confirmationSection(outcome: .verifiedTimeout) { $0.evidence?.timeoutConfirmation?.timedOutAgain == true },
            assertionKillConfirmationLimitation: assertionLimitation,
            // `report.score` is only carried through when integrity actually
            // passed — never trusted at face value, since a decoded
            // `RunReport` (unlike a freshly-built one) can hold a populated
            // `score` alongside real integrity violations. See this type's
            // own `score` doc comment.
            score: status == .mismatch ? nil : report.score,
            operationalIssueCount: report.operationalIssues.count,
            assertionKills: recordedAssertionConfirmations > 0 ? assertionKills : nil,
            verification: verification,
            killEvidence: killEvidenceSection(for: report.results),
            trustStatus: status
        )
    }
}
