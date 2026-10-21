import MutationModel

extension MutationRunner {
    /// Wave-based early kill: the batched replacement for
    /// `PrioritizingTestAdapter`'s one-test-per-invocation strategy.
    ///
    /// Each wave creates one batch invocation where every surviving mutant
    /// runs exactly ONE covering test — the next in its priority-ordered
    /// list. Mutants whose test fails this wave are killed and stop.
    /// Mutants whose test passes advance to their next test in the next
    /// wave. A mutant that exhausts its covering tests without ever failing
    /// one is `.survived`.
    ///
    /// The fixed per-invocation cost (~30s of simulator install/launch) is
    /// paid once per wave, not once per (mutant × covering-test) pair: a run
    /// with 50 mutants and 5 covering tests each pays it 5 times (one per
    /// wave) instead of 250 times (one per test per mutant, as wrapping the
    /// adapter one test at a time would). Killed mutants also drop out of
    /// later waves, so wave 2 onward tests strictly fewer mutants than the
    /// wave before it.
    ///
    /// Mutants without covering-test attribution (coverage was not
    /// measured, or the map has nothing to say about their line) are tested
    /// with their full configured test list before the wave loop starts —
    /// each in its own chunk, never bundled together (see
    /// `testUnattributed`) — and do not participate in subsequent waves,
    /// the same safe fallback every other selected-tests path in this file
    /// uses for `selectedTests ==
    /// nil`.
    ///
    /// `readyToTest` entries reach here exactly as `testAndFinish`'s other
    /// callers hand them off — a mutant's own fresh sandbox from
    /// `evaluateInBatches`, or a cloned products directory from
    /// `evaluateIncrementallyInBatches` — so this needs no sandbox-lifetime
    /// handling of its own: the worker sandbox that built a clone is kept
    /// alive by the caller until `testAndFinish` (and therefore every wave
    /// here) has returned, exactly as it is for the non-wave batch path.
    func testInWaves(
        readyToTest: [PreparedMutant],
        baseline: BaselineContext,
        store: TestPriorityStore,
        batchable: any BatchTestable,
        batchSize: Int
    ) async -> (results: [MutationResult], batchExecution: BatchExecutionSummary) {
        var results: [MutationResult] = []
        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []

        // Partition: mutants with a known, non-empty covering-test
        // selection go into the wave loop, ordered by historical kill
        // usefulness; everything else (no attribution at all) runs its
        // full test list and is done after wave 1.
        var waveSurvivors: [WaveSurvivor] = []
        var unattributed: [PreparedMutant] = []
        // Sorted by `MutationID` before partitioning, not left in whatever
        // order builds happened to finish in — wave 1's batch composition
        // (and therefore which mutants share timing ambiguity with which)
        // must be reproducible the same way `testOneWave` makes every later
        // wave's composition reproducible.
        for prepared in readyToTest.sorted(by: { $0.point.id < $1.point.id }) {
            if let tests = prepared.selectedTests, !tests.isEmpty {
                let ordered = await store.order(tests)
                waveSurvivors.append(WaveSurvivor(prepared: prepared, remainingTests: ordered))
            } else {
                unattributed.append(prepared)
            }
        }

        if !unattributed.isEmpty {
            let outcome = await testUnattributed(
                unattributed, baseline: baseline, batchable: batchable
            )
            results.append(contentsOf: outcome.results)
            batchCount += outcome.batchCount
            totalConfigurations += unattributed.count
            batchDurations.append(contentsOf: outcome.batchDurations)
        }

        // Wave loop for attributed mutants. `waveIndex` is part of every
        // sandbox ID this wave creates (see `testOneWave`) — without it,
        // wave 2's first chunk would reuse wave 1's first chunk's sandbox ID
        // verbatim (`chunkStart` alone resets to 0 every call), and a
        // creation racing a not-yet-finished destroy of the same path fails
        // closed as an infrastructure failure instead of testing at all.
        // Caught for real on a live Xcode project: a mutant that should have
        // been `killedByAssertion` in wave 2 came back `infrastructureFailure`
        // because its chunk's sandbox ID collided with wave 1's.
        var waveIndex = 0
        while !waveSurvivors.isEmpty {
            let wave = await testOneWave(
                waveSurvivors, waveIndex: waveIndex, baseline: baseline, store: store, batchable: batchable, batchSize: batchSize
            )
            results.append(contentsOf: wave.results)
            batchCount += wave.batchCount
            totalConfigurations += wave.totalConfigurations
            batchDurations.append(contentsOf: wave.batchDurations)
            waveSurvivors = wave.nextSurvivors
            waveIndex += 1
        }

        return (
            results,
            BatchExecutionSummary(batchCount: batchCount, totalConfigurations: totalConfigurations, batchDurations: batchDurations)
        )
    }

