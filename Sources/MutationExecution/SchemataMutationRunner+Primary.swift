import Foundation
import MutationModel

/// Per-mutant primary runs for `SchemataMutationRunner`.
extension SchemataMutationRunner {
    /// What `runPrimary` produced for one entry: either a fully resolved
    /// outcome (`.settled` — no confirmation was needed, or none could be
    /// gathered), or everything `runEntries` needs to gather a confirmation
    /// itself (`.needsConfirmation`) — confirmation dispatch is owned by the
    /// scheduler, not by this function, specifically so the scheduler can
    /// interpose a containment rebuild between the primary run and the
    /// confirmation run when the schemata timeout-isolation design requires one (Trigger 1).
    enum PrimaryOutcome {
        case settled(EntryRunOutcome, primaryTimedOut: Bool)
        case needsConfirmation(ConfirmationHandoff)
    }

    /// Everything `runEntries` needs to gather and finalize a confirmation
    /// for one entry, once `runPrimary` has determined one is required —
    /// the primary run's own evidence, captured once and threaded through
    /// unchanged (a confirmation never re-derives it), plus `primaryTimedOut`
    /// so the scheduler knows whether Trigger 1 applies without re-deriving
    /// it from `testObservation.run.status` itself.
    struct ConfirmationHandoff {
        let requirement: ConfirmationRequirement
        let request: ConfirmationRequest
        let point: MutationPoint
        let evidence: MutationEvidence
        let buildObservation: BuildObservation
        let testObservation: SingleTestObservation
        let targetIdentity: TargetExecutionIdentity
        let startedAt: Date
        let testStartedAt: Date
        let primaryTimedOut: Bool
        /// The exact same selection the primary run itself used — never
        /// recomputed or widened for the confirmation. A confirmation
        /// re-tests the same mutant to verify a kill/timeout is real, not a
        /// fluke, so it must exercise the same tests the primary run did.
        let selectedTests: Set<TestIdentifier>?
        /// The exact per-mutant limit the primary run itself was resolved
        /// against (`TimeoutController.mutantLimitSeconds(selectedTests:
        /// coverage:)`, computed once in `runPrimary`) — carried through so
        /// the confirmation run reuses it verbatim instead of re-resolving
        /// it, which the confirmation's own artifact/sandbox context has no
        /// business doing differently from the run it is confirming.
        let resolvedTimeoutSeconds: Double
    }

    /// Everything about one entry that is known *before* its primary test
    /// process ever runs — resolved once, whether that run turns out to be
    /// an individual `runSchemataToken` call (today's only path) or a
    /// Everything about one entry that is known *before* its primary test
    /// process ever runs — resolved once, whether that run turns out to be
    /// an individual `runSchemataToken` call (today's only path) or a
    /// looked-up member of a shared batch call: the two origins share this
    /// exact same shape, so `processPrimaryObservation` never needs to know
    /// or care which one produced its `TestRunResult`.
    struct PrimaryDispatch {
        let token: SchemataSelectorToken
        let sourceEmbeddingID: SHA256Digest
        let point: MutationPoint
        let compilationUnitID: CompilationUnitID
        let selectedTests: Set<TestIdentifier>?
        let resolvedTimeoutSeconds: Double
        let runID: RunID
        let evidenceDirectory: URL
        let transcriptPath: URL
        let started: Date
        let testStarted: Date

        var invocation: SchemataTokenInvocation {
            SchemataTokenInvocation(token: token, transcriptPath: transcriptPath, runID: runID)
        }
    }

    /// The identifying fields of one transcript record, whichever event
    /// shape it is — what the dynamic-fallback diagnostics compare against
    /// the expectation.
    struct TranscriptRecordFacts {
        let kind: String
        let runID: RunID
        let unitID: CompilationUnitID
        let token: SchemataSelectorToken

