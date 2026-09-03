import Foundation
import MutationModel
import SwiftFrontend

/// Everything `MutationConfirmationCoordinator.timeoutInnerConfirmKillIfNeeded(_:)`
/// needs, bundled so that call stays within swiftlint's parameter-count
/// limit — see that method's own doc comment for what it does with these.
struct TimeoutInnerRetestRequest {
    let point: MutationPoint
    let artifact: BuildArtifact
    let innerConfirmationSandbox: URL?
    let baseline: MutationRunner.BaselineContext
    let selectedTests: Set<TestIdentifier>?
    let confirmingRun: TestRunResult
    let confirmingActivationProven: Bool
    let wasBatchAttributed: Bool
}

/// Owns retesting a mutant's already-decided outcome before it is trusted:
/// same-artifact confirmation for an assertion kill (`confirmKillIfNeeded`/
/// `confirmKill`), and fresh, independent rebuild-and-retest for a crash or
/// a timeout (`confirmCrashKill`/`confirmTimeout`) — plus the shared
/// test-running primitive (`runMutantTests`) every one of those retests, and
/// `MutationRunner`'s own primary test run, executes through.
///
/// Extracted out of `MutationRunner` (Phase A1 of the execution-pipeline
/// decomposition): every method here closes over exactly the dependencies a
/// retest needs to run in true isolation — `workspaces`/`build`/`test` to
/// stand up an independent sandbox and drive it, `configuration` for the
/// `retestKilledMutants`/`confirmCrashKills` gates a retest itself checks
/// (not the outer `confirmCrashKills`/`confirmTimedOutMutants` gate that
/// decides *whether* to call in here at all — that stays in
/// `MutationRunner.finishAfterTest`, since it also has to fold the result
/// into a single `MutationObservations`). Nothing here decides a verdict;
/// `MutationVerdictVerifier` (via `MutationEvidenceAssembler.finalize`)
/// still does that, from whatever `ConfirmationObservation`s these methods
/// hand back.
struct MutationConfirmationCoordinator: Sendable {
    let workspaces: WorkspaceManager
    let build: any BuildAdapter
    let test: any TestAdapter
    let configuration: Configuration

    /// Runs a mutant's tests, narrowed to `selectedTests` when the adapter
    /// can honour that (`TestSelecting`) and a set was supplied, and
    /// running the full configured test list otherwise — the same fallback
    /// `TestSelecting.runMutant` itself applies for `selectedTests == nil`,
    /// mirrored here so a coverage-blind adapter (no `TestSelecting`
    /// conformance at all) behaves identically.
    ///
    /// Used for a mutant's first test run and for every confirmation rerun
    /// of it: a confirmation is meant to reproduce the original observation,
    /// not test a different, wider or narrower, slice of the suite than the
    /// one that produced the verdict being confirmed.
    func runMutantTests(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in sandbox: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        if let selecting = test as? any TestSelecting {
            return try await selecting.runMutant(
                point, artifact: artifact, in: sandbox, timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
            )
        }
        return try await test.runMutant(point, artifact: artifact, in: sandbox, timeoutSeconds: timeoutSeconds)
    }

