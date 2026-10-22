import Foundation
import MutationModel
import SwiftFrontend

/// Everything `MutationRunner.establishConfirmationSandbox(_:startedAt:)`
/// needs, bundled so that call stays within swiftlint's parameter-count
/// limit — see that method's own doc comment for what it does with these.
struct ConfirmationSandboxRequest {
    let point: MutationPoint
    let applied: AppliedMutation
    let artifact: BuildArtifact
    let activation: ActivationEvidence?
    let coverage: CoverageObservation?
    let buildDurationSeconds: Double
}

extension MutationRunner {
    /// A mutant that finished everything up through its build and is ready
    /// for a test run — shared shape between the per-mutant path and
    /// `evaluateInBatches`.
    ///
    /// Extracted from this type: `internal` (not `fileprivate`) because
    /// `MutationConfirmationCoordinator`, in its own file, takes this as a
    /// parameter to `confirmKillIfNeeded`.
    struct PreparedMutant: Sendable {
        let point: MutationPoint
        /// Where this mutant is tested, and what destroying it removes.
        let workspace: MutantWorkspace
        var sandbox: URL {
            workspace.url
        }

        let applied: AppliedMutation
        let artifact: BuildArtifact
        let activation: ActivationEvidence?
        let observation: CoverageObservation?
        let selectedTests: Set<TestIdentifier>?
        let startedAt: Date
        /// Every `PreparedMutant` by construction came from a successful
        /// `build.buildMutant` call, so this is never `nil`.
        let buildDurationSeconds: Double
        /// F3 zero-base review, verdict-contamination audit: an independent
        /// clone of this mutant's own build products, established by
        /// `prepare(_:in:baseline:startedAt:)` immediately after the build
        /// succeeds — strictly *before* the primary test run below ever
        /// starts, and therefore before any `ProcessSupervisor`-spawned
        /// process from that primary run, escaped or not, has ever had any
        /// chance to write into it. `confirmKill` uses this instead of
        /// `sandbox` — see that function's own doc comment for the actual
        /// threat this closes. `nil` only when
        /// `Configuration.execution.retestKilledMutants` is off (no
        /// confirmation retest will ever be attempted, so nothing needs
        /// isolating) or the eager clone itself failed (`prepare`'s own
        /// `.finished(.infrastructureFailure)` short-circuit in that case —
        /// see there).
        let confirmationSandbox: URL?

        /// A copy narrowed to exactly one test — used when a wave's
        /// detection came from a single covering test, so a confirmation
        /// rerun (`retestKilledMutants`/`confirmCrashKills`/
        /// `confirmTimedOutMutants`) reproduces that same witness instead of
        /// the mutant's whole original covering-test set.
        func narrowed(to test: TestIdentifier) -> PreparedMutant {
            PreparedMutant(
                point: point, workspace: workspace, applied: applied, artifact: artifact,
                activation: activation, observation: observation, selectedTests: [test],
                startedAt: startedAt, buildDurationSeconds: buildDurationSeconds,
                confirmationSandbox: confirmationSandbox
            )
        }
    }

    enum PrepareOutcome {
        case finished(MutationResult)
        case readyToTest(PreparedMutant)
    }

    /// Evaluates one mutation. Never throws: every planned mutation owes the
    /// integrity check a result, and a thrown error would silently become a
    /// missing one.
    func evaluate(_ point: MutationPoint, baseline: BaselineContext) async -> MutationResult {
        let started = Date()

        let sandbox: Sandbox
        do {
            sandbox = try await workspaces.createSandbox(id: point.id.rawValue)
        } catch {
            return await evidenceAssembler.infrastructureFailureResult(
                point: point,
                diagnosis: "No sandbox could be created for this mutant: \(error)",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        let result = await evaluate(point, in: sandbox, baseline: baseline, startedAt: started)
        try? await workspaces.destroySandbox(sandbox)
        return result
    }

    func evaluate(
        _ point: MutationPoint,
        in sandbox: Sandbox,
        baseline: BaselineContext,
        startedAt: Date
    ) async -> MutationResult {
        switch await prepare(point, in: sandbox, baseline: baseline, startedAt: startedAt) {
        case let .finished(result):
            return result
        case let .readyToTest(prepared):
            let testStarted = Date()
            let run: TestRunResult
            do {
                run = try await confirmationCoordinator.runMutantTests(
                    point,
                    artifact: prepared.artifact,
                    in: sandbox.workspaceRoot,
                    timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: prepared.selectedTests),
                    selectedTests: prepared.selectedTests
                )
            } catch {
                return await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "The mutant's tests could not be run: \(error)",
                    evidence: evidenceAssembler.evidence(
                        prepared.applied, artifact: prepared.artifact, activation: prepared.activation
                    ),
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    buildDurationSeconds: prepared.buildDurationSeconds,
                    testDurationSeconds: Date().timeIntervalSince(testStarted)
                )
            }
            let testDurationSeconds = Date().timeIntervalSince(testStarted)
            return await finishAfterTest(
                prepared, baseline: baseline, run: run, attribution: .standalone, testDurationSeconds: testDurationSeconds
            )
        }
    }