    /// What `testOneWave` hands back to the wave loop: the results it
    /// finished, the survivors that advance to the next wave, and the batch
    /// statistics it spent doing so.
    struct WaveOutcome {
        var results: [MutationResult] = []
        var nextSurvivors: [WaveSurvivor] = []
        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []
    }

    /// What `testWaveChunk` produced for one chunk; `duration` is `nil` when
    /// no batched run happened.
    struct WaveChunkOutcome {
        var results: [MutationResult] = []
        var nextSurvivors: [WaveSurvivor] = []
        var duration: Double?
    }

    /// One chunk's shared batch run: every configuration's reported result,
    /// and the even share of the batch's wall clock each member is charged.
    struct WaveChunkBatch {
        let runs: [MutationID: TestRunResult]
        let perMutantShare: Double
    }

    /// What `testUnattributed` produced for the mutants with no covering-test
    /// attribution.
    struct UnattributedOutcome {
        let results: [MutationResult]
        let batchCount: Int
        let batchDurations: [Double]
    }

    struct WaveSurvivor: Sendable {
        let prepared: PreparedMutant
        let remainingTests: [TestIdentifier]
        /// Real test time this mutant has consumed across every wave so
        /// far — never wall clock since `prepared.startedAt`, which also
        /// counts build time and time spent waiting behind every other
        /// mutant's build/chunk and would keep accumulating even while this
        /// mutant is not being tested at all.
        var cumulativeTestSeconds: Double = 0
        /// The most recent wave's real `TestRunResult` — carried forward so
        /// a mutant that later exhausts its list or expires its budget
        /// reports its actual last test command and result artifact, not a
        /// synthetic placeholder. `nil` only before this survivor's first
        /// wave has run at all.
        var lastRun: TestRunResult?
        /// Every earlier wave this survivor passed, each with its own
        /// preserved result artifact — see `TestAttemptEvidence`. Without
        /// this, only the mutant's LAST wave's evidence would survive to the
        /// final report, silently dropping every earlier wave's.
        var attempts: [TestAttemptEvidence] = []
    }

