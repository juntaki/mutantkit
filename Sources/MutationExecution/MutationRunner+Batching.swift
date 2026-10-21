import Foundation
import MutationModel

extension MutationRunner {
    /// What `testOneBatch` produced for one chunk: its finished results, how
    /// many test configurations it ran, and how long the batched run took
    /// (`nil` when no batched run happened).
    struct BatchTestOutcome {
        let results: [MutationResult]
        let configurations: Int
        let duration: Double?
    }

    /// `evaluate(_:baseline:)`'s counterpart for
    /// `Configuration.execution.testBatchSize`: builds every mutant the
    /// ordinary, isolated way — its own fresh sandbox, its own build, its
    /// own activation hash — then tests up to `batchSize` of them per
    /// `xcodebuild` invocation instead of one invocation per mutant.
    ///
    /// Two phases, not interleaved: every mutant is built first (bounded by
    /// `resolvedWorkerCount()`, same parallelism the unbatched path uses),
    /// then the ones that need testing are grouped and tested in batches.
    /// A mutant whose build alone already produced a verdict — an anchor
    /// that no longer matches, `.noCoverage`, a build failure — never
    /// reaches the test phase at all, exactly as it never would on the
    /// unbatched path. `finishAfterTest` and every confirmation path are
    /// shared unchanged with `evaluate(_:in:baseline:startedAt:)`: a
    /// batched mutant's crash or timeout confirmation still gets its own
    /// fresh, independent, unbatched sandbox.
    func evaluateInBatches(
        _ pending: [MutationPoint], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        var collected: [MutationResult] = []
        var readyToTest: [PreparedMutant] = []

        let workers = max(1, configuration.execution.resolvedWorkerCount())
        try await withThrowingTaskGroup(of: (Sandbox?, PrepareOutcome).self) { group in
            var remaining = pending.makeIterator()

            func addTask(for point: MutationPoint) throws {
                group.addTask {
                    let started = Date()
                    let sandbox: Sandbox
                    do {
                        sandbox = try await self.workspaces.createSandbox(id: point.id.rawValue)
                    } catch {
                        return (
                            nil,
                            .finished(await self.evidenceAssembler.infrastructureFailureResult(
                                point: point,
                                diagnosis: "No sandbox could be created for this mutant: \(error)",
                                durationSeconds: Date().timeIntervalSince(started)
                            ))
                        )
                    }
                    let outcome = await self.prepare(point, in: sandbox, baseline: baseline, startedAt: started)
                    return (sandbox, outcome)
                }
            }

            for _ in 0 ..< workers {
                guard stop?.isStopRequested != true, let point = remaining.next() else { break }
                try addTask(for: point)
            }

            while let (sandbox, outcome) = try await group.next() {
                switch outcome {
                case let .finished(result):
                    if let sandbox { try? await workspaces.destroySandbox(sandbox) }
                    collected.append(result)
                case let .readyToTest(prepared):
                    readyToTest.append(prepared)
                }
                if stop?.isStopRequested != true, let point = remaining.next() {
                    try addTask(for: point)
                }
            }
        }

        let (testResults, summary) = try await testAndFinish(readyToTest: readyToTest, baseline: baseline, batchSize: batchSize)
        collected.append(contentsOf: testResults)
        return (collected, summary)
    }

    /// Groups `readyToTest` into the chunks `testAndFinish` will each hand to
    /// one `runBatch` call.
    ///
    /// A mutant with no attributed covering test (`selectedTests == nil`)
    /// runs the full configured test list, not a narrow one — batching
    /// exists to amortize one xcodebuild invocation's fixed overhead across
    /// many *small* runs, and several full-suite mutants sharing a batch
    /// does the opposite: their costs simply add, multiplying rather than
    /// sharing. A batch composed this way can exceed even `batchTimeout`'s
    /// generous per-mutant-count sizing, which then makes every mutant in
    /// it — including perfectly good, fast, narrowly-attributed ones that
    /// happened to land in the same batch — unprovable and `.flaky`, not
    /// because anything about them individually is unstable.
    ///
    /// Chunked separately, at size 1: this costs nothing relative to running
    /// them outside batching at all (there was no sharable overhead to
    /// lose), and keeps them from inflating a shared batch's cumulative test
    /// time past its budget.
    static func chunked(_ readyToTest: [PreparedMutant], batchSize: Int) -> [[PreparedMutant]] {
        let narrow = readyToTest.filter { $0.selectedTests != nil }
        let unrestricted = readyToTest.filter { $0.selectedTests == nil }
        return stride(from: 0, to: narrow.count, by: batchSize)
            .map { Array(narrow[$0 ..< min($0 + batchSize, narrow.count)]) }
            + unrestricted.map { [$0] }
    }