    /// Retries a failed mutant's own test in its independent
    /// `confirmationSandbox`, when one applies — retesting only ever moves
    /// a verdict *out* of a kill, never into one, so this only runs for
    /// `.failed` with proven activation; see `Configuration.execution
    /// .retestKilledMutants`.
    ///
    /// `confirmKill` always reuses whatever sandbox/artifact it is handed
    /// — never `prepared.sandbox`/`prepared.artifact` directly (the
    /// primary run's own home, wherever that was for this mutant's own
    /// test path — same sandbox, a batch sandbox, or a wave chunk
    /// sandbox), always `prepared.confirmationSandbox` (see that field's
    /// own doc comment): an independent clone `prepare` established before
    /// this mutant's primary test ever ran, so this retest can never
    /// execute anywhere a `ProcessSupervisor`-escaped descendant from that
    /// primary run could still be writing. `confirmationSandbox` is `nil`
    /// here only if `retestKilledMutants` was off when this mutant's own
    /// build completed — impossible in this branch, since that flag is one
    /// constant `Configuration` value for the whole run — so that branch is
    /// defensive, not a real fallback path.
    func confirmKillIfNeeded(
        _ prepared: MutationRunner.PreparedMutant, baseline: MutationRunner.BaselineContext, run: TestRunResult, activationProven: Bool
    ) async -> (observation: ConfirmationObservation, durationSeconds: Double)? {
        guard configuration.execution.retestKilledMutants, run.status == .failed, activationProven else { return nil }
        let confirmationStarted = Date()
        let observation: ConfirmationObservation
        if let confirmationSandbox = prepared.confirmationSandbox {
            let isolated = MutationRunner.relocating(prepared, to: confirmationSandbox)
            observation = await confirmKill(
                isolated.point, artifact: isolated.artifact, in: isolated.sandbox, baseline: baseline,
                selectedTests: isolated.selectedTests, originalFailingTests: run.summary?.failingTests
            )
        } else {
            observation = ConfirmationObservation(
                kind: .kill,
                run: infrastructureFailureRun(
                    "This mutant's own independent confirmation workspace was never established, so no " +
                        "isolated retest could run."
                ),
                originalFailingTests: run.summary?.failingTests
            )
        }
        return (observation, Date().timeIntervalSince(confirmationStarted))
    }

