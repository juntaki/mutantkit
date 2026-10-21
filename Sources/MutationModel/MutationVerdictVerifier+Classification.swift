extension MutationVerdictVerifier {
    // MARK: - Classification (ported from ResultClassifier/SchemataResultClassifier)

    /// `decidingRun` is whichever `TestRunResult` actually produced this
    /// classification — the primary run, or a confirmation's run once a
    /// confirmation changes the outcome. `proof(for:...)` reads its summary
    /// straight from here rather than a `testSummary` threaded in
    /// separately, so a confirmation that flips the final outcome (a
    /// batch-attributed timeout trusted as a kill, say) attaches the run
    /// that actually decided it, not the original timed-out run's summary.
    struct Classification {
        let outcome: MutationOutcome
        let diagnosis: String
        let decidingRun: TestRunResult?
        /// Structured record of a `.kill` confirmation's result. Carried to
        /// the proof's evidence only; it never influences `outcome`.
        var killConfirmation: AssertionKillConfirmation?
        /// Which tests credited an assertion kill; see
        /// `AssertionKillAttribution`. Carried to the proof's evidence only.
        var killAttribution: AssertionKillAttribution?
    }

    static func classify(
        run: TestRunResult,
        applicationEvidence: MutationApplicationEvidence?,
        coverage: CoverageObservation?
    ) -> Classification {
        switch run.status {
        case .failed:
            if let unproven = unprovenActivation(applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "The tests failed (\(run.diagnosis)), but \(unproven) — a failure cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: run
                )
            }
            return Classification(outcome: .killedByAssertion, diagnosis: killedByAssertionDiagnosis(run), decidingRun: run)

        case .crashed:
            if let unproven = unprovenActivation(applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "The test runner crashed (\(run.diagnosis)), but \(unproven) — a crash cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: run
                )
            }
            return Classification(
                outcome: .killedByCrash,
                diagnosis: "The mutant killed the test runner rather than failing an assertion: \(run.diagnosis)",
                decidingRun: run
            )

        case .timedOut:
            return Classification(
                outcome: .timedOut,
                diagnosis: "The mutant's tests did not finish within their limit, so the suite never got to judge it: \(run.diagnosis)",
                decidingRun: run
            )

        case .infrastructureFailure:
            return Classification(
                outcome: .infrastructureFailure, diagnosis: "The test run produced no verdict for this mutant: \(run.diagnosis)", decidingRun: run
            )

        case .passed:
            return classifyPassing(run: run, applicationEvidence: applicationEvidence, coverage: coverage)
        }
    }

    static func classifyPassing(
        run: TestRunResult,
        applicationEvidence: MutationApplicationEvidence?,
        coverage: CoverageObservation?
    ) -> Classification {
        let passed = run.summary.map { "All \($0.total) tests passed" } ?? "The tests passed"

        switch applicationEvidence {
        case let .schemata(observation)?:
            let chain = Result { try verifySchemataChain(observation) }
            if let coverage, !coverage.mutatedLineWasExecuted {
                if case .success = chain {
                    return Classification(
                        outcome: .infrastructureFailure,
                        diagnosis: """
                        \(passed), but \(coverage.source) reports the mutated code was never executed, \
                        while the verified chain proves the mutation was built, selected, and hit in this \
                        exact run — a genuine contradiction between coverage and runtime evidence, not \
                        something either signal alone can resolve.
                        """,
                        decidingRun: run
                    )
                }
                return Classification(
                    outcome: .noCoverage, diagnosis: "\(passed), but \(coverage.source) reports the mutated code was never executed.", decidingRun: run
                )
            }
            guard case .success = chain else {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(passed), but \(schemataChainDiagnosis(chain))",
                    decidingRun: run
                )
            }
            return Classification(
                outcome: .survived,
                diagnosis: "\(passed) with the mutation proven active and hit in this run, so nothing in the suite distinguishes this change from the original.",
                decidingRun: run
            )

        case .isolated, nil:
            if let coverage, !coverage.mutatedLineWasExecuted {
                return Classification(
                    outcome: .noCoverage, diagnosis: "\(passed), but \(coverage.source) reports the mutated code was never executed.", decidingRun: run
                )
            }
            guard case let .isolated(activation)? = applicationEvidence else {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(passed), but the build produced no product hash, so there is no proof the mutation reached the code under test; a passing suite is not evidence without it.",
                    decidingRun: run
                )
            }
            guard activation.provesActivation else {
                // A no-op canary that behaved as the hash says (the suite passed
                // on a product identical to the baseline's). Any other canary
                // outcome never reaches here: a failure or crash on an
                // "identical" product stays an infrastructure failure above.
                if case .buildProductIdenticalToBaseline = activation {
                    return Classification(
                        outcome: .notMaterialized,
                        diagnosis: "\(passed), on a build product identical to the baseline's: the mutation did not reach the product under test, so this says nothing about the suite.",
                        decidingRun: run
                    )
                }
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(passed), but the mutation's activation evidence is self-contradictory, so this result proves nothing.",
                    decidingRun: run
                )
            }
            return Classification(
                outcome: .survived,
                diagnosis: "\(passed) with the mutation active in the build product, so nothing in the suite distinguishes this change from the original.",
                decidingRun: run
            )
        }
    }

    static func unprovenActivation(_ applicationEvidence: MutationApplicationEvidence?) -> String? {
        switch applicationEvidence {
        case let .isolated(activation)?:
            if activation.provesActivation { return nil }
            return "the mutant's build product is identical to the baseline's, so the mutation never reached the code under test"
        case let .schemata(observation)?:
            let chain = Result { try verifySchemataChain(observation) }
            if case .success = chain { return nil }
            return schemataChainDiagnosis(chain)
        case nil:
            return "the build produced no product hash, so there is no proof the mutation reached the code under test"
        }
    }

    static func killedByAssertionDiagnosis(_ run: TestRunResult) -> String {
        guard let summary = run.summary else {
            return """
            A test assertion failed on this mutant, so it was caught. The runner reported no per-test breakdown, \
            so which test caught it is unknown.
            """
        }
        let caught = summary.failingTests.prefix(3).joined(separator: ", ")
        let base = "\(summary.failed) of \(summary.total) tests failed on this mutant"
        guard !caught.isEmpty else { return base + "." }
        let more = summary.failingTests.count > 3 ? " and \(summary.failingTests.count - 3) more" : ""
        return base + ", caught by \(caught)\(more)."
    }
}