    /// The test phase shared by every path that builds a batch of mutants
    /// ahead of testing them: batches `readyToTest` and tests each batch in
    /// one `xcodebuild` invocation, then classifies and destroys each
    /// mutant's own sandbox plus the batch sandbox once its results are in
    /// hand.
    ///
    /// Deliberately agnostic to *how* `prepared.sandbox` came to hold its
    /// artifact — `evaluateInBatches` hands it a mutant's own fresh,
    /// isolated sandbox; `evaluateIncrementallyInBatches` hands it a cloned
    /// products directory, independent of the persistent worker sandbox
    /// that built it (see `WorkspaceManager.cloneProducts`). Both are just
    /// "a directory to test from and destroy afterward" as far as this
    /// function is concerned, which is what makes sharing it safe.
    func testAndFinish(
        readyToTest: [PreparedMutant], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary) {
        // Wave-based early kill: when a priority store is available and
        // early abort is requested, test one prioritised covering test per
        // mutant per wave instead of a mutant's whole selection in one
        // batch. Killed mutants stop immediately; survivors advance to
        // their next test in the next wave. Each wave is still one batched
        // `xcodebuild` invocation, not one per test — this is the fix for
        // `PrioritizingTestAdapter`'s per-test-per-mutant fixed cost, not a
        // parallel test-running mechanism: it hands its batches to the same
        // `batchable.runBatch` (and therefore the same, already-fixed batch
        // attribution path) every other batched path here uses.
        if configuration.execution.earlyAbortSelectedTests,
           let store = priorityStore,
           let batchable = batchableTest,
           !readyToTest.isEmpty {
            return await testInWaves(
                readyToTest: readyToTest, baseline: baseline, store: store, batchable: batchable, batchSize: batchSize
            )
        }

        var collected: [MutationResult] = []

        guard let batchable = batchableTest, !readyToTest.isEmpty else {
            // Nothing built successfully, or the adapter stopped conforming
            // between the dispatch check and here (it cannot, but the
            // fallback costs nothing): destroy any leftover sandboxes and
            // fall back to testing them one at a time rather than losing them.
            // This is NOT genuine batching, so it does not contribute to the
            // batch execution summary.
            for prepared in readyToTest {
                let testStarted = Date()
                let run = try? await confirmationCoordinator.runMutantTests(
                    prepared.point, artifact: prepared.artifact, in: prepared.sandbox,
                    timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: prepared.selectedTests),
                    selectedTests: prepared.selectedTests
                )
                let testDurationSeconds = Date().timeIntervalSince(testStarted)
                let result = await finishAfterTest(
                    prepared, baseline: baseline,
                    run: run ?? TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "The mutant's tests could not be run."
                    ),
                    attribution: .standalone,
                    testDurationSeconds: testDurationSeconds
                )
                try? await workspaces.destroy(prepared.workspace)
                collected.append(result)
            }
            return (collected, BatchExecutionSummary(batchCount: 0, totalConfigurations: 0))
        }

        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []

        // `Self.chunked` (not a plain stride slice): keeps unattributed
        // mutants out of a shared batch with each other — see its doc
        // comment — while `testOneBatch` (shared with the pipelined test
        // lane, see `runPipelinedTestLane`) does the actual per-chunk
        // sandbox/build/test/classify work.
        for chunk in Self.chunked(readyToTest, batchSize: batchSize) {
            let outcome = await testOneBatch(
                chunk, batchIndex: batchCount, baseline: baseline, batchable: batchable
            )
            collected.append(contentsOf: outcome.results)
            batchCount += 1
            totalConfigurations += outcome.configurations
            if let duration = outcome.duration { batchDurations.append(duration) }
        }

        return (
            collected,
            BatchExecutionSummary(
                batchCount: batchCount, totalConfigurations: totalConfigurations, batchDurations: batchDurations
            )
        )
    }

    /// Tests every unattributed mutant's full configured test list, one per
    /// chunk — never several bundled into the same batch.
    ///
    /// Bundling more than one into a shared batch was tried first and found
    /// wrong the same way `testAndFinish`'s equivalent fix was: several
    /// full-suite reruns bundled together simply add their costs rather than
    /// sharing them, which can exceed even a batch sized generously per
    /// mutant count and mark every mutant in it — not just the slow one —
    /// unprovable. One mutant per chunk costs nothing relative to not
    /// batching them at all, since there was no sharable overhead to lose.
    func testUnattributed(
        _ unattributed: [PreparedMutant], baseline: BaselineContext, batchable: any BatchTestable
    ) async -> UnattributedOutcome {
        var results: [MutationResult] = []
        var batchDurations: [Double] = []
        for prepared in unattributed {
            do {
                let batchSandbox = try await workspaces.createSandbox(id: "wave-unattributed-\(prepared.point.id.rawValue)")
                let items = [BatchMutantItem(id: prepared.point.id, artifact: prepared.artifact, selectedTests: nil)]
                let batchTimeout = baseline.timeouts.mutantLimitSeconds
                let batchStarted = Date()
                let runs = await batchable.runBatch(items, in: batchSandbox.workspaceRoot, timeoutSeconds: batchTimeout)
                let duration = Date().timeIntervalSince(batchStarted)
                batchDurations.append(duration)

                let run = runs[prepared.point.id] ?? TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                    resultArtifactPath: nil, diagnosis: "This mutant's outcome was not reported back from its batch."
                )
                let result = await finishAfterTest(
                    prepared, baseline: baseline, run: run, attribution: .batch, testDurationSeconds: duration
                )
                try? await workspaces.destroy(prepared.workspace)
                results.append(result)
                try? await workspaces.destroySandbox(batchSandbox)
            } catch {
                let result = await finishAfterTest(
                    prepared, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "No batch sandbox could be created: \(error)"
                    ),
                    attribution: .standalone
                )
                try? await workspaces.destroy(prepared.workspace)
                results.append(result)
            }
        }
        return UnattributedOutcome(results: results, batchCount: unattributed.count, batchDurations: batchDurations)
    }

    /// Tests one already-batchable group of prepared mutants through a
    /// single `runBatch` call, classifies each result, records checkpoints,
    /// and destroys each mutant's own sandbox (its clone, for the pipelined
    /// path) plus the batch sandbox. Extracted out of `testAndFinish`'s loop
    /// body so it can be shared with `runPipelinedTestLane`, which calls it
    /// once per batch as clones arrive live instead of once per pre-sliced
    /// chunk of a complete `readyToTest` array.
    ///
    /// Never throws: a batch sandbox creation failure, a missing result, or
    /// any other error is recorded as `.infrastructureFailure` for the
    /// affected mutants, same fail-closed contract every other path in this
    /// file has. Checkpoint failures are swallowed here (`try?`, not
    /// `try`) rather than propagated the way `testAndFinish`'s own
    /// non-batched fallback loop still does above — a deliberate
    /// harmonization with the build-worker paths, which have always
    /// swallowed checkpoint failures rather than aborting the run over
    /// them, and a practical necessity here: this function is called from
    /// `runPipelinedTestLane`, a non-throwing task running concurrently
    /// alongside the build workers, so a checkpoint write failure cannot be
    /// allowed to unwind through it.
    func testOneBatch(
        _ chunk: [PreparedMutant], batchIndex: Int, baseline: BaselineContext, batchable: any BatchTestable
    ) async -> BatchTestOutcome {
        var collected: [MutationResult] = []

        let batchSandbox: Sandbox
        do {
            batchSandbox = try await workspaces.createSandbox(id: "batch-\(batchIndex)")
        } catch {
            // No place to write the batch xctestrun/result bundle: every
            // mutant in this chunk is unproven, not silently dropped. No
            // test time was spent on this failed attempt, so there is no
            // duration to report — matches `BatchExecutionSummary.
            // batchDurations`'s documented "one entry per chunk that
            // actually reached `BatchTestable.runBatch`" contract.
            for prepared in chunk {
                let result = await finishAfterTest(
                    prepared, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "No batch sandbox could be created: \(error)"
                    ),
                    attribution: .standalone
                )
                try? await workspaces.destroy(prepared.workspace)
                collected.append(result)
            }
            return BatchTestOutcome(results: collected, configurations: chunk.count, duration: nil)
        }

        let items = chunk.map {
            BatchMutantItem(id: $0.point.id, artifact: $0.artifact, selectedTests: $0.selectedTests)
        }
        // Each mutant in the shared invocation contributes its own limit —
        // selected-test-clamped where it has a known, non-empty selection,
        // whole-suite-scaled otherwise — rather than every mutant in the
        // batch being charged the same whole-suite number regardless of how
        // narrow its own selection is.
        let batchTimeout = chunk.reduce(0.0) { partial, prepared in
            partial + baseline.timeouts.mutantLimitSeconds(selectedTests: prepared.selectedTests)
        }
        // Containment, layered underneath `batchTimeout` above (which stays
        // the outer, aggregate fail-safe, unchanged) — this is the path a
        // plain `testBatchSize > 1` configuration (`earlyAbortSelectedTests`
        // left at its default `false`) actually runs, the same path Gate
        // 3's real-production-app batch-hang-containment finding came from. See
        // `testWaveChunk`'s identical native-timeout block for the full
        // rationale — repeated here rather than
        // shared because the two chunk shapes (`[WaveSurvivor]` vs
        // `[PreparedMutant]`) don't share a common type to factor a helper
        // over without a bigger refactor than this phase calls for.
        let nativeTimeoutAllowanceSeconds: Double? = {
            guard chunk.count > 1 else { return nil }
            let allowance = baseline.timeouts.mutantLimitSeconds
            return allowance >= 60 ? allowance : nil
        }()
        let batchStarted = Date()
        let runs = await batchable.runBatch(
            items, in: batchSandbox.workspaceRoot, timeoutSeconds: batchTimeout,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )
        let batchTestDuration = Date().timeIntervalSince(batchStarted)

        for prepared in chunk {
            var run = runs[prepared.point.id] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                resultArtifactPath: nil,
                diagnosis: "This mutant's outcome was not reported back from its batch."
            )
            // `.infrastructureFailure` here — whether `classifyBatch` itself
            // produced it (no per-configuration evidence in the result
            // bundle) or it was synthesized just above (missing from `runs`
            // entirely) — means the *shared invocation's* attribution
            // failed for this one mutant, not that the mutant is
            // unprovable. `testWaveChunk` already has this exact gate for
            // the identical failure shape (found for real on a live Xcode
            // project — see its own doc comment); `testOneBatch`, the plain
            // non-wave batch path (`earlyAbortSelectedTests` left at its
            // default `false`), never had the equivalent protection until
            // now. `.timedOut` is deliberately left alone here — that
            // status already has its own correct, existing handling via
            // `confirmTimedOutMutants`'s policy-driven confirmation
            // (`isBatchAttributedTimeout` distinguishes a genuine
            // individually-attributed timeout from a batch-wide one), which
            // this gate must not duplicate or race against.
            var verifiedDurationSeconds: Double?
            var attribution = TestExecutionRecord.Attribution.batch
            if run.status == .infrastructureFailure {
                let (standaloneRun, standaloneDuration) = await standaloneVerify(
                    prepared, selectedTests: prepared.selectedTests, baseline: baseline
                )
                run = standaloneRun
                verifiedDurationSeconds = standaloneDuration
                attribution = .standalone
            }
            let result = await finishAfterTest(
                prepared, baseline: baseline, run: run, attribution: attribution,
                testDurationSeconds: verifiedDurationSeconds ?? batchTestDuration
            )
            try? await workspaces.destroy(prepared.workspace)
            collected.append(result)
        }

        try? await workspaces.destroySandbox(batchSandbox)
        return BatchTestOutcome(results: collected, configurations: chunk.count, duration: batchTestDuration)
    }

    // MARK: - Baseline
}
