/// The only place a `VerifiedMutationRecord` is constructed, and — as of
/// The authoritative verdict pipeline — the only place a mutation's outcome is *decided*.
///
/// `verify(_:)` is a pure function from `MutationObservations` (what
/// actually happened) to a verdict: no caller pre-computes an outcome and
/// hands it in (the previous `RawMutationAttempt.candidateOutcome` design
/// PR A–D used is gone). The judgment rules themselves are a faithful port
/// of `ResultClassifier`/`SchemataResultClassifier` (deleted from
/// `MutationExecution` in this stage) — this stage relocates and
/// restructures *where* the rules run, not what they decide; the existing,
/// extensive isolated-mode test suite (crash/flaky/timeout confirmation,
/// wave early-kill, etc.) is what proves that relocation preserved
/// behavior.
///
/// *Whether* to gather a confirmation observation (a retest, an
/// independent rebuild) is still a runner-level orchestration decision —
/// actually running one requires executing a build/test adapter, which the
/// verifier (in `MutationModel`, with no I/O capability at all) cannot do.
/// That decision is made from `MutationObservations.test`'s own raw
/// `TestRunResult.status`, never from an outcome this verifier already
/// decided — the runner asks "did this fail" and "is retesting configured
/// on", not "did the verifier call this a kill".

/// What confirmation (if any) a run's own policy requires for one
/// mutation's primary observation — see `MutationVerdictVerifier
/// .confirmationRequirement(for:policy:)`, the sole place this is decided.
public enum ConfirmationRequirement: Sendable, Equatable {
    case none
    case retestKilledMutant
    case confirmCrash
    case confirmTimeout
}

public enum MutationVerdictVerifier {
    /// Bumped whenever the rules below change in a way that could flip an
    /// outcome for previously-seen input. The verified-verdict cache gate's cache-
    /// invalidation gate (`VerifiedVerdictReceipt`) reads this to auto-miss
    /// stale entries. Bumped to 2 for the authoritative verdict pipeline: the verifier now
    /// derives outcomes itself instead of reproducing a caller-supplied
    /// one, a real change to what "verified" means even though the
    /// underlying classification rules were ported, not rewritten. Bumped
    /// to 12: `verifySchemataChain` now groups STARTUP/HIT by process
    /// instead of requiring exactly one raw event — the identical
    /// `MutationObservations` that used to classify as
    /// `.infrastructureFailure` under a legitimate multi-process test run
    /// can now classify as `.survived`/`.killedByAssertion`, so a
    /// pre-bump cached verdict must never be reused as-is. Bumped to 13: a
    /// `killedByAssertion` is now credited only when its observation records
    /// the tests the run was narrowed to and every named failing test lies
    /// inside that selection — the identical `MutationObservations` (including
    /// every older cache or checkpoint entry, none of which recorded the
    /// execution) that used to classify as `.killedByAssertion` now classify as
    /// `.infrastructureFailure`, so a pre-bump cached kill must never be
    /// reused as-is. Bumped to 14: an assertion kill whose retest reproduced the
    /// failure is now confirmed only when the unmutated build passed the same
    /// tests (a baseline control); the identical `MutationObservations` (every
    /// older entry, none of which recorded a control) that used to classify as
    /// `.killedByAssertion` now classify as `.infrastructureFailure`, so a
    /// pre-bump cached kill must never be reused as-is. Bumped to 15: whether a
    /// failing test lies inside the run's selection is now decided from the full
    /// identifier (target, suites, type, method and parameter list) instead of
    /// its last two path components, so the identical `MutationObservations`
    /// whose failing test only collided with a selected one (another target or
    /// enclosing suite, another overload or parameterized variant) that used to
    /// classify as `.killedByAssertion` now classify as `.infrastructureFailure`,
    /// so a pre-bump cached kill must never be reused as-is. Bumped to 16: a
    /// selection recorded as `method()()` (a Swift Testing test selected through
    /// SwiftPM) is now read as `method()`, so the identical `MutationObservations`
    /// whose failing test was that very test, which used to classify as
    /// `.infrastructureFailure` (outside the selection), now classify as
    /// `.killedByAssertion`; a pre-bump cached verdict must never be reused as-is.
    /// Bumped to 17: an applied edit whose build succeeded to a product identical
    /// to the baseline's (the tests skipped, or a no-op canary that passed) is now
    /// `.notMaterialized` instead of `.infrastructureFailure`. Not a trust
    /// relaxation — the same observations get the classification their proof
    /// supports, so a pre-bump cached verdict must never be reused as-is. Bumped to
    /// 18: a build failure recorded as a confirmed compiler crash (the compiler crashed
    /// on the mutant and again in an independent rebuild) is `.unviable`; no older
    /// observation carries that kind, so this only keeps the version honest about the
    /// rules that judged a cached verdict.
    public static let currentVersion = 18