    /// One mutant, up through the build — everything about its evaluation
    /// that does not need a test run. Shared by the per-mutant path above
    /// and `evaluateInBatches`, so a mutant is prepared identically no
    /// matter which path is about to test it: `.finished` for a verdict
    /// that needed no test at all (an anchor that no longer matches,
    /// `.noCoverage`, a build that failed to produce a testable artifact,
    /// or — isolated mode only — a build product already proven identical
    /// to the baseline's, see the short-circuit below), `.readyToTest` for
    /// one whose build succeeded and still needs running.
    func prepare(
        _ point: MutationPoint,
        in sandbox: Sandbox,
        baseline: BaselineContext,
        startedAt: Date
    ) async -> PrepareOutcome {
        let scope = PrepareScope(runner: self, point: point, startedAt: startedAt)

        let applied: AppliedMutation
        switch await applyMutation(in: sandbox, scope: scope) {
        case let .applied(appliedMutation):
            applied = appliedMutation
        case let .failed(outcome):
            return outcome
        }

        // Fast path: a baseline coverage map that knows this line was never
        // executed lets us classify the mutant without building or testing it.
        // The mutation is on a line the suite does not reach, so the verdict is
        // `noCoverage` regardless of what a run would say — and skipping the
        // build is a large fraction of the speedup the design promises.
        //
        // The mutation was applied to the source, so the evidence carries a real
        // diff. The build product hash is left `nil` and the activation evidence
        // is `nil`, which is exactly the honest record for a mutant that was
        // never built. `isReportable` is satisfied by the source diff alone, and
        // `noCoverage` is not flagged by the activation check, so this result
        // enters the score without a phantom or unproven-activation violation.
        if let coverage = baseline.coverage, coverage.isKnownUncovered(point) {
            let observation = coverage.observation(forFile: point.file, line: point.line)
            return await scope.finished(
                sourceApplication: .applied(evidenceAssembler.evidence(applied)),
                coverage: CoverageObservation(mutatedLineWasExecuted: false, source: observation?.source ?? "baseline coverage")
            )
        }

        let observation = baseline.coverage?.observation(forFile: point.file, line: point.line)

        // An empty result is never used: it would mean "run nothing", which
        // a coverage-blind run can't tell apart from a test that legitimately
        // has none. `nil` — unknown attribution, or none configured — always
        // falls back to the full configured test list inside the adapter.
        let selectedTests = baseline.perTestCoverage
            .flatMap { $0.testsCovering(file: point.file, line: point.line) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let artifact: BuildArtifact
        let buildDurationSeconds: Double
        switch await buildMutant(applied, in: sandbox, scope: scope) {
        case let .built(builtArtifact, duration):
            artifact = builtArtifact
            buildDurationSeconds = duration
        case let .failed(outcome):
            return outcome
        }

        let activation = MutationEvidenceAssembler.activationEvidence(
            mutantHash: artifact.productHash,
            baselineHash: baseline.productHash
        )

        // Short-circuit: in isolated mode the mutation is compiled directly
        // into the binary, so a build product already identical to the
        // baseline's needs no test run to classify. This comparison runs
        // once, immediately after the build and strictly before any test is
        // ever attempted for this mutant — so `.timedOut` and `.flaky`
        // cannot already exist at this point; both are outcomes of an
        // actual test run (`.flaky` only as a *second*, confirming run
        // disagreeing with a first — see `MutationVerdictVerifier
        // .confirmKill`/`confirmCrash`), which by construction has not
        // happened yet.
        //
        // What the suite *would* report if run anyway is a separate
        // question, and it does not have one uniform answer.
        // `MutationVerdictVerifier.classify` routes `.passed`/`.failed`/
        // `.crashed` through `unprovenActivation` and downgrades every one
        // of them to `.infrastructureFailure` once activation is unproven —
        // for those three, running the suite here really would only ever
        // confirm what this comparison already knows, at the cost of the
        // full test-execution wall-clock. But `.timedOut` bypasses that gate
        // entirely: `classify` always reports a hang as `.timedOut`
        // regardless of activation. Had this short-circuit not existed and
        // a hash-identical mutant's tests hung, the verdict would have been
        // `.timedOut` — and, if `confirmTimedOutMutants` reproduced it on
        // an independent rebuild, ultimately `.verifiedTimeout`, which this
        // codebase credits as a real kill — for a mutation that never
        // reached the binary at all. So for the timeout path specifically,
        // skipping the run does not just avoid a redundant confirmation; it
        // closes a route to a false kill credit that running the suite
        // would otherwise have opened. (Schemata mode has no equivalent:
        // one shared build embeds every mutation, so there is no per-mutant
        // pre-test hash to compare — activation there can only be
        // established by the runtime hit protocol during the test itself.)
        //
        // Round-2 review M2: the "identical to baseline" claim this
        // short-circuit trusts completely comes from `MachOCodeHash`, which
        // has been wrong before in exactly this direction — issue #3 (see
        // its own doc comment) was a real, CI-confirmed false positive
        // where a mutation that genuinely reached the binary and genuinely
        // failed a test still hashed identical to baseline, because the
        // difference lived in linkage rather than in any hashed section's
        // bytes. Before this short-circuit existed, running the suite on
        // every mutant was the safety net that surfaced that: a
        // hash-identical mutant whose tests still failed was a visible
        // contradiction, right here in this run's own diagnosis text. This
        // short-circuit retires that net for every hash-matched mutant,
        // since none of their tests run at all any more — see
        // `Configuration.execution.noOpCanarySampleRate` for the narrow,
        // deterministic, opt-in slice of it this reopens.
        if case .buildProductIdenticalToBaseline? = activation, !isNoOpCanarySample(point.id) {
            return await scope.finished(
                sourceApplication: .applied(evidenceAssembler.evidence(applied, artifact: artifact, activation: activation)),
                build: BuildObservation(
                    outcome: .succeeded(buildProductHash: artifact.productHash, command: artifact.command),
                    durationSeconds: buildDurationSeconds
                ),
                infrastructureFailureDiagnosis: """
                The mutant's build product is identical to the baseline's, so the mutation did not reach the \
                product under test (code compiled out, dead-stripped or optimized away). Tests were skipped rather \
                than run against a build already known to contain no mutation.
                """,
                buildDurationSeconds: buildDurationSeconds
            )
        }

        // F3 zero-base review, verdict-contamination audit: cloned here —
        // immediately after the build succeeds, strictly *before* the
        // caller ever runs this mutant's primary test — so that
        // `confirmKill`'s later retest (see that function's own doc
        // comment) never executes anywhere a `ProcessSupervisor`-escaped
        // descendant from *this exact* primary run could still be writing.
        // Cloning any later than this — even "right before `confirmKill`
        // itself runs" — would not be safe: that descendant is still alive
        // for however long it happens to survive, so a clone taken after
        // the primary run merely races it instead of avoiding it entirely.
        // See `establishConfirmationSandbox` for the clone itself and its
        // own infrastructure-failure handling.
        let (confirmationSandbox, confirmationFailure) = await establishConfirmationSandbox(
            ConfirmationSandboxRequest(
                point: point, applied: applied, artifact: artifact, activation: activation,
                coverage: observation, buildDurationSeconds: buildDurationSeconds
            ),
            startedAt: startedAt
        )
        if let confirmationFailure { return confirmationFailure }

        return .readyToTest(PreparedMutant(
            point: point,
            workspace: .sandbox(sandbox),
            applied: applied,
            artifact: artifact,
            activation: activation,
            observation: observation,
            selectedTests: selectedTests,
            startedAt: startedAt,
            buildDurationSeconds: buildDurationSeconds,
            confirmationSandbox: confirmationSandbox
        ))
    }

    /// Clones this mutant's own independent confirmation workspace out of
    /// its just-built products directory, before `prepare` ever hands this
    /// mutant off for its primary test.
    ///
    /// F3 zero-base review, verdict-contamination audit: called
    /// immediately after the build succeeds, strictly *before* this
    /// mutant's primary test ever runs — so that `confirmKill`'s later
    /// retest (see that function's own doc comment) never executes
    /// anywhere a `ProcessSupervisor`-escaped descendant from *this exact*
    /// primary run could still be writing. Calling this any later — even
    /// "right before `confirmKill` itself runs" — would not be safe: that
    /// descendant is still alive for however long it happens to survive,
    /// so a clone taken after the primary run merely races it instead of
    /// avoiding it entirely. Only paid when a confirmation retest could
    /// ever actually be attempted; `cloneProducts` clones the already-built
    /// products directory (`clonefile` on APFS — not a real byte-for-byte
    /// copy) rather than rebuilding, so this stays cheap relative to the
    /// build that already happened, even though it runs for every mutant
    /// this gate applies to, not just the ones that end up `.failed`.
    ///
    /// Returns `(nil, nil)` when no confirmation could ever be attempted
    /// (`retestKilledMutants` off), `(url, nil)` with the clone's location,
    /// or `(nil, outcome)` carrying the already-finalized `PrepareOutcome`
    /// for the caller — `prepare`'s own — to return directly.
    func establishConfirmationSandbox(
        _ request: ConfirmationSandboxRequest, startedAt: Date
    ) async -> (sandbox: URL?, failure: PrepareOutcome?) {
        guard configuration.execution.retestKilledMutants else { return (nil, nil) }
        do {
            // Chooses the flat or nested clone shape per `test`'s own
            // conformance -- see `PackageManifestConfirmationRetesting`.
            let sandbox = try await workspaces.cloneProductsForConfirmationRetest(
                from: request.artifact.productsDirectory, id: "\(request.point.id.rawValue)-confirm", for: test
            )
            return (sandbox, nil)
        } catch {
            let result = await evidenceAssembler.finalize(
                point: request.point,
                sourceApplication: .applied(
                    evidenceAssembler.evidence(request.applied, artifact: request.artifact, activation: request.activation)
                ),
                build: BuildObservation(
                    outcome: .succeeded(buildProductHash: request.artifact.productHash, command: request.artifact.command),
                    durationSeconds: request.buildDurationSeconds
                ),
                coverage: request.coverage,
                infrastructureFailureDiagnosis: """
                This mutant built successfully, but its own independent confirmation workspace could not be \
                cloned out ahead of testing: \(error). Testing was skipped rather than proceed without \
                confirmKill's own required isolation from this run's primary test.
                """,
                durationSeconds: Date().timeIntervalSince(startedAt),
                buildDurationSeconds: request.buildDurationSeconds
            )
            return (nil, .finished(result))
        }
    }

    /// Deterministic membership test for `Configuration.execution
    /// .noOpCanarySampleRate`'s sample of hash-matched "no-op" mutants —
    /// see the short-circuit above and that setting's own doc comment for
    /// why this exists.
    ///
    /// Keyed off the mutation's own stable `MutationID` rather than a random
    /// draw, so the same plan always samples the same canaries run to
    /// run — this type's own top-level doc comment promises "two runs of
    /// the same plan produce the same report", and a `Bool.random()` here
    /// would break that promise for every hash-matched mutant. `ContentHash
    /// .uint64` turns the ID into a value uniform over the full `UInt64`
    /// range; comparing its position in that range against `rate` is the
    /// continuous form of `hash % n == 0`, without requiring `rate` to
    /// divide evenly into any particular `n`.
    private func isNoOpCanarySample(_ id: MutationID) -> Bool {
        let rate = configuration.execution.noOpCanarySampleRate
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }
        let position = Double(ContentHash.uint64(of: id.rawValue)) / Double(UInt64.max)
        return position < rate
    }