    /// One iteration of the wave loop: classifies exhausted and
    /// budget-expired survivors, then chunks whoever is left into batches of
    /// at most `batchSize` (see `MutationRunnerBatchTestingTests` and
    /// codex's review of this branch — an earlier version ignored
    /// `batchSize` entirely and put every survivor in one batch, defeating
    /// the resource bound it exists to enforce) and tests each chunk's next
    /// prioritised test.
    func testOneWave(
        _ waveSurvivors: [WaveSurvivor],
        waveIndex: Int,
        baseline: BaselineContext,
        store: TestPriorityStore,
        batchable: any BatchTestable,
        batchSize: Int
    ) async -> WaveOutcome {
        var results: [MutationResult] = []

        // Survivors that have run out of covering tests without ever
        // failing one → survived. Checked at the top of every wave, not
        // just once, because a mutant can only reach this state after
        // advancing past its last test in a previous wave.
        //
        // Checked ahead of the budget-expiry filter below on purpose: a
        // mutant that finished every one of its covering tests has a
        // complete, definitive answer, even if the wave that produced it
        // pushed cumulative time slightly past the budget. The budget
        // exists to bound how long an *unresolved* mutant gets waited on,
        // not to discard a result that did resolve.
        let exhausted = waveSurvivors.filter { $0.remainingTests.isEmpty }
        for survivor in exhausted {
            // command/resultArtifactPath come from the actual last wave's
            // test run, not the build artifact — this mutant was tested,
            // repeatedly, and the evidence should point at that, not at how
            // it was built. Falls back to the build command only in the
            // unreachable-in-practice case of a survivor with no prior wave
            // at all (remainingTests starts non-empty, so exhausting it
            // requires at least one).
            let lastRun = survivor.lastRun
            // `appendCurrentAttempt` stays false: this synthetic "all waves
            // passed" run only restates the last real wave's own result,
            // which `survivor.attempts` already recorded when that wave's
            // advance branch ran — appending it again here would duplicate
            // it rather than add anything new.
            let result = await finishAfterTest(
                survivor.prepared, baseline: baseline,
                run: TestRunResult(
                    status: .passed, summary: lastRun?.summary,
                    command: lastRun?.command ?? survivor.prepared.artifact.command,
                    resultArtifactPath: lastRun?.resultArtifactPath,
                    diagnosis: "All \(survivor.prepared.selectedTests?.count ?? 0) covering test(s) passed across every wave."
                ),
                attribution: .batch,
                testDurationSeconds: survivor.cumulativeTestSeconds,
                priorTestAttempts: survivor.attempts
            )
            try? await workspaces.destroy(survivor.prepared.workspace)
            results.append(result)
        }

        // A survivor's total *test* time across every wave it has been
        // through is bounded by the same mutantLimitSeconds a single-
        // invocation test would have gotten — otherwise a mutant with many
        // covering tests could accumulate coveringTests × mutantLimitSeconds
        // of wall clock, and the setting would no longer bound what it
        // promises to. Measured against `cumulativeTestSeconds`, not wall
        // clock since `prepared.startedAt`: that also counts build time and
        // time spent waiting behind every other mutant's build/chunk, so a
        // mutant could be timed out before its first test ever ran.
        let (budgetExpired, stillAlive) = waveSurvivors
            .filter { !$0.remainingTests.isEmpty }
            .reduce(into: (expired: [WaveSurvivor](), alive: [WaveSurvivor]())) { partial, survivor in
                // Each survivor's own budget — selected-test-clamped where it
                // has a known, non-empty covering-test selection,
                // whole-suite-scaled otherwise — not one shared number every
                // survivor is measured against regardless of how narrow its
                // own selection is.
                let mutantLimitSeconds = baseline.timeouts.mutantLimitSeconds(
                    selectedTests: survivor.prepared.selectedTests
                )
                if survivor.cumulativeTestSeconds >= mutantLimitSeconds {
                    partial.expired.append(survivor)
                } else {
                    partial.alive.append(survivor)
                }
            }
        // `cumulativeTestSeconds` crossing the limit is a trigger, not a
        // verdict — it is built from fair-share division of shared batch
        // wall clock (see `testWaveChunk`), which is an estimate, never a
        // per-configuration measurement. Reaching a `.timedOut` classification
        // from that estimate alone would mean the product's headline
        // trustworthiness claim rests on a number nobody actually measured.
        // So budget exhaustion only ever earns this survivor one real,
        // standalone, individually-timed test of its whole remaining list —
        // through the same trusted unbatched path ordinary execution already
        // uses — and only *that* result decides the final classification.
        for survivor in budgetExpired {
            let (standaloneRun, standaloneDuration) = await standaloneVerify(
                survivor.prepared, selectedTests: Set(survivor.remainingTests), baseline: baseline
            )
            let result = await finishAfterTest(
                survivor.prepared, baseline: baseline, run: standaloneRun, attribution: .standalone,
                testDurationSeconds: survivor.cumulativeTestSeconds + standaloneDuration,
                priorTestAttempts: survivor.attempts, appendCurrentAttempt: true
            )
            try? await workspaces.destroy(survivor.prepared.workspace)
            results.append(result)
        }

        guard !stillAlive.isEmpty else { return WaveOutcome(results: results) }

        // Deterministic batch composition: which mutants land in the same
        // chunk (and therefore share timing ambiguity) must not depend on
        // whichever order builds happened to complete in. Sorted by
        // `MutationID` — an arbitrary but fixed, reproducible order — same
        // as `Self.chunked` relies on for `testAndFinish`'s non-wave path.
        let orderedAlive = stillAlive.sorted { $0.prepared.point.id < $1.prepared.point.id }

        var nextSurvivors: [WaveSurvivor] = []
        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []
        for chunkStart in stride(from: 0, to: orderedAlive.count, by: batchSize) {
            let chunk = Array(orderedAlive[chunkStart ..< min(chunkStart + batchSize, orderedAlive.count)])
            batchCount += 1
            totalConfigurations += chunk.count
            let chunkOutcome = await testWaveChunk(
                chunk, id: "wave-\(waveIndex)-chunk-\(chunkStart)", waveIndex: waveIndex,
                baseline: baseline, store: store, batchable: batchable
            )
            results.append(contentsOf: chunkOutcome.results)
            nextSurvivors.append(contentsOf: chunkOutcome.nextSurvivors)
            if let duration = chunkOutcome.duration { batchDurations.append(duration) }
        }

        return WaveOutcome(
            results: results, nextSurvivors: nextSurvivors, batchCount: batchCount,
            totalConfigurations: totalConfigurations, batchDurations: batchDurations
        )
    }