    /// `verify(_:)` alone cannot tell a primary kill/crash that skipped its
    /// confirmation because the run's own configuration never enabled one
    /// apart from one whose `confirmations` were simply stripped out of an
    /// untrusted `MutationObservations` envelope — both look identical from
    /// the observations alone. This policy is that missing context: the
    /// same `Configuration.execution.retestKilledMutants`/
    /// `confirmCrashKills`/`confirmTimedOutMutants` flags the run itself
    /// was actually gated on, supplied by the caller so the verifier can
    /// require the confirmation those flags promise rather than trust
    /// whatever `confirmations` an untrusted envelope happens to contain.
    public struct VerdictVerificationPolicy: Codable, Sendable, Hashable {
        public let retestKilledMutants: Bool
        public let confirmCrashKills: Bool
        public let confirmTimedOutMutants: Bool

        public init(retestKilledMutants: Bool, confirmCrashKills: Bool, confirmTimedOutMutants: Bool) {
            self.retestKilledMutants = retestKilledMutants
            self.confirmCrashKills = confirmCrashKills
            self.confirmTimedOutMutants = confirmTimedOutMutants
        }

        /// The one canonical way to derive a run's actual confirmation
        /// policy from its resolved `ExecutionSettings` — previously
        /// reimplemented identically (same three fields, same three flags)
        /// in `MutationEvidenceAssembler.verificationPolicy`,
        /// `SchemataRunOrchestration.run()`'s local `policy`, and
        /// `RunCommand+ExecutionContext.prepareRunExecutionContext`'s local
        /// `verificationPolicy`. Every call site above passed the exact same
        /// three booleans from the exact same `Configuration.execution`
        /// fields, so folding them into this one factory changes no
        /// computed value — pure duplication removal.
        public init(_ execution: ExecutionSettings) {
            self.init(
                retestKilledMutants: execution.retestKilledMutants,
                confirmCrashKills: execution.confirmCrashKills,
                confirmTimedOutMutants: execution.confirmTimedOutMutants
            )
        }