        init(_ record: RuntimeEventRecord) {
            switch record {
            case let .startup(event):
                self.init(kind: "startup", runID: event.runID, unitID: event.compilationUnitID, token: event.token)
            case let .hit(event):
                self.init(kind: "hit", runID: event.runID, unitID: event.compilationUnitID, token: event.token)
            }
        }

        private init(kind: String, runID: RunID, unitID: CompilationUnitID, token: SchemataSelectorToken) {
            self.kind = kind
            self.runID = runID
            self.unitID = unitID
            self.token = token
        }
    }

    /// `prepareDispatch`'s result: either this entry is already fully
    /// decided without ever running a test (`.settled` — the
    /// `knownUncovered` fast path), or it is ready to be dispatched — by
    /// either caller shape — for a real token run.
    enum PrimaryDispatchOutcome {
        case settled(PrimaryOutcome)
        case dispatched(PrimaryDispatch)
    }

    /// The pre-run half of what used to be `runPrimary` end to end: every
    /// guard, precondition, and pure-logic resolution that must happen
    /// *before* a token is ever dispatched — unchanged in content or order
    /// from the original function, only extracted so a batched caller can
    /// resolve every entry's own dispatch up front, before deciding how to
    /// group them, without duplicating any of this reasoning.
    private func prepareDispatch(
        _ entry: SchemataPlanEntry, state: ChunkExecutionState, timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) -> PrimaryDispatchOutcome {
        // `token`/`sourceEmbeddingID` are always non-nil here: `entries` was
        // already filtered to `isEmbedded` entries by the caller, and both
        // are only ever `nil` for `.isolatedFallback` placements. `point`
        // is a caller contract, not a runtime condition: `points` must
        // cover every `MutationID` in `programs`, the same completeness
        // `SchemataPlan.decodeAndValidate` already enforces between a plan
        // and its entries.
        guard
            let token = entry.selectorToken, let sourceEmbeddingIDString = entry.sourceEmbeddingID,
            let sourceEmbeddingID = SHA256Digest(rawValue: sourceEmbeddingIDString)
        else {
            preconditionFailure("a schemata-embedded entry must carry a selector token and source embedding ID")
        }
        guard let point = points[entry.mutationID] else {
            preconditionFailure("no MutationPoint supplied for embedded mutation \(entry.mutationID.rawValue)")
        }
        let compilationUnitID = Self.compilationUnitID(for: entry, point: point)

        // Fast path: a baseline coverage map that already proves this line
        // was never executed makes a schemata token attempt pointless —
        // isolated mode would reach the identical `.noCoverage` verdict for
        // free (`MutationRunner.prepare(...)`'s own identical check), so
        // this entry is routed to isolated fallback *before* paying for a
        // build-already-done-but-test-still-real token run, not after
        // discovering the same fact via `noStartup` (see
        // `SchemataFallbackReason.knownUncovered`'s own doc comment).
        if let coverage, coverage.isKnownUncovered(point) {
            return .settled(.settled(.isolatedFallback(mutationID: entry.mutationID, reason: .knownUncovered), primaryTimedOut: false))
        }

        // An empty result is never used: it would mean "run nothing", which
        // a coverage-blind run can't tell apart from a mutant with no
        // covering test at all. `nil` — unknown attribution, or none
        // configured — always falls back to the full configured test list
        // inside the adapter, mirroring `MutationRunner`'s own lookup at its
        // equivalent call site exactly.
        let selectedTests = perTestCoverage
            .flatMap { $0.testsCovering(file: point.file, line: point.line) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Selected-test-clamped when this entry has a known, non-empty
        // selection, the same whole-suite-scaled fallback isolated mode uses
        // otherwise — resolved once, here, and reused verbatim by this
        // entry's confirmation (see `ConfirmationHandoff
        // .resolvedTimeoutSeconds`), never recomputed downstream.
        let resolvedTimeoutSeconds = timeoutController.mutantLimitSeconds(selectedTests: selectedTests)

        let started = Date()
        let runID = RunID()
        let evidenceDirectory = state.sandbox.appendingPathComponent(".mutantkit-schemata/\(entry.mutationID.rawValue)")
        let transcriptPath = evidenceDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        return .dispatched(PrimaryDispatch(
            token: token, sourceEmbeddingID: sourceEmbeddingID, point: point, compilationUnitID: compilationUnitID,
            selectedTests: selectedTests, resolvedTimeoutSeconds: resolvedTimeoutSeconds, runID: runID,
            evidenceDirectory: evidenceDirectory, transcriptPath: transcriptPath, started: started, testStarted: Date()
        ))
    }

    func primaryOutcomeOrPrefetched(
        _ preFetched: PrimaryOutcome?, entry: SchemataPlanEntry, state: ChunkExecutionState,
        timeoutController: TimeoutController, perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) async -> PrimaryOutcome {
        if let preFetched { return preFetched }
        return await runPrimary(
            entry, state: state, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage
        )
    }

    /// Collects raw observations only (the schemata proof chain) — this runner
    /// decides nothing about whether the mutation was proven built,
    /// selected, or hit. It runs the process, reads back whatever
    /// transcript it wrote (however empty or malformed), and hands the
    /// whole unfiltered result to `MutationVerdictVerifier
    /// .verifySchemataChain` inside a `SchemataExecutionObservation` —
    /// the only place that chain is ever built or judged.
    ///
    /// Never dispatches a confirmation itself (the schemata timeout-isolation design): whether one is
    /// needed is decided here, but gathering it — and, when required,
    /// interposing a containment rebuild first — is `runEntries`' job, since
    /// only the scheduler knows what else remains in the chunk to protect.
    ///
    /// Orchestrates `prepareDispatch` + an individual `runSchemataToken`
    /// call + `processPrimaryObservation` — the unbatched path every entry
    /// still takes today. A batched caller calls
    /// `prepareDispatch`/`processPrimaryObservation` directly instead,
    /// substituting a shared `runSchemataTokenBatch` call for the
    /// individual one in between; nothing in either helper changes to
    /// support that.
    func runPrimary(
        _ entry: SchemataPlanEntry, state: ChunkExecutionState, timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) async -> PrimaryOutcome {
        let dispatch: PrimaryDispatch
        switch prepareDispatch(
            entry, state: state, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage
        ) {
        case let .settled(outcome): return outcome
        case let .dispatched(resolved): dispatch = resolved
        }

        let tokenSpanStart = GateTimingRecorder.shared.now()
        let run: TestRunResult
        do {
            run = try await runSchemataToken(
                state.artifact, in: state.sandbox, invocation: dispatch.invocation,
                timeoutSeconds: dispatch.resolvedTimeoutSeconds, selectedTests: dispatch.selectedTests
            )
        } catch {
            await GateTimingRecorder.shared.record(
                "token.total.failed", chunkID: state.chunkLabel, mutationID: entry.mutationID.rawValue, start: tokenSpanStart
            )
            try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)
            return processLaunchFailure(entry, point: dispatch.point, startedAt: dispatch.started, error: error)
        }
        await GateTimingRecorder.shared.record(
            "token.total", chunkID: state.chunkLabel, mutationID: entry.mutationID.rawValue, start: tokenSpanStart
        )

        return await processPrimaryObservation(entry, dispatch: dispatch, run: run, attribution: .standalone, state: state)
    }