    /// Tests one chunk's worth of survivors — each contributing its next
    /// prioritised covering test — in a single batch, and splits them into
    /// this wave's kills (finished) and advances (returned to keep waving).
    func testWaveChunk(
        _ chunk: [WaveSurvivor], id: String, waveIndex: Int,
        baseline: BaselineContext, store: TestPriorityStore, batchable: any BatchTestable
    ) async -> WaveChunkOutcome {
        do {
            let batchSandbox = try await workspaces.createSandbox(id: id)
            let items = chunk.map { survivor in
                BatchMutantItem(
                    id: survivor.prepared.point.id,
                    artifact: survivor.prepared.artifact,
                    selectedTests: [survivor.remainingTests[0]]
                )
            }
            // Sized from what each survivor has *left*, not a fresh
            // mutantLimitSeconds per mutant — a survivor already close to
            // its cumulative budget must not still be granted a batch that
            // could run it for another full mutantLimitSeconds regardless
            // of what it already spent, which would let this wave alone
            // blow well past the cumulative budget the pre-wave check above
            // exists to enforce.
            let batchTimeout = chunk.reduce(0.0) { partial, survivor in
                let mutantLimitSeconds = baseline.timeouts.mutantLimitSeconds(
                    selectedTests: survivor.prepared.selectedTests
                )
                return partial + max(0, mutantLimitSeconds - survivor.cumulativeTestSeconds)
            }
            // Containment, layered underneath `batchTimeout` above (which
            // stays the outer, aggregate fail-safe, unchanged): confirmed
            // that XCTest's own per-test allowance
            // cuts one hanging configuration off — reported `.timedOut` by
            // `XCResultAdapter.classifyBatch`'s native-timeout branch,
            // routed into the same confirmation path a single-mutant
            // timeout already goes through — without killing this batch's
            // shared `xcodebuild` invocation or losing its other members'
            // results. Every member of one chunk resolves to the identical
            // `mutantLimitSeconds` today (the selected-test-width clamp
            // that could once have varied it per mutant was removed, see
            // `TimeoutController.mutantLimitSeconds(selectedTests:)`), so
            // one value covers the whole batch rather than needing
            // per-item grouping.
            //
            // `nil` — native timeout not attempted, `batchTimeout` alone
            // still applies exactly as before — in two cases: a chunk of
            // exactly one member has no attribution ambiguity for the
            // outer timeout to begin with, so there is nothing for this to
            // contain; and a resolved allowance below the
            // empirically-validated value (60s — the only value actually
            // exercised against a real hang) is not a value this has
            // evidence is safe against false positives from Xcode/Simulator
            // per-invocation startup overhead.
            let nativeTimeoutAllowanceSeconds: Double? = {
                guard chunk.count > 1 else { return nil }
                let allowance = baseline.timeouts.mutantLimitSeconds
                return allowance >= 60 ? allowance : nil
            }()
            let batchStarted = monotonicNow()
            let runs = await batchable.runBatch(
                items, in: batchSandbox.workspaceRoot, timeoutSeconds: batchTimeout,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
            let duration = monotonicNow() - batchStarted
            // What THIS mutant's own budget is charged for its share of the
            // batch — configurations in a shared invocation run
            // sequentially, not concurrently, so charging every one of them
            // the *whole* batch's wall clock (as `testDurationSeconds`
            // already does elsewhere, for reporting) would let a batch of
            // several slow-to-fail mutants exhaust every survivor's
            // cumulative budget at once, well before any of them
            // individually used that much time. An even split is an
            // approximation — real per-configuration timing isn't
            // available from the adapter — but a far more honest one than
            // charging the total to everyone.
            let perMutantShare = duration / Double(chunk.count)

            let batch = WaveChunkBatch(runs: runs, perMutantShare: perMutantShare)
            var outcome = WaveChunkOutcome(duration: duration)
            for survivor in chunk {
                await resolveWaveSurvivor(
                    survivor, batch: batch, waveIndex: waveIndex,
                    baseline: baseline, store: store, into: &outcome
                )
            }

            try? await workspaces.destroySandbox(batchSandbox)
            return outcome
        } catch {
            // No place to write this wave's batch xctestrun/result bundle:
            // every mutant in this chunk is unproven, not silently dropped,
            // and does not advance to a wave that will never run. No test
            // time was spent on this failed attempt, so the reported
            // duration is whatever this mutant had already accumulated.
            var results: [MutationResult] = []
            for survivor in chunk {
                let result = await finishAfterTest(
                    survivor.prepared, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: survivor.prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "No wave sandbox could be created: \(error)"
                    ),
                    attribution: .standalone,
                    testDurationSeconds: survivor.cumulativeTestSeconds
                )
                try? await workspaces.destroy(survivor.prepared.workspace)
                results.append(result)
            }
            return WaveChunkOutcome(results: results, nextSurvivors: [], duration: nil)
        }
    }