        /// Requires nothing — the pre-policy behavior. `verify(_:policy:)`
        /// takes no default, so this is never reached by omission; the
        /// right explicit choice for a test fixture that isn't exercising
        /// confirmation-policy enforcement. A real runner/cache/checkpoint
        /// call site should always pass the policy actually in effect for
        /// the run instead.
        public static let permissive = VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false
        )
    }

    public static func verify(_ observations: MutationObservations, policy: VerdictVerificationPolicy) -> VerifiedMutationRecord {
        let ref = observations.plannedMutation
        let proof = deriveProof(observations, ref: ref, policy: policy)
        return VerifiedMutationRecord(mutationRef: ref, proof: proof, verificationVersion: currentVersion)
    }

    /// What confirmation (if any) `policy` requires for `observations`,
    /// judged by classifying its primary observation exactly as `verify`
    /// itself would — before any confirmation is folded in. The single
    /// source of truth both `MutationRunner` and `SchemataMutationRunner`
    /// ask instead of each independently re-deriving "does this need a
    /// retest" from `policy`'s flags and the raw run status; a caller that
    /// diverged from this would risk gathering a confirmation `verify`
    /// would not actually credit, or skipping one it would require.
    ///
    /// Assumes `observations.confirmations` is empty — this answers "is a
    /// first confirmation needed", not "is another one needed after the
    /// first came back inconclusive" (a cascade, which stays a runner-level
    /// decision from that confirmation's own resulting status, unchanged).
    public static func confirmationRequirement(
        for observations: MutationObservations, policy: VerdictVerificationPolicy
    ) -> ConfirmationRequirement {
        guard
            case let .applied(evidence)? = observations.sourceApplication, evidence.provesSourceApplication,
            let build = observations.build, case let .succeeded(buildProductHash, _) = build.outcome,
            let test = observations.test,
            executionEvidenceProblem(
                sourceEvidence: evidence, buildProductHash: buildProductHash, testEvidence: test.applicationEvidence
            ) == nil
        else {
            return .none
        }

        let classification = classify(run: test.run, applicationEvidence: test.applicationEvidence, coverage: observations.coverage)
        switch classification.outcome {
        case .killedByAssertion where policy.retestKilledMutants:
            return .retestKilledMutant
        case .killedByCrash where policy.confirmCrashKills || test.run.crashProvenance != nil:
            return .confirmCrash
        case .timedOut where policy.confirmTimedOutMutants:
            return .confirmTimeout
        default:
            return .none
        }
    }

    /// Why a schemata attempt should be re-run in isolated mode instead of
    /// being scored from its own (unproven) schemata result — see
    /// `MutationVerdictVerifier.schemataIsolatedFallbackReason(for:)`, the
    /// sole place this is decided.
    ///
    /// Deliberately narrow: only the two failure shapes a passing test run
    /// genuinely cannot distinguish from "this mutation was simply never
    /// executed" (see that function's own doc comment for why the scope
    /// stops there). Every other `SchemataChainError` case — a duplicate
    /// STARTUP/HIT, an orphan HIT, a missing/ambiguous build receipt — is a
    /// real inconsistency, not a proof-of-execution gap, and stays
    /// `.infrastructureFailure` exactly as before.
    public enum SchemataIsolatedFallbackReason: String, Codable, Sendable, Hashable {
        case noStartup
        case noHit
    }

    /// Whether `observations`' own schemata attempt lacks *any* runtime
    /// activation proof (no STARTUP, or a STARTUP with no HIT) — the same
    /// shape a genuinely uncovered/never-executed mutation produces, which
    /// no isolated-mode equivalent proof exists to contradict. `nil` means
    /// no fallback is warranted: either the schemata chain already proved
    /// itself (`.survived`/`.killedByAssertion` will follow from `verify`
    /// unchanged), or the failure is a real inconsistency (a duplicate
    /// event, an orphan HIT, an ambiguous/missing build receipt) that
    /// isolated mode re-running the mutation would not explain away
    /// either — those stay `.infrastructureFailure`.
    ///
    /// Reuses `verifySchemataChain` itself — never a second, independent
    /// interpretation of the raw transcript — so this can never drift from
    /// what `verify(_:policy:)` would actually classify.
    ///
    /// Scoped to a *passing* test run only (the first step of the no-HIT ->
    /// isolated-fallback design): a `.failed`/`.crashed`/`.timedOut` run
    /// with no HIT is a materially different question (was the failure
    /// even caused by this mutation at all?) that a future phase can
    /// address on its own evidence, not folded in here by widening this
    /// scope quietly.
    public static func schemataIsolatedFallbackReason(for observations: MutationObservations) -> SchemataIsolatedFallbackReason? {
        guard let test = observations.test, test.run.status == .passed else { return nil }
        guard case let .schemata(observation)? = test.applicationEvidence else { return nil }
        do {
            _ = try verifySchemataChain(observation)
            return nil
        } catch SchemataChainError.noStartup {
            return .noStartup
        } catch SchemataChainError.noHit {
            return .noHit
        } catch {
            return nil
        }
    }

    // MARK: - Source application

    private static func deriveProof(
        _ obs: MutationObservations, ref: PlannedMutationRef, policy: VerdictVerificationPolicy
    ) -> VerdictProof {
        guard let sourceApplication = obs.sourceApplication else {
            return excluded(
                ref, outcome: .infrastructureFailure,
                diagnosis: obs.infrastructureFailureDiagnosis ?? "no observation reached even source application"
            )
        }

        switch sourceApplication {
        case let .notApplied(diagnosis):
            return excluded(ref, outcome: .notApplied, diagnosis: diagnosis)
        case let .applied(recordedEvidence):
            // The verifier is the only author of the kill-confirmation,
            // kill-attribution and confirmation-chain records: whatever a
            // stored observation carries is discarded, so a hand-edited
            // entry cannot smuggle in a "confirmed" or "within selection"
            // record.
            let evidence = recordedEvidence.strippingVerifierAuthoredRecords()
            guard evidence.provesSourceApplication else {
                return excluded(
                    ref, outcome: .infrastructureFailure,
                    diagnosis: """
                    Source application was recorded, but the before/after hashes and source diff do not prove that an \
                    edit occurred.
                    """,
                    evidence: evidence
                )
            }
            return deriveAfterApplication(obs, ref: ref, evidence: evidence, policy: policy)
        }
    }

    // MARK: - Build

    private static func deriveAfterApplication(
        _ obs: MutationObservations, ref: PlannedMutationRef, evidence: MutationEvidence, policy: VerdictVerificationPolicy
    ) -> VerdictProof {
        // Coverage fast path: a baseline coverage map that knows this line
        // was never executed lets us classify without building at all.
        if obs.build == nil, let coverage = obs.coverage, !coverage.mutatedLineWasExecuted {
            return .noCoverage(NoCoverageProof(
                mutationRef: ref, sourceApplication: evidence, coverageSource: coverage.source,
                diagnosis: "The baseline suite never executed this line, so no test could have distinguished the mutation from the original. \(coverage.source) reports the mutated code was never reached."
            ))
        }

        guard let build = obs.build else {
            return excluded(
                ref, outcome: .infrastructureFailure,
                diagnosis: obs.infrastructureFailureDiagnosis ?? "the mutation was applied but no build was ever attempted"
            )
        }

        switch build.outcome {
        case let .failed(kind, diagnosis, _):
            switch kind {
            case .compilationError:
                return .unviable(BuildFailureProof(
                    mutationRef: ref,
                    diagnosis: "The mutant does not compile, so there was nothing to test: \(diagnosis)",
                    evidence: evidence
                ))
            case .confirmedCompilerCrash:
                return .unviable(BuildFailureProof(
                    mutationRef: ref,
                    diagnosis: "The mutant crashes the compiler (reproduced in an independent rebuild), so there was nothing to test: \(diagnosis)",
                    evidence: evidence
                ))
            case .infrastructure:
                return excluded(
                    ref, outcome: .infrastructureFailure,
                    diagnosis: "The build failed for reasons unrelated to the mutation: \(diagnosis)", evidence: evidence
                )
            case .timedOut:
                return excluded(
                    ref, outcome: .timedOut, diagnosis: "The mutant's build exceeded its time limit: \(diagnosis)", evidence: evidence
                )
            }
        case let .infrastructureFailure(diagnosis):
            return excluded(ref, outcome: .infrastructureFailure, diagnosis: diagnosis, evidence: evidence)
        case let .timedOut(diagnosis):
            return excluded(ref, outcome: .timedOut, diagnosis: diagnosis, evidence: evidence)
        case let .succeeded(buildProductHash, _):
            return deriveAfterBuild(obs, ref: ref, evidence: evidence, buildProductHash: buildProductHash, policy: policy)
        }
    }

    // MARK: - Test

    private static func deriveAfterBuild(
        _ obs: MutationObservations, ref: PlannedMutationRef, evidence: MutationEvidence, buildProductHash: String?,
        policy: VerdictVerificationPolicy
    ) -> VerdictProof {
        // The edit was applied, the build succeeded and its product is the
        // baseline's: the tests were rightly not run (see `MutationRunner.prepare`).
        // This is a complete observation, not a missing one. The hash the
        // evidence names must be the one actually observed, or the claim is
        // not credited.
        if obs.test == nil, case let .isolated(.buildProductIdenticalToBaseline(hash))? = evidence.applicationEvidence,
           !hash.isEmpty, hash == buildProductHash {
            return excluded(
                ref, outcome: .notMaterialized,
                diagnosis: """
                The edit was applied and the build succeeded, but the mutant's build product is identical to the \
                baseline's, so the mutation did not reach the product under test. Nothing ran against a mutation, \
                so this says nothing about the test suite.
                """,
                evidence: evidence
            )
        }

        guard let test = obs.test else {
            return excluded(
                ref, outcome: .infrastructureFailure,
                diagnosis: obs.infrastructureFailureDiagnosis ?? "the build succeeded but no test observation was recorded",
                evidence: evidence
            )
        }

        let problem = executionEvidenceProblem(
            sourceEvidence: evidence, buildProductHash: buildProductHash, testEvidence: test.applicationEvidence
        )
        if let problem {
            return excluded(ref, outcome: .infrastructureFailure, diagnosis: problem, evidence: evidence)
        }

        var (classification, chain) = foldConfirmations(
            classify(run: test.run, applicationEvidence: test.applicationEvidence, coverage: obs.coverage),
            confirmations: obs.confirmations, primaryApplicationEvidence: test.applicationEvidence
        )

        if let problem = missingRequiredConfirmationProblem(
            classification, confirmations: obs.confirmations, policy: policy,
            crashNeedsConfirmation: test.run.crashProvenance != nil
        ) {
            classification = Classification(outcome: .infrastructureFailure, diagnosis: problem, decidingRun: classification.decidingRun)
        }

        classification = applyingKillAttribution(classification, execution: test.execution)

        return proof(for: classification, ref: ref, evidence: evidence, confirmationChain: chain, coverageSource: obs.coverage?.source)
    }

    /// `verify(_:)` sees only `MutationObservations`, not the run's own
    /// `Configuration.execution.retestKilledMutants`/`confirmCrashKills`
    /// flags — an untrusted envelope whose `confirmations` were simply
    /// stripped out looks identical to one where the run's own config never
    /// required a confirmation in the first place. `policy` closes that:
    /// a final `.killedByAssertion`/`.killedByCrash` reached while its
    /// policy flag is on must actually carry the confirmation of the
    /// matching kind the real run would have gathered, or it is not
    /// trusted. `.verifiedTimeout` needs no equivalent check — it is only
    /// ever *produced* by folding a `.timeout` confirmation in the first
    /// place (see `confirmTimeout`), so one is structurally guaranteed
    /// whenever this outcome is reached at all.
    private static func missingRequiredConfirmationProblem(
        _ classification: Classification, confirmations: [ConfirmationObservation], policy: VerdictVerificationPolicy,
        crashNeedsConfirmation: Bool = false
    ) -> String? {
        switch classification.outcome {
        case .killedByAssertion where policy.retestKilledMutants:
            guard confirmations.contains(where: { $0.kind == .kill }) else {
                return """
                This run's configuration requires a confirming retest for an assertion kill, but no .kill \
                confirmation was recorded.
                """
            }
        case .killedByCrash where policy.confirmCrashKills || crashNeedsConfirmation:
            guard confirmations.contains(where: { $0.kind == .crash }) else {
                return """
                This run's configuration requires a confirming rebuild for a crash kill, but no .crash \
                confirmation was recorded.
                """
            }
        default:
            break
        }
        return nil
    }

    /// `MutationEvidence.applicationEvidence` (the copy attached to the
    /// final proof) and `SingleTestObservation.applicationEvidence` (the
    /// copy the verifier actually classifies from) are independent `Codable`
    /// fields — the runner always constructs them from the same value, but
    /// nothing enforces that once `MutationObservations` round-trips
    /// through an untrusted cache/checkpoint envelope. Without this check,
    /// an edited entry could carry forged, proven-looking activation
    /// evidence on the test side while the evidence actually attached to
    /// the resulting proof stays whatever (even hollow) evidence sits on
    /// the source-application side — or vice versa. Also catches activation
    /// evidence whose own embedded hash disagrees with the build actually
    /// observed, which an edit could otherwise keep internally consistent
    /// between the two copies while still not matching reality.
    private static func executionEvidenceProblem(
        sourceEvidence: MutationEvidence, buildProductHash: String?, testEvidence: MutationApplicationEvidence?
    ) -> String? {
        guard sourceEvidence.applicationEvidence == testEvidence else {
            return """
            Source evidence and the test observation carry different activation evidence — this observation is \
            inconsistent and cannot be trusted.
            """
        }
        guard sourceEvidence.buildProductHash == buildProductHash else {
            return """
            The build product hash recorded in source evidence does not match the build observation — this \
            observation is inconsistent and cannot be trusted.
            """
        }

        if case let .isolated(activation)? = testEvidence {
            return isolatedActivationBuildProblem(activation, buildProductHash: buildProductHash)
        }

        return nil
    }

    /// Whether `activation`'s own embedded hash(es) actually match
    /// `buildProductHash` — an independently-observed build's product hash,
    /// never a value `activation` itself supplies. Shared between the
    /// primary path (`executionEvidenceProblem`, against
    /// `BuildObservation`'s hash) and timeout confirmation (against
    /// `ConfirmationObservation.confirmingBuildProductHash`) — both are the
    /// same question: does this self-reported activation evidence actually
    /// correspond to a build that was observed to happen, or could it name
    /// hashes that never came from any real build at all.
    static func isolatedActivationBuildProblem(_ activation: ActivationEvidence, buildProductHash: String?) -> String? {
        switch activation {
        case let .buildProductDiffersFromBaseline(mutantHash, _):
            guard mutantHash == buildProductHash else {
                return """
                The activation evidence names a mutant product hash different from the observed build product — \
                this observation is inconsistent and cannot be trusted.
                """
            }
        case let .buildProductIdenticalToBaseline(hash):
            guard hash == buildProductHash else {
                return """
                The identical-product activation evidence does not match the observed build product — this \
                observation is inconsistent and cannot be trusted.
                """
            }
        }
        return nil
    }
}