    /// Logs the canary contradiction `finishAfterTest` detects: a mutant
    /// `MachOCodeHash` swore reached the binary unchanged, whose real test
    /// run did not simply pass anyway. Recorded both to stderr (for a human
    /// watching the run live) and to `RunReport.operationalIssues` (for a
    /// reader of `report.json` afterward), the same two places
    /// `finalize`'s checkpoint-write failure already uses — this is
    /// exactly as "the run's own score does not depend on it, but it must
    /// not silently vanish" as that one is.
    private func recordNoOpCanaryAnomaly(_ point: MutationPoint, run: TestRunResult) async {
        let diagnosis = """
        noOpCanarySampleRate canary for \(point.id): the build product hashed identical to baseline, but the \
        real test run reported \(run.status.rawValue) rather than passing (\(run.diagnosis)). A mutation that \
        never reached the binary cannot make a suite that passes on baseline behave differently — this is the \
        same shape of contradiction issue #3 exposed in MachOCodeHash, and is worth investigating as a possible \
        false "identical to baseline" claim rather than assumed harmless.
        """
        FileHandle.standardError.write(Data("warning: \(diagnosis)\n".utf8))
        await operationalIssues.append(
            OperationalIssue(severity: .warning, kind: .noOpCanaryUnexpectedOutcome, mutationID: point.id, diagnosis: diagnosis)
        )
    }