    /// The post-run half of what used to be `runPrimary` end to end —
    /// unchanged in content, order, or meaning from the original function's
    /// tail, only reading `run`/`dispatch`'s fields where it used to read
    /// locals of the same name. Deletes `dispatch.evidenceDirectory`
    /// itself, after reading the transcript from it (`schemataObservation`)
    /// — the same lifetime the original function's `defer` gave it, just no
    /// longer expressible as a `defer` once `run` can arrive from a batch
    /// lookup made by a *different* function than the one that created
    /// this directory.
    func processPrimaryObservation(
        _ entry: SchemataPlanEntry, dispatch: PrimaryDispatch, run: TestRunResult, attribution: TestExecutionRecord.Attribution,
        state: ChunkExecutionState
    ) async -> PrimaryOutcome {
        defer { try? FileManager.default.removeItem(at: dispatch.evidenceDirectory) }

        let expectation = SchemataRunExpectation(
            mutationID: entry.mutationID, compilationUnitID: dispatch.compilationUnitID, sourceEmbeddingID: dispatch.sourceEmbeddingID,
            selectorToken: dispatch.token, runID: dispatch.runID
        )
        let observation = schemataObservation(transcriptPath: dispatch.transcriptPath, expectation: expectation, receipt: state.receipt)

        let sourceLevel = sourceLevelEvidence(for: dispatch.point)
        let evidence = MutationEvidence(
            sourceBeforeHash: sourceLevel.beforeHash,
            sourceAfterHash: sourceLevel.afterHash,
            sourceDiff: sourceLevel.diff,
            buildProductHash: state.artifact.productHash,
            applicationEvidence: .schemata(observation),
            buildCommand: state.artifact.command,
            testCommand: run.command
        )
        let buildObservation = BuildObservation(
            outcome: .succeeded(buildProductHash: state.artifact.productHash, command: state.artifact.command)
        )
        let testObservation = SingleTestObservation(
            run: run, applicationEvidence: .schemata(observation),
            execution: TestExecutionRecord(attribution: attribution, selectedTests: dispatch.selectedTests?.map(\.onlyTestingArgument))
        )

        let preliminary = preliminaryObservations(
            point: dispatch.point, sourceApplication: .applied(evidence), build: buildObservation, test: testObservation
        )

        // Checked before `confirmationRequirement` is even asked (Group 2:
        // no-HIT/no-STARTUP -> isolated fallback): a passing test with no
        // proof this mutation was ever selected/hit gets no confirmation
        // gathered and no `finalize` call here at all — `run()` drops
        // every target placement for this MutationID and
        // `SchemataRunOrchestration` re-runs it through isolated mode from
        // scratch, which will build its own, independent proof chain.
        // Never widen this beyond what `schemataIsolatedFallbackReason`
        // itself already scopes to (see that function's own doc comment) —
        // in particular, this routing is scoped to *passing* runs, so
        // `run.status == .timedOut` here is always false in practice; kept
        // as a real check rather than a hardcoded `false` so this stays
        // correct even if that scoping ever changes.
        if let reason = MutationVerdictVerifier.schemataIsolatedFallbackReason(for: preliminary) {
            // Diagnostic only (see `GateTimingRecorder`'s own doc comment)
            // — for each transcript record present but not matching what
            // this token expected, which field(s) actually differ: a
            // different `compilationUnitID`/token (another mutation in the
            // same chunk registered/hit instead) versus a different `runID`
            // (evidence from a stale or unrelated invocation). One span per
            // record, not one summary string, so each is independently
            // readable.
            for (index, record) in observation.transcript.records.enumerated() {
                let facts = TranscriptRecordFacts(record)
                let kind = facts.kind
                let runIDMatch = facts.runID == expectation.runID ? "runID=match" : "runID=DIFFERENT(\(facts.runID.rawValue))"
                let unitMatch = facts.unitID == expectation.compilationUnitID ? "unit=match" : "unit=DIFFERENT(\(facts.unitID))"
                let tokenMatch = facts.token == expectation.selectorToken ? "token=match" : "token=DIFFERENT(\(facts.token))"
                await GateTimingRecorder.shared.record(
                    "dynamicFallback.activation.\(reason).record[\(index)] kind=\(kind) \(runIDMatch) \(unitMatch) \(tokenMatch)",
                    mutationID: entry.mutationID.rawValue, start: GateTimingRecorder.shared.now()
                )
            }
            await GateTimingRecorder.shared.record(
                "dynamicFallback.activation.\(reason) selectedTests=\(dispatch.selectedTests?.count.description ?? "nil") "
                    + "transcriptRecords=\(observation.transcript.records.count) expectedRunID=\(expectation.runID.rawValue) "
                    + "expectedUnit=\(expectation.compilationUnitID) expectedToken=\(expectation.selectorToken)",
                mutationID: entry.mutationID.rawValue, start: GateTimingRecorder.shared.now()
            )
            return .settled(
                .isolatedFallback(mutationID: entry.mutationID, reason: .activation(reason)),
                primaryTimedOut: run.status == .timedOut
            )
        }

        // The same single source of truth `MutationRunner`'s own
        // confirmation gates ultimately encode — never a policy check this
        // runner re-derives on its own (the re-enabled schemata scoring).
        //
        // Never a cascade of more than one confirmation, unlike
        // `MutationConfirmationCoordinator.confirmTimeout`'s own nested `retestKilledMutants`/
        // `confirmCrashKills` calls: that cascade only fires for a
        // *batch-attributed* timeout (`TestRunResult.isBatchAttributedTimeout`,
        // set only by isolated mode's own `runBatch`). Schemata batching
        // never sets it either — `runSchemataTokenBatch`'s own results,
        // like `runSchemataToken`'s, are individually attributed per
        // `MutationID` from the start, never an ambiguous batch-wide
        // placeholder — so a schemata timeout's own `isBatchAttributedTimeout`
        // is always `false` whether or not this entry's primary came from a
        // batch call, and `MutationVerdictVerifier.confirmTimeout`'s cascade
        // branch stays structurally unreachable here: a schemata timeout
        // confirmation that finishes normally is `.flaky`, exactly like
        // isolated mode's own non-batch-attributed case, never promoted to
        // a kill — proven by `SchemataConfirmationCrashTimeoutVerifierTests
        // .timeoutConfirmationFinishingNormallyIsFlakyNotCascaded`. There is
        // therefore no second confirmation for this runner to ever gather.
        let requirement = MutationVerdictVerifier.confirmationRequirement(for: preliminary, policy: session.policy)
        let primaryTimedOut = run.status == .timedOut

        guard requirement != .none else {
            let record = finalize(
                point: dispatch.point, sourceApplication: .applied(evidence), build: buildObservation, test: testObservation
            )
            return .settled(.verified(TargetRecord(
                targetIdentity: Self.targetIdentity(for: entry),
                record: record,
                durationSeconds: Date().timeIntervalSince(dispatch.started),
                testDurationSeconds: Date().timeIntervalSince(dispatch.testStarted)
            )), primaryTimedOut: primaryTimedOut)
        }

        let request = ConfirmationRequest(
            mutationID: entry.mutationID, compilationUnitID: dispatch.compilationUnitID, sourceEmbeddingID: dispatch.sourceEmbeddingID,
            token: dispatch.token, receipt: state.receipt, originalFailingTests: run.summary?.failingTests, originalDiagnosis: run.diagnosis
        )
        return .needsConfirmation(ConfirmationHandoff(
            requirement: requirement, request: request, point: dispatch.point, evidence: evidence,
            buildObservation: buildObservation, testObservation: testObservation,
            targetIdentity: Self.targetIdentity(for: entry), startedAt: dispatch.started, testStartedAt: dispatch.testStarted,
            primaryTimedOut: primaryTimedOut, selectedTests: dispatch.selectedTests,
            resolvedTimeoutSeconds: dispatch.resolvedTimeoutSeconds
        ))
    }