    /// A synthetic run standing in for "a confirmation attempt could not
    /// even launch" (no sandbox, no build, no process) — represented as an
    /// ordinary `TestRunResult` with `.infrastructureFailure` status so it
    /// flows through `ConfirmationObservation` like any other confirming
    /// run, rather than needing a separate short-circuit path. The verifier
    /// treats an `.infrastructureFailure`-status confirmation uniformly,
    /// regardless of kind — see `MutationVerdictVerifier.confirm`.
    func infrastructureFailureRun(_ diagnosis: String) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil,
            command: CommandRecord(executable: "", arguments: [], workingDirectory: ""),
            resultArtifactPath: nil, diagnosis: diagnosis
        )
    }

    /// Runs a mutant's tests a second time, on the artifact already built for it.
    ///
    /// A confirmation that could not even run — a launch failure, an
    /// adapter/simulator/process problem — is represented as an
    /// `.infrastructureFailure`-status run (see `infrastructureFailureRun`),
    /// which the verifier always treats as unconfirmed regardless of kind —
    /// `killedByAssertion` is not proven until a retest reproduces it, so a
    /// confirmation that never got that far is excluded from the score, the
    /// same as any other mutant this tool could not reach a verdict on.
    func confirmKill(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in sandbox: URL,
        baseline: MutationRunner.BaselineContext,
        selectedTests: Set<TestIdentifier>?,
        originalFailingTests: [String]?
    ) async -> ConfirmationObservation {
        let confirmingRun: TestRunResult
        do {
            // Same per-mutant timeout the primary run this is confirming
            // used — derived the same way, from the same `selectedTests`,
            // never recomputed independently or widened to the whole suite.
            confirmingRun = try await runMutantTests(
                point, artifact: artifact, in: sandbox,
                timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: selectedTests),
                selectedTests: selectedTests
            )
        } catch {
            confirmingRun = infrastructureFailureRun("a confirmation run could not be started: \(error)")
        }
        return ConfirmationObservation(kind: .kill, run: confirmingRun, originalFailingTests: originalFailingTests)
    }

    /// Rebuilds a mutant from scratch in an independent sandbox and re-tests
    /// it, to confirm a `killedByCrash` verdict before trusting it.
    ///
    /// Unlike `confirmKill`, this does not reuse the artifact or sandbox the
    /// first attempt built. Found necessary on a real project: a
    /// `killedByCrash` verdict whose crash was attributed to test methods
    /// with no connection to the mutated file did not reproduce when the
    /// identical mutant was rebuilt independently and tested by hand — a
    /// same-sandbox retest, still holding onto whatever state produced that
    /// crash, would have had no chance of ruling it out.
    ///
    /// Returns both the raw `ConfirmationObservation` (what the verifier
    /// actually judges) and the `CrashConfirmation` display evidence
    /// (`crashedAgain` computed the identical way the verifier's own
    /// `confirmCrash` derives it — a real crash, with the identical,
    /// normalized diagnosis text) — kept in sync deliberately, not by
    /// sharing code across the module boundary between `MutationExecution`
    /// and `MutationModel`.
    func confirmCrashKill(
        _ point: MutationPoint,
        baseline: MutationRunner.BaselineContext,
        selectedTests: Set<TestIdentifier>?,
        originalDiagnosis: String
    ) async -> (observation: ConfirmationObservation, evidence: CrashConfirmation) {
        func unconfirmed(_ diagnosis: String) -> (ConfirmationObservation, CrashConfirmation) {
            (
                ConfirmationObservation(kind: .crash, run: infrastructureFailureRun(diagnosis), originalDiagnosis: originalDiagnosis),
                CrashConfirmation(confirmingBuildCommand: nil, confirmingTestCommand: nil, crashedAgain: false, diagnosis: diagnosis)
            )
        }

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: "\(point.id.rawValue)-crash-confirm")
        } catch {
            return unconfirmed("No confirmation sandbox could be created: \(error)")
        }

        let sourceURL: URL
        do {
            sourceURL = try workspaces.resolveSourceURL(in: sandbox, relativePath: point.file)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The confirmation sandbox's source could not be located: \(error)")
        }

        let applied: AppliedMutation
        do {
            applied = try MutationApplication.applyInPlace(point, fileAt: sourceURL)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The mutation could not be re-applied for confirmation: \(error)")
        }

        let artifact: BuildArtifact
        do {
            artifact = try await build.buildMutant(applied, in: sandbox)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The confirmation rebuild did not build: \(error)")
        }

        let confirmingRun: TestRunResult
        do {
            confirmingRun = try await runMutantTests(
                point, artifact: artifact, in: sandbox,
                // Same per-mutant timeout the primary run this is confirming
                // used — derived the same way, from the same
                // `selectedTests`, never recomputed independently or widened
                // to the whole suite.
                timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: selectedTests),
                selectedTests: selectedTests
            )
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The confirmation rebuild's tests could not be run: \(error)")
        }

        try? await workspaces.destroySandbox(at: sandbox)

        let normalizedOriginal = originalDiagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfirming = confirmingRun.diagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        let crashedAgain = confirmingRun.status == .crashed && normalizedOriginal == normalizedConfirming

        return (
            ConfirmationObservation(kind: .crash, run: confirmingRun, originalDiagnosis: originalDiagnosis),
            CrashConfirmation(
                confirmingBuildCommand: artifact.command,
                confirmingTestCommand: confirmingRun.command,
                crashedAgain: crashedAgain,
                diagnosis: confirmingRun.diagnosis
            )
        )
    }

    /// Rebuilds a `.timedOut` mutant from scratch, in a sandbox independent
    /// of the one the original timeout was observed in.
    ///
    /// Same shape as `confirmCrashKill`, same reasoning: a hang has no diff
    /// to check against, and was found — empirically, on a real project — to
    /// sometimes be a fact about *this* evaluation's execution context (a
    /// concurrent worker pool vs. running alone, or even just which machine
    /// ran it) rather than a fact about the mutant. Runs under the *same*
    /// timeout limit as the original attempt.
    ///
    /// A confirming rebuild that turns out to be a kill or a crash (a
    /// batch-attributed `.timedOut` carries no real information about this
    /// specific mutant, so the confirming rebuild is that mutant's first
    /// real observation) is routed through the *same* confirmation gates
    /// any other first-observed kill/crash would go through —
    /// `retestKilledMutants`/`confirmCrashKills` — gated on the confirming
    /// run's own raw status and activation, exactly as `finishAfterTest`
    /// gates its own first-pass confirmations, never on a classification.
    /// Returns every observation gathered, in order (the timeout attempt,
    /// then whichever cascade fired) — `MutationVerdictVerifier` folds them
    /// in that same order.
    struct TimeoutConfirmationResult {
        let observations: [ConfirmationObservation]
        let timeoutConfirmation: TimeoutConfirmation
        let crashConfirmation: CrashConfirmation?
    }

    func confirmTimeout(
        _ point: MutationPoint,
        baseline: MutationRunner.BaselineContext,
        selectedTests: Set<TestIdentifier>?,
        wasBatchAttributed: Bool
    ) async -> TimeoutConfirmationResult {
        func unconfirmed(_ diagnosis: String) -> TimeoutConfirmationResult {
            TimeoutConfirmationResult(
                observations: [ConfirmationObservation(
                    kind: .timeout, run: infrastructureFailureRun(diagnosis), wasBatchAttributed: wasBatchAttributed
                )],
                timeoutConfirmation: TimeoutConfirmation(
                    confirmingBuildCommand: nil, confirmingTestCommand: nil, timedOutAgain: false, diagnosis: diagnosis
                ),
                crashConfirmation: nil
            )
        }

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: "\(point.id.rawValue)-timeout-confirm")
        } catch {
            return unconfirmed("No confirmation sandbox could be created: \(error)")
        }

        let sourceURL: URL
        do {
            sourceURL = try workspaces.resolveSourceURL(in: sandbox, relativePath: point.file)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The confirmation sandbox's source could not be located: \(error)")
        }

        let applied: AppliedMutation
        do {
            applied = try MutationApplication.applyInPlace(point, fileAt: sourceURL)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The mutation could not be re-applied for confirmation: \(error)")
        }

        let artifact: BuildArtifact
        do {
            artifact = try await build.buildMutant(applied, in: sandbox)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The confirmation rebuild did not build: \(error)")
        }

        // F3 zero-base review, verdict-contamination audit: cloned here —
        // immediately after this confirming rebuild succeeds, strictly
        // *before* `confirmingRun` (this function's own primary-equivalent
        // test) ever runs — so that the internal `confirmKill` retest below
        // (same-artifact, for a batch-attributed timeout that turns out to
        // be a genuine assertion kill) never executes anywhere a
        // `ProcessSupervisor`-escaped descendant from `confirmingRun` could
        // still be writing. Same shape and same reasoning as `prepare`'s
        // own `confirmationSandbox` — see that method's doc comment.
        let innerConfirmationSandbox: URL?
        if configuration.execution.retestKilledMutants, wasBatchAttributed {
            innerConfirmationSandbox = try? await workspaces.cloneProducts(
                from: artifact.productsDirectory, id: "\(point.id.rawValue)-timeout-confirm-of-confirm"
            )
        } else {
            innerConfirmationSandbox = nil
        }

        let confirmingRun: TestRunResult
        do {
            confirmingRun = try await runMutantTests(
                point, artifact: artifact, in: sandbox,
                // Same per-mutant timeout the primary run this is confirming
                // used — derived the same way, from the same
                // `selectedTests`, never recomputed independently or widened
                // to the whole suite.
                timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: selectedTests),
                selectedTests: selectedTests
            )
        } catch {
            if let innerConfirmationSandbox { try? await workspaces.destroySandbox(at: innerConfirmationSandbox) }
            try? await workspaces.destroySandbox(at: sandbox)
            return unconfirmed("The confirmation rebuild's tests could not be run: \(error)")
        }

        let confirmingActivation = MutationEvidenceAssembler.activationEvidence(
            mutantHash: artifact.productHash, baselineHash: baseline.productHash
        )
        let confirmingActivationProven = confirmingActivation?.provesActivation ?? false
        var observations: [ConfirmationObservation] = [
            ConfirmationObservation(
                kind: .timeout, run: confirmingRun, activation: confirmingActivation,
                confirmingBuildProductHash: artifact.productHash, wasBatchAttributed: wasBatchAttributed
            )
        ]

        // Same-artifact retest — but never on `sandbox` itself, which
        // `confirmingRun` (just above) has already run in: a
        // `ProcessSupervisor`-escaped descendant from that run could still
        // be writing there. See `timeoutInnerConfirmKillIfNeeded`.
        if let observation = await timeoutInnerConfirmKillIfNeeded(TimeoutInnerRetestRequest(
            point: point, artifact: artifact, innerConfirmationSandbox: innerConfirmationSandbox,
            baseline: baseline, selectedTests: selectedTests, confirmingRun: confirmingRun,
            confirmingActivationProven: confirmingActivationProven, wasBatchAttributed: wasBatchAttributed
        )) {
            observations.append(observation)
        }

        if let innerConfirmationSandbox { try? await workspaces.destroySandbox(at: innerConfirmationSandbox) }
        try? await workspaces.destroySandbox(at: sandbox)

        // A crash, unlike an assertion kill, is never confirmed on the same
        // artifact (see `confirmCrashKill`'s doc comment) — its own fresh,
        // independent rebuild, same as any other first-observed crash.
        var crashConfirmationEvidence: CrashConfirmation?
        if configuration.execution.confirmCrashKills, wasBatchAttributed,
           confirmingRun.status == .crashed, confirmingActivationProven {
            let (crashObservation, crashEvidence) = await confirmCrashKill(
                point, baseline: baseline, selectedTests: selectedTests, originalDiagnosis: confirmingRun.diagnosis
            )
            observations.append(crashObservation)
            crashConfirmationEvidence = crashEvidence
        }

        let timeoutConfirmation = TimeoutConfirmation(
            confirmingBuildCommand: artifact.command,
            confirmingTestCommand: confirmingRun.command,
            timedOutAgain: confirmingRun.status == .timedOut && confirmingActivationProven,
            diagnosis: confirmingRun.diagnosis
        )

        return TimeoutConfirmationResult(
            observations: observations, timeoutConfirmation: timeoutConfirmation, crashConfirmation: crashConfirmationEvidence
        )
    }

    /// `confirmTimeout`'s own same-artifact retest, for a batch-attributed
    /// timeout whose confirming rebuild turned out to be a genuine
    /// assertion kill — same shape and reasoning as a normal assertion
    /// kill's own retest (`confirmKillIfNeeded`), reusing the confirming
    /// rebuild's artifact rather than rebuilding again.
    ///
    /// F3 zero-base review, verdict-contamination audit: never reruns in
    /// the confirming rebuild's own sandbox, which `confirmingRun` has
    /// already run in — a `ProcessSupervisor`-escaped descendant from that
    /// run could still be writing there. Always
    /// `request.innerConfirmationSandbox`, an independent clone
    /// `confirmTimeout` established immediately after its own rebuild
    /// succeeded, strictly *before* `confirmingRun` ever started. `nil`
    /// only if that eager clone itself failed — reported as its own
    /// unconfirmed observation rather than silently skipped, the same way
    /// `confirmKillIfNeeded`'s outer-level counterpart handles a missing
    /// `confirmationSandbox`. Returns `nil` when no retest applies at all.
    func timeoutInnerConfirmKillIfNeeded(_ request: TimeoutInnerRetestRequest) async -> ConfirmationObservation? {
        guard configuration.execution.retestKilledMutants, request.wasBatchAttributed,
              request.confirmingRun.status == .failed, request.confirmingActivationProven else { return nil }
        guard let innerConfirmationSandbox = request.innerConfirmationSandbox else {
            return ConfirmationObservation(
                kind: .kill,
                run: infrastructureFailureRun(
                    "This timeout confirmation's own independent same-artifact retest workspace could not be " +
                        "cloned out ahead of testing, so no isolated retest could run."
                ),
                originalFailingTests: request.confirmingRun.summary?.failingTests
            )
        }
        let relocatedArtifact = BuildArtifact(
            productsDirectory: innerConfirmationSandbox,
            productHash: request.artifact.productHash,
            xctestrunPath: request.artifact.xctestrunPath.map { innerConfirmationSandbox.appendingPathComponent($0.lastPathComponent) },
            command: request.artifact.command
        )
        return await confirmKill(
            request.point, artifact: relocatedArtifact, in: innerConfirmationSandbox, baseline: request.baseline,
            selectedTests: request.selectedTests, originalFailingTests: request.confirmingRun.summary?.failingTests
        )
    }
}