    /// Resolves one survivor against its chunk's batch run: a kill (or any
    /// other non-pass) finishes it, a pass advances it to the next wave.
    /// `batch.perMutantShare` is the even split of the batch's wall clock this
    /// survivor is charged unless ground-truth verification measures its own.
    func resolveWaveSurvivor(
        _ survivor: WaveSurvivor,
        batch: WaveChunkBatch,
        waveIndex: Int,
        baseline: BaselineContext,
        store: TestPriorityStore,
        into outcome: inout WaveChunkOutcome
    ) async {
        let test = survivor.remainingTests[0]
        var run = batch.runs[survivor.prepared.point.id] ?? TestRunResult(
            status: .infrastructureFailure, summary: nil, command: survivor.prepared.artifact.command,
            resultArtifactPath: nil, diagnosis: "This mutant's outcome was not reported back from its wave batch."
        )
        // Real, individually-timed duration for THIS mutant, once
        // ground-truth verification below has actually measured one —
        // as opposed to `perMutantShare`, the estimate everyone in
        // this chunk gets by default.
        var verifiedDurationSeconds: Double?
        var attribution = TestExecutionRecord.Attribution.batch

        // `.infrastructureFailure`, or missing from the batch's
        // results at all, is a definitive signal about THIS mutant —
        // both are exactly what a shared invocation failing to
        // report back cleanly looks like from the outside, with no
        // way to tell whether this mutant caused it or merely shared
        // the invocation with whatever did. Found for real on a live
        // Xcode project: a chunk of exactly one survivor still
        // reported `infrastructureFailure` for a mutant that a plain
        // standalone rerun immediately confirmed was
        // `killedByAssertion` — so this is not only a multi-mutant
        // sharing problem, and the check does not gate on
        // `chunk.count`. `.failed`/`.crashed` are left alone: the
        // batch xctestrun's own attribution of an assertion failure
        // or crash to a specific configuration is a solid,
        // independent mechanism this is not second-guessing — only
        // the batch's non-answers are.
        //
        // `.timedOut` is different from the other two, and is only
        // ambiguous when `isBatchAttributedTimeout` says so (a
        // field introduced for exactly this
        // distinction, previously unused
        // on this path). A native-XCTest-timeout classification
        // (`isBatchAttributedTimeout == false`) already names the one
        // configuration responsible; rerunning it standalone here
        // before `finishAfterTest` below triggers its own, separate
        // `confirmTimedOutMutants` confirmation (narrowed to this
        // same witness test) pays for the identical single-test
        // confirmation twice. Only a genuine batch-wide kill
        // (`isBatchAttributedTimeout == true` — the whole shared
        // invocation was terminated with no way to tell which
        // configuration caused it) still needs this standalone rerun
        // to find out whether THIS mutant was actually responsible.
        if (run.status == .timedOut && run.isBatchAttributedTimeout) || run.status == .infrastructureFailure
            || batch.runs[survivor.prepared.point.id] == nil {
            let (standaloneRun, standaloneDuration) = await standaloneVerify(
                survivor.prepared, selectedTests: [test], baseline: baseline
            )
            run = standaloneRun
            verifiedDurationSeconds = standaloneDuration
            attribution = .standalone
        }

        if run.status != .passed {
            // Confirmation (retestKilledMutants/confirmCrashKills/
            // confirmTimedOutMutants) reruns using `selectedTests` —
            // narrowed here to just the one test that actually
            // produced this wave's detection, not the mutant's whole
            // original covering-test set, so a confirmation rerun
            // reproduces the same single witness rather than a
            // broader run that could reach a different result.
            //
            // testDurationSeconds is this mutant's *total* test time
            // across every wave, not just this final one — otherwise
            // a mutant killed on wave 3 would report only wave 3's
            // duration, silently dropping waves 1 and 2's.
            let result = await finishAfterTest(
                survivor.prepared.narrowed(to: test), baseline: baseline, run: run, attribution: attribution,
                testDurationSeconds: survivor.cumulativeTestSeconds + (verifiedDurationSeconds ?? batch.perMutantShare),
                priorTestAttempts: survivor.attempts, appendCurrentAttempt: true, currentAttemptWaveIndex: waveIndex
            )
            // Only a confirmed kill credits this test's priority
            // history — checked against the *final* outcome, not the
            // raw wave `run.status`: confirmation may have just
            // downgraded it to `.flaky` or an unconfirmed `.timedOut`,
            // and crediting a result that did not hold up would
            // corrupt the learned ordering. Mirrors
            // `PrioritizingTestAdapter.runMutant`'s identical
            // distinction on the per-invocation path.
            if result.outcome.isKilled {
                await store.recordDetection(by: test)
            }
            try? await workspaces.destroy(survivor.prepared.workspace)
            outcome.results.append(result)
        } else {
            // Passed this test → advance to the next one, carrying
            // this wave's (per-mutant share of the, or — once ground-
            // truth verified above — the real) duration into the
            // running total, and this run itself forward so a later
            // exhausted/budget-expired result can report its real
            // command/artifact instead of a placeholder.
            //
            // This wave's own artifact is preserved now, before
            // `batchSandbox` is destroyed below — otherwise a later
            // wave/confirmation could never recover it once this
            // survivor eventually reaches a final verdict.
            // `survivor.prepared.sandbox` (not `batchSandbox`) is
            // passed deliberately, the same way the single-attempt
            // path below does for its own preserve call: several
            // survivors in this chunk share the SAME batch-wide
            // result bundle, and passing the sandbox it actually
            // lives in would let the first survivor's preserve MOVE
            // it away, leaving nothing for the rest. Passing a
            // sandbox the artifact is never inside forces a copy.
            let preservedArtifact = evidenceAssembler.preserve(
                run.resultArtifactPath, for: survivor.prepared.point, in: survivor.prepared.sandbox,
                label: "wave-\(waveIndex)"
            )
            let attempt = TestAttemptEvidence(
                selectedTests: [test.onlyTestingArgument],
                status: run.status.rawValue,
                summary: run.summary,
                command: run.command,
                resultArtifact: preservedArtifact,
                waveIndex: waveIndex
            )
            let advanced = Array(survivor.remainingTests.dropFirst())
            outcome.nextSurvivors.append(WaveSurvivor(
                prepared: survivor.prepared, remainingTests: advanced,
                cumulativeTestSeconds: survivor.cumulativeTestSeconds + (verifiedDurationSeconds ?? batch.perMutantShare),
                lastRun: run,
                attempts: survivor.attempts + [attempt]
            ))
        }
    }

