import Foundation
import MutationModel
import SwiftFrontend

/// Confirmation gathering and source-level evidence for `SchemataMutationRunner`.
extension SchemataMutationRunner {
    /// Recovers one batched primary whose shared invocation produced
    /// `.infrastructureFailure` — real evidence was simply never
    /// attributable to this configuration, not proof the mutant itself is
    /// unprovable (`XCResultAdapter.classify`'s own doc comment: fail-closed
    /// on missing per-configuration evidence, never guessed from aggregate
    /// counts). Isolated mode's wave path (`MutationRunner.testWaveChunk`)
    /// already does the equivalent thing for the identical failure shape;
    /// this is schemata's own version of that same discipline, not a new
    /// retry policy.
    ///
    /// A fresh, individual, unbatched `runSchemataToken` call — this
    /// mutant's own token, point, compilation unit, selected tests, and
    /// resolved timeout carried over unchanged from the ambiguous attempt's
    /// `dispatch`, but under a **new** `RunID`/transcript/evidence
    /// directory. Never the same `RunID` as the ambiguous attempt: mixing a
    /// batch's incomplete evidence with a retry's own would let
    /// `verifySchemataChain` cross-attribute records that never actually
    /// came from the same process invocation. The retry's `TestRunResult`
    /// flows through the exact same `processPrimaryObservation` every other
    /// primary observation already uses — a `.passed`/`.failed`/`.crashed`/
    /// `.timedOut` result here gets precisely the schemata timeout-isolation design handling it
    /// would have gotten had this mutant never been batched at all; no
    /// verifier semantics change. Runs at most once: a second
    /// `.infrastructureFailure` here is final, not retried again.
    func recoverAmbiguousBatchedPrimary(
        _ entry: SchemataPlanEntry, dispatch: PrimaryDispatch, state: ChunkExecutionState
    ) async -> PrimaryOutcome {
        // The ambiguous attempt's own evidence directory was never read by
        // anything (its `TestRunResult` carried no usable schemata
        // transcript path this function trusts) and is not reused —
        // cleaned up here since `processPrimaryObservation` will only ever
        // clean up the *fresh* dispatch's directory below, not this one.
        try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)

        let recoveryDirectory = state.sandbox.appendingPathComponent(
            ".mutantkit-schemata/\(entry.mutationID.rawValue)-recovery-\(UUID().uuidString)"
        )
        let transcriptPath = recoveryDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let freshDispatch = PrimaryDispatch(
            token: dispatch.token, sourceEmbeddingID: dispatch.sourceEmbeddingID, point: dispatch.point,
            compilationUnitID: dispatch.compilationUnitID, selectedTests: dispatch.selectedTests,
            resolvedTimeoutSeconds: dispatch.resolvedTimeoutSeconds, runID: RunID(),
            evidenceDirectory: recoveryDirectory, transcriptPath: transcriptPath,
            // `started` carries over from the ambiguous attempt, not reset —
            // this mutant's total duration honestly includes the batch time
            // it already spent before its own attribution came back
            // unusable, not just the recovery's own wall clock.
            started: dispatch.started, testStarted: Date()
        )

        let recoverySpanStart = GateTimingRecorder.shared.now()
        let run: TestRunResult
        do {
            run = try await runSchemataToken(
                state.artifact, in: state.sandbox, invocation: freshDispatch.invocation,
                timeoutSeconds: freshDispatch.resolvedTimeoutSeconds, selectedTests: freshDispatch.selectedTests
            )
        } catch {
            await GateTimingRecorder.shared.record(
                "token.batchAmbiguityRecovery.failed", chunkID: state.chunkLabel,
                mutationID: entry.mutationID.rawValue, start: recoverySpanStart
            )
            try? FileManager.default.removeItem(at: freshDispatch.evidenceDirectory)
            return processLaunchFailure(entry, point: freshDispatch.point, startedAt: freshDispatch.started, error: error)
        }
        await GateTimingRecorder.shared.record(
            "token.batchAmbiguityRecovery.total", chunkID: state.chunkLabel,
            mutationID: entry.mutationID.rawValue, start: recoverySpanStart
        )