    /// Resolves as many `embeddedEntries` as possible into already-run
    /// `PrimaryOutcome`s via one or more shared `runSchemataTokenBatch`
    /// calls, before `runEntries`' sequential per-entry scheduler ever
    /// starts. Every `MutationID` this returns a value for has already been
    /// dispatched — the caller substitutes it directly; every entry absent
    /// from the result (batching unsupported, ineligible, or disabled) is
    /// untouched and falls through to `runEntries`' existing individual
    /// `runPrimary` call, exactly as before batching existed.
    ///
    /// Never revisited once returned: entries covered here have their
    /// *final* primary result before the schemata timeout-isolation design's Trigger 1/2 rebuild logic
    /// runs for anything in this chunk. A later rebuild — triggered by some
    /// *other* entry's own timeout, individual or (once containment fires)
    /// native — never needs to touch these: each one's own evidence chain
    /// (`compilationUnitID`/`runID`/`sourceEmbeddingID`/token matching,
    /// enforced identically for a batched or unbatched primary) already
    /// proves its own result independently of whatever a sibling
    /// configuration in the same batch did. Confirmed directly, not
    /// assumed: real acceptance evidence is a batch where a sibling
    /// configuration's hang did not affect another configuration's
    /// already-passing result, an unrelated `xcodebuild` invocation from
    /// this runner's perspective in every way that matters here. Trigger
    /// 1/2's actual purpose — protecting a *future, not-yet-run* individual
    /// spawn from a shared sandbox a forced kill may have left unverified —
    /// is simply moot for an entry whose primary already ran as part of
    /// this same batch; it still fires, unweakened, for that entry's own
    /// *confirmation* (always an individual, never-batched run — batching
    /// never touches confirmation dispatch at all) and for any entry in a
    /// later, not-yet-dispatched batch group.
    func prepareBatchedPrimaries(
        _ embeddedEntries: [SchemataPlanEntry], state: ChunkExecutionState, timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) async -> [MutationID: PrimaryOutcome] {
        // `<= 1` (the default): batching disabled outright, the same
        // opt-in-by-default-value convention `workers` uses. Adapter
        // conformance is optional, mirroring `BatchTestable`: one that does
        // not conform simply never gets asked, and every entry runs the
        // unbatched way exactly as it always has.
        guard schemataTokenBatchSize > 1, let batchable = batchableTest else { return [:] }

        var dispatchesByMutationID: [MutationID: PrimaryDispatch] = [:]
        for entry in embeddedEntries {
            guard
                case let .dispatched(dispatch) = prepareDispatch(
                    entry, state: state, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage
                ),
                // A token with more than one selected test can
                // independently hang on *any* of them — native per-test
                // timeout catches each one correctly, but a batch
                // containing such a token still pays up to
                // `coveringTests × mutantLimitSeconds` for it, confirmed
                // against a real production app. Isolated mode's fix for
                // the equivalent case was wave-based early-abort, which
                // schemata batching has no analogue of — rather than build
                // one for a lever token batching already measured at only
                // ~3% overall, only a token whose own selection is exactly
                // one test is eligible to share a batch: native timeout can
                // then only ever fire once for that mutant's own
                // configuration, so no batch member can cost more than its
                // own `mutantLimitSeconds`. A multi-test token still runs —
                // through the existing, unaffected unbatched
                // `runPrimary`/`runSchemataToken` path, whose own
                // per-mutant outer timeout already bounds it without any
                // cascade risk.
                let selectedTests = dispatch.selectedTests, selectedTests.count == 1
            else { continue }
            dispatchesByMutationID[entry.mutationID] = dispatch
        }

        // A "batch" of one has no containment benefit over the unbatched
        // path (the same single-member skip isolated mode's own
        // `testOneBatch`/`testWaveChunk` already applies) — and every other
        // entry (ineligible, or the sole eligible one here) still needs to
        // run through `runPrimary`'s own, unaffected `prepareDispatch` call,
        // so any evidence directory already created above must be cleaned
        // up now rather than left for `runPrimary` to silently overwrite.
        guard dispatchesByMutationID.count > 1 else {
            for dispatch in dispatchesByMutationID.values {
                try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)
            }
            return [:]
        }