    /// Ground-truth verification for a mutant whose classification would
    /// otherwise rest on shared-batch estimated timing — fair-share division
    /// of a batch's wall clock, or an ambiguous `.timedOut`/missing-from-batch
    /// result from an invocation shared with other mutants. Runs this ONE
    /// mutant standalone, through `runMutantTests` — the same trusted,
    /// individually-timed path ordinary (non-batch, non-wave) execution
    /// already uses, with nobody else's time to borrow from or be blamed for.
    ///
    /// The wave loop's own bookkeeping (fair-share division, the cumulative-
    /// budget estimate) exists only to decide *when* to reach for this check
    /// — it must never stand in for it. A caller whose `run` genuinely could
    /// not be launched here reports `.infrastructureFailure`, exactly like
    /// every other unbatched test call in this file.
    func standaloneVerify(
        _ prepared: PreparedMutant, selectedTests: Set<TestIdentifier>?, baseline: BaselineContext
    ) async -> (run: TestRunResult, duration: Double) {
        let testStarted = monotonicNow()
        // Scaled off exactly what this standalone attempt actually runs
        // (`selectedTests`, not unconditionally `prepared.selectedTests` —
        // a caller may narrow this to the mutant's whole remaining list or
        // to a single witness test, never its original full covering-test
        // set, though `testOneBatch`'s own ambiguity-recovery call passes
        // `prepared.selectedTests` straight through since it has no
        // narrower list to prefer). `nil` here means the same thing it
        // always does — no known selection, run the full configured list —
        // preserved rather than collapsed into an empty `Set`.
        let timeoutSeconds = baseline.timeouts.mutantLimitSeconds(selectedTests: selectedTests)
        let run = try? await confirmationCoordinator.runMutantTests(
            prepared.point, artifact: prepared.artifact, in: prepared.sandbox,
            timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
        )
        let duration = monotonicNow() - testStarted
        return (
            run ?? TestRunResult(
                status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                resultArtifactPath: nil, diagnosis: "The mutant's standalone verification test could not be run."
            ),
            duration
        )
    }
}