        return await processPrimaryObservation(entry, dispatch: freshDispatch, run: run, attribution: .standalone, state: state)
    }

    /// One entry whose test process never even started. Not a forced
    /// timeout-kill: no `TestRunResult` was ever produced, so there is
    /// nothing for the schemata timeout-isolation design's containment trigger to key off, and none of
    /// the shared-sandbox residue risk it exists for applies — hence
    /// `primaryTimedOut: false`, unconditionally. Existing behavior,
    /// unaffected by this ADR; extracted from `runPrimary` only to keep that
    /// function's own body readable.
    func processLaunchFailure(
        _ entry: SchemataPlanEntry, point: MutationPoint, startedAt started: Date, error: any Error
    ) -> PrimaryOutcome {
        .settled(.verified(TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: finalize(point: point, infrastructureFailureDiagnosis: "the test process could not be run: \(error)"),
            durationSeconds: Date().timeIntervalSince(started),
            testDurationSeconds: nil
        )), primaryTimedOut: false)
    }

    /// Thin wrapper over `confirmSchemataToken` taking a `ChunkExecutionState`
    /// rather than separate `artifact`/`sandbox` parameters, so call sites in
    /// the scheduler read against the same state value Trigger 1's rebuild
    /// may just have replaced.
    func runConfirmation(
        _ requirement: ConfirmationRequirement, request: ConfirmationRequest, state: ChunkExecutionState,
        timeoutSeconds: Double, selectedTests: Set<TestIdentifier>?
    ) async -> ConfirmationObservation {
        await confirmSchemataToken(
            requirement, artifact: state.artifact, request: request, in: state.sandbox, timeoutSeconds: timeoutSeconds,
            selectedTests: selectedTests
        )
    }

    struct SourceLevelEvidence {
        let beforeHash: String
        let afterHash: String
        let diff: String
    }

    func sourceLevelEvidence(for point: MutationPoint) -> SourceLevelEvidence {
        guard let original = originalSources[point.file], let applied = try? MutationApplication.apply(point, to: original) else {
            return SourceLevelEvidence(beforeHash: point.sourceFileHash, afterHash: point.sourceFileHash, diff: "")
        }
        return SourceLevelEvidence(
            beforeHash: applied.evidence.sourceBeforeHash, afterHash: applied.evidence.sourceAfterHash, diff: applied.evidence.sourceDiff
        )
    }

    /// Used only where an entry's own `MutationPoint` may genuinely be
    /// absent (a chunk-level build/sandbox failure, before any per-mutant
    /// work starts) — `nil` when `points` has no entry for it, so the
    /// `compactMap` call sites drop it rather than fabricate a result with
    /// no anchor.
    func infrastructureFailureResult(for entry: SchemataPlanEntry, reason: String, startedAt: Date = Date()) -> TargetRecord? {
        guard let point = points[entry.mutationID] else { return nil }
        return TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: finalize(
                point: point, sourceApplication: chunkLevelSourceApplication(for: point), infrastructureFailureDiagnosis: reason
            ),
            durationSeconds: Date().timeIntervalSince(startedAt),
            testDurationSeconds: nil
        )
    }

    /// The chunk itself failed to build or produced no product hash, so no
    /// per-mutant test ever ran — but the source-level fact that this
    /// mutation was applied to the chunk's sources is still real and
    /// computable from `originalSources`, so it is honestly reported
    /// rather than omitted.
    private func chunkLevelSourceApplication(for point: MutationPoint) -> SourceApplicationOutcome {
        let sourceLevel = sourceLevelEvidence(for: point)
        return .applied(MutationEvidence(
            sourceBeforeHash: sourceLevel.beforeHash,
            sourceAfterHash: sourceLevel.afterHash,
            sourceDiff: sourceLevel.diff,
            buildProductHash: nil,
            applicationEvidence: nil,
            buildCommand: nil,
            testCommand: nil
        ))
    }

    /// Runs one already-built chunk's runtime against `token`, under its own
    /// fresh `runID`/`transcriptPath` — the one place `runEntry` and
    /// `confirmSchemataToken` both launch a schemata process, so a primary
    /// run and its confirmation are built from an identical invocation
    /// shape and can never drift apart from each other by accident.
    func runSchemataToken(
        _ artifact: BuildArtifact, in sandbox: URL, invocation: SchemataTokenInvocation,
        timeoutSeconds: Double, selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        try await test.runSchemataToken(
            artifact, in: sandbox, timeoutSeconds: timeoutSeconds,
            environment: invocation.environment,
            selectedTests: selectedTests
        )
    }

    /// What identifies one schemata process launch: the token it selects,
    /// where its transcript goes and which `RunID` it reports under. The
    /// single source of the environment every launch (single or batched)
    /// hands the test process.
    struct SchemataTokenInvocation {
        let token: SchemataSelectorToken
        let transcriptPath: URL
        let runID: RunID

        var environment: [String: String] {
            [
                SchemataEvidenceCollector.tokenEnvironmentVariable:
                    SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
                SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
                SchemataEvidenceCollector.runIDEnvironmentVariable:
                    SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
            ]
        }
    }

    /// Reads back whatever `runSchemataToken` actually wrote — empty (no
    /// transcript at all, malformed data) becomes an empty transcript,
    /// never a thrown error either caller has to handle specially: an
    /// empty transcript already fails the verifier's chain closed on its
    /// own.
    func schemataObservation(
        transcriptPath: URL, expectation: SchemataRunExpectation, receipt: SchemataBuildReceipt?
    ) -> SchemataExecutionObservation {
        let transcript = (try? SchemataEvidenceCollector.readTranscript(at: transcriptPath))
            ?? RuntimeTranscript(protocolVersion: 0, records: [])
        return SchemataExecutionObservation(expectation: expectation, buildReceipt: receipt, transcript: transcript)
    }

    /// Everything a confirmation attempt needs about the mutation it is
    /// confirming, bundled so `confirmSchemataToken` takes one thing rather
    /// than re-threading each of these individually through its own
    /// parameter list.
    struct ConfirmationRequest {
        let mutationID: MutationID
        let compilationUnitID: CompilationUnitID
        let sourceEmbeddingID: SHA256Digest
        let token: SchemataSelectorToken
        /// `var`, not `let` (the schemata timeout-isolation design): a request built by `runPrimary` at
        /// primary-run time carries that moment's receipt, but if Trigger 1
        /// rebuilds the chunk before this confirmation actually runs, the
        /// confirmation's own transcript is written against the *new*
        /// build's image UUID — `runEntries` must overwrite this field with
        /// the post-rebuild receipt before dispatching, or
        /// `schemataConfirmationChainProblem` will (correctly) reject the
        /// confirmation as inconsistent with a receipt from a build that no
        /// longer exists.
        var receipt: SchemataBuildReceipt?
        let originalFailingTests: [String]?
        let originalDiagnosis: String
    }

    /// Runs a genuinely independent confirmation attempt for `request`'s
    /// mutation — its own fresh `RunID`, its own transcript file, its own
    /// test process, requesting the exact same token against the exact
    /// same already-built artifact (the re-enabled schemata scoring): schemata mode never
    /// rebuilds to confirm, since the chunk's build already embeds every
    /// mutation and confirming is only ever a question of whether the
    /// runtime independently reaches and reports the same site again.
    /// Never reuses the primary run's own transcript, `RunID`, or process —
    /// `MutationVerdictVerifier.confirm` independently verifies this
    /// confirmation's own chain and refuses one that reused the original
    /// `RunID` (see `schemataConfirmationChainProblem`), so a shortcut here
    /// would only ever be caught downstream, never silently trusted.
    func confirmSchemataToken(
        _ requirement: ConfirmationRequirement, artifact: BuildArtifact, request: ConfirmationRequest, in sandbox: URL,
        timeoutSeconds: Double, selectedTests: Set<TestIdentifier>?
    ) async -> ConfirmationObservation {
        let kind: ConfirmationObservation.Kind = switch requirement {
        case .retestKilledMutant: .kill
        case .confirmCrash: .crash
        case .confirmTimeout: .timeout
        case .none: preconditionFailure("confirmSchemataToken must never be called for .none")
        }

        let runID = RunID()
        let evidenceDirectory = sandbox
            .appendingPathComponent(".mutantkit-schemata/\(request.mutationID.rawValue)-confirm-\(runID.rawValue.uuidString)")
        let transcriptPath = evidenceDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let run: TestRunResult
        do {
            run = try await runSchemataToken(
                artifact, in: sandbox,
                invocation: SchemataTokenInvocation(token: request.token, transcriptPath: transcriptPath, runID: runID),
                timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
            )
        } catch {
            return ConfirmationObservation(
                kind: kind, run: Self.infrastructureFailureRun("the confirmation process could not be run: \(error)"),
                originalFailingTests: request.originalFailingTests, originalDiagnosis: request.originalDiagnosis
            )
        }

        let expectation = SchemataRunExpectation(
            mutationID: request.mutationID, compilationUnitID: request.compilationUnitID, sourceEmbeddingID: request.sourceEmbeddingID,
            selectorToken: request.token, runID: runID
        )
        let observation = schemataObservation(transcriptPath: transcriptPath, expectation: expectation, receipt: request.receipt)
        // Only a retest that reproduced the failure can still become a confirmed kill.
        let control = kind == .kill && run.status == .failed
            ? await baselineControls.schemataControl(
                test: test, artifact: artifact, in: sandbox, timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
            )
            : nil
        return ConfirmationObservation(
            kind: kind, run: run, schemataObservation: observation,
            originalFailingTests: request.originalFailingTests, originalDiagnosis: request.originalDiagnosis,
            baselineControl: control
        )
    }

    /// A synthetic run standing in for "a confirmation attempt could not
    /// even launch" — mirrors `MutationConfirmationCoordinator.infrastructureFailureRun`
    /// exactly, the same convention for the same reason: represented as an
    /// ordinary `TestRunResult` so it flows through `ConfirmationObservation`
    /// like any other confirming run.
    static func infrastructureFailureRun(_ diagnosis: String) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil,
            command: CommandRecord(executable: "", arguments: [], workingDirectory: ""),
            resultArtifactPath: nil, diagnosis: diagnosis
        )
    }
}