    /// The other half of a prepared mutant's evaluation: gather whatever
    /// confirmation observations `Configuration.execution` calls for, then
    /// hand the complete `MutationObservations` to `finalize` exactly
    /// once. `run` may have come from `runMutantTests` (the per-mutant
    /// path) or from a batch (`evaluateInBatches`) — this function does
    /// not know or care which, so a batched and an unbatched mutant with
    /// the same test outcome are classified identically.
    ///
    /// The authoritative verdict pipeline: whether to gather a confirmation is decided from
    /// `run`'s own raw `status` and `prepared.activation`'s own
    /// `provesActivation` — never from a classification computed ahead of
    /// the verifier, which is the whole point of this stage. The verifier
    /// (inside `finalize`) is the only place that turns the resulting
    /// observation set into an outcome.
    /// - Parameters:
    ///   - attribution: whether `run` was observed for this mutant alone
    ///     (`.standalone`, including a synthetic infrastructure failure that
    ///     never reached a runner) or taken from a shared batch invocation's
    ///     per-configuration result (`.batch`). Recorded as evidence only.
    ///   - priorTestAttempts: earlier waves' evidence this mutant already
    ///     went through (see `WaveSurvivor.attempts`) — empty outside
    ///     wave-based early kill.
    ///   - appendCurrentAttempt: whether `run` itself is a NEW attempt to
    ///     record (true for a real invocation: a wave's own test, or a
    ///     standalone ground-truth verification) as opposed to a synthetic
    ///     repackaging of a survivor's already-recorded last wave (the
    ///     `exhausted` case in `testOneWave`, where `run` merely restates
    ///     `priorTestAttempts`'s own last entry and appending it again would
    ///     duplicate it).
    ///   - currentAttemptWaveIndex: which wave `run` belongs to, when
    ///     `appendCurrentAttempt` is true and it came from a specific wave —
    ///     `nil` for a standalone verification, which is not itself a wave.
    func finishAfterTest(
        _ prepared: PreparedMutant,
        baseline: BaselineContext,
        run: TestRunResult,
        attribution: TestExecutionRecord.Attribution,
        testDurationSeconds: Double? = nil,
        priorTestAttempts: [TestAttemptEvidence] = [],
        appendCurrentAttempt: Bool = false,
        currentAttemptWaveIndex: Int? = nil
    ) async -> MutationResult {
        var confirmations: [ConfirmationObservation] = []
        var crashConfirmation: CrashConfirmation?
        var timeoutConfirmation: TimeoutConfirmation?
        var confirmationDurationSeconds: Double?
        let activationProven = prepared.activation?.provesActivation ?? false

        // Round-2 review M2: a hash-matched ("no-op") mutant only ever
        // reaches a real `run` here when `noOpCanarySampleRate` sampled it
        // as a canary — see `prepare`'s short-circuit and that setting's own
        // doc comment. `.passed` is the only outcome consistent with the
        // hash's claim that the mutation never reached the binary; anything
        // else contradicts it, which is exactly the shape issue #3 took (a
        // false "identical", exposed only by the suite genuinely not
        // passing). `MutationVerdictVerifier.classify` still applies its own
        // rules below, same as always — this only makes sure the
        // contradiction itself is not lost inside whatever bucket that
        // produces.
        if case .buildProductIdenticalToBaseline? = prepared.activation, run.status != .passed {
            await recordNoOpCanaryAnomaly(prepared.point, run: run)
        }

        // Retesting only ever moves a verdict *out* of a kill, never into
        // one — a mutant that survived or crashed is not re-run, because
        // the failure mode this guards against is a flake being mistaken
        // for a kill, not the reverse. See `Configuration.execution
        // .retestKilledMutants`.
        // F3 zero-base review, verdict-contamination audit: `confirmKill`
        // always reuses whatever sandbox/artifact it is handed — never
        // `prepared.sandbox`/`prepared.artifact` directly (the primary
        // run's own home) — always `prepared.confirmationSandbox`, an
        // independent clone `prepare` established before this mutant's
        // primary test ever ran. See `confirmKillIfNeeded`.
        if let (observation, durationSeconds) = await confirmationCoordinator.confirmKillIfNeeded(
            prepared, baseline: baseline, run: run, activationProven: activationProven
        ) {
            confirmations.append(observation)
            confirmationDurationSeconds = (confirmationDurationSeconds ?? 0) + durationSeconds
        }

        // A crash gets a fresh, independent rebuild rather than a same-sandbox
        // retest — see `Configuration.execution.confirmCrashKills`'s doc comment
        // for why the same-artifact retest `retestKilledMutants` uses for
        // assertion kills is not enough here.
        if configuration.execution.confirmCrashKills || run.crashProvenance != nil, run.status == .crashed, activationProven {
            let confirmationStarted = Date()
            let (observation, crashEvidence) = await confirmationCoordinator.confirmCrashKill(
                prepared.point, baseline: baseline, selectedTests: prepared.selectedTests, originalDiagnosis: run.diagnosis
            )
            confirmations.append(observation)
            crashConfirmation = crashEvidence
            confirmationDurationSeconds = (confirmationDurationSeconds ?? 0) + Date().timeIntervalSince(confirmationStarted)
        }

        // Same shape as the crash confirmation above, for the same reason: a
        // hang has no diff to check against, so it gets a fresh, independent
        // rebuild rather than a same-sandbox retest. See
        // `Configuration.execution.confirmTimedOutMutants`. Unlike the other
        // two gates, this one does not also require `activationProven`: a
        // `.timedOut` mutant's own activation is often unknown (the build
        // may never have produced a comparable hash under a hung test), and
        // the whole point of the confirming rebuild is to establish that
        // proof, not require it up front.
        if configuration.execution.confirmTimedOutMutants, run.status == .timedOut {
            let confirmationStarted = Date()
            let confirmed = await confirmationCoordinator.confirmTimeout(
                prepared.point, baseline: baseline, selectedTests: prepared.selectedTests,
                wasBatchAttributed: run.isBatchAttributedTimeout
            )
            confirmations.append(contentsOf: confirmed.observations)
            timeoutConfirmation = confirmed.timeoutConfirmation
            crashConfirmation = confirmed.crashConfirmation
            confirmationDurationSeconds = (confirmationDurationSeconds ?? 0) + Date().timeIntervalSince(confirmationStarted)
        }

        // `confirmationSandbox` was created eagerly, before this mutant's
        // verdict was known (see its own doc comment on `PreparedMutant`),
        // so it must be disposed here unconditionally — whether or not
        // `run.status == .failed` actually used it above. `finishAfterTest`
        // is this mutant's one terminal call (every caller reaches it
        // exactly once — wave-based early kill carries `prepared` forward
        // across waves without ever re-preparing it), so this is not
        // reachable more than once per mutant.
        if let confirmationSandbox = prepared.confirmationSandbox {
            try? await workspaces.destroyProductsClone(at: confirmationSandbox)
        }

        let resultArtifact = evidenceAssembler.preserve(run.resultArtifactPath, for: prepared.point, in: prepared.sandbox)
        var testAttempts = priorTestAttempts
        if appendCurrentAttempt {
            testAttempts.append(TestAttemptEvidence(
                selectedTests: prepared.selectedTests?.map(\.onlyTestingArgument),
                status: run.status.rawValue,
                summary: run.summary,
                command: run.command,
                resultArtifact: resultArtifact,
                waveIndex: currentAttemptWaveIndex
            ))
        }

        return await evidenceAssembler.finalize(
            point: prepared.point,
            sourceApplication: .applied(evidenceAssembler.evidence(
                prepared.applied,
                artifact: prepared.artifact,
                activation: prepared.activation,
                testCommand: run.command,
                resultArtifact: resultArtifact,
                crashConfirmation: crashConfirmation,
                timeoutConfirmation: timeoutConfirmation,
                testAttempts: testAttempts
            )),
            build: BuildObservation(
                outcome: .succeeded(buildProductHash: prepared.artifact.productHash, command: prepared.artifact.command)
            ),
            coverage: prepared.observation,
            test: SingleTestObservation(
                run: run, applicationEvidence: prepared.activation.map { .isolated($0) },
                execution: TestExecutionRecord(attribution: attribution, selectedTests: prepared.selectedTests?.map(\.onlyTestingArgument))
            ),
            confirmations: confirmations,
            durationSeconds: Date().timeIntervalSince(prepared.startedAt),
            buildDurationSeconds: prepared.buildDurationSeconds,
            testDurationSeconds: testDurationSeconds,
            confirmationDurationSeconds: confirmationDurationSeconds
        )
    }
}