        // Every eligible entry resolves to the identical limit today
        // (`TimeoutController.mutantLimitSeconds(selectedTests:)` no longer
        // varies by selection width — see its own doc comment); asserted
        // here, not assumed, so a future divergence fails this batch
        // attempt closed (falls through to the unbatched path for
        // everything) rather than silently mis-timing one entry against
        // another's budget.
        let resolvedAllowances = Set(dispatchesByMutationID.values.map(\.resolvedTimeoutSeconds))
        guard let sharedAllowance = resolvedAllowances.first, resolvedAllowances.count == 1 else {
            for dispatch in dispatchesByMutationID.values {
                try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)
            }
            return [:]
        }
        // An empirically-validated floor — the only value ever actually
        // exercised against a real hang — mirroring
        // `MutationRunner.testOneBatch`/`testWaveChunk`'s identical guard.
        let nativeTimeoutAllowanceSeconds = sharedAllowance >= 60 ? sharedAllowance : nil

        let entriesByMutationID = Dictionary(uniqueKeysWithValues: embeddedEntries.map { ($0.mutationID, $0) })
        let dispatchGroups = dispatchesByMutationID.map { ($0.key, $0.value) }
        var outcomes: [MutationID: PrimaryOutcome] = [:]

        for chunkStart in stride(from: 0, to: dispatchGroups.count, by: schemataTokenBatchSize) {
            let group = Array(dispatchGroups[chunkStart ..< min(chunkStart + schemataTokenBatchSize, dispatchGroups.count)])
            let items = group.map { mutationID, dispatch in
                SchemataBatchTokenItem(
                    mutationID: mutationID,
                    environment: dispatch.invocation.environment,
                    selectedTests: dispatch.selectedTests
                )
            }
            // The outer, aggregate fail-safe — summed across the group,
            // never replaced by `nativeTimeoutAllowanceSeconds` — mirrors
            // isolated mode's own `testOneBatch`/`testWaveChunk` batch
            // timeout exactly: if native containment somehow fails to fire
            // for some reason outside this runner's control, the outer
            // supervisor still has a generous-enough budget for every
            // member to finish normally before it would ever intervene.
            let outerTimeoutSeconds = Double(group.count) * sharedAllowance
            let tokenSpanStart = GateTimingRecorder.shared.now()
            let runs = await batchable.runSchemataTokenBatch(
                state.artifact, in: state.sandbox, items: items, timeoutSeconds: outerTimeoutSeconds,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
            await GateTimingRecorder.shared.record(
                "token.batch.total", chunkID: state.chunkLabel, start: tokenSpanStart
            )

            for (mutationID, dispatch) in group {
                guard let entry = entriesByMutationID[mutationID] else { continue }
                let run = runs[mutationID] ?? TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: state.artifact.command, resultArtifactPath: nil,
                    diagnosis: "This token's outcome went unreported by the batch classifier."
                )
                // `.infrastructureFailure` from a shared batch call —
                // whether `classifyBatch` itself produced it (no
                // per-configuration evidence in the result bundle) or it
                // was synthesized just above (missing from `runs` entirely)
                // — means the *shared invocation's* attribution failed for
                // this one mutant, not that the mutant is unprovable. Every
                // other status a batch can produce (`.passed`/`.failed`/
                // `.crashed`/`.timedOut`) is an independently usable
                // observation about this configuration specifically and is
                // never retried here.
                outcomes[mutationID] = run.status == .infrastructureFailure
                    ? await recoverAmbiguousBatchedPrimary(entry, dispatch: dispatch, state: state)
                    : await processPrimaryObservation(entry, dispatch: dispatch, run: run, attribution: .batch, state: state)
            }
        }
        return outcomes
    }
}
