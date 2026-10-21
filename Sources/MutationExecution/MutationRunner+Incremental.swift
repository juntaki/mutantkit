import Foundation
import MutationModel

extension MutationRunner {
    /// What one sequential incremental build worker hands back: the results
    /// that finished during its builds, the clones awaiting a batched test,
    /// and the worker sandbox the caller must keep alive until then (`nil`
    /// when the worker could not create one).
    struct IncrementalBuildWorkerOutcome: Sendable {
        let results: [MutationResult]
        let readyToTest: [PreparedMutant]
        let sandbox: Sandbox?
    }

    /// `evaluate(_:baseline:)`'s counterpart for
    /// `Configuration.execution.incrementalBuild`: `resolvedWorkerCount()`
    /// persistent sandboxes, each pulling mutants from a shared queue and
    /// evaluating them one at a time, reverting the one file it touched
    /// before moving to the next — see `runIncrementalWorker`.
    ///
    /// The per-mutant evaluation itself (`evaluate(_:in:baseline:startedAt:)`)
    /// is unchanged and shared with the non-incremental path: everything
    /// about *what* proves a verdict — activation hash against baseline,
    /// crash/timeout confirmation in their own fresh sandboxes — stays
    /// exactly as it is there. Only *which* sandbox a mutant's own first
    /// build and test run in changes.
    func evaluateIncrementally(_ pending: [MutationPoint], baseline: BaselineContext) async throws -> [MutationResult] {
        let workers = max(1, configuration.execution.resolvedWorkerCount())
        let queue = MutationQueue(pending, stop: stop)

        return try await withThrowingTaskGroup(of: [MutationResult].self) { group in
            for workerIndex in 0 ..< workers {
                group.addTask {
                    await runIncrementalWorker(id: "incr-worker-\(workerIndex)", queue: queue, baseline: baseline)
                }
            }

            var collected: [MutationResult] = []
            for try await workerResults in group {
                collected.append(contentsOf: workerResults)
            }
            return collected
        }
    }

    /// One persistent sandbox's lifetime: created once, handed every mutant
    /// this worker dequeues in turn, reverted to pristine after each one,
    /// destroyed once the queue is empty.
    ///
    /// A worker that cannot even create its sandbox does not silently drop
    /// its share of the plan: it drains the queue reporting
    /// `.infrastructureFailure` for each mutant it would have taken, the
    /// same fate a per-mutant sandbox failure has on the non-incremental
    /// path, so every planned mutation still owes the integrity check a
    /// result.
    ///
    /// F3 verdict-contamination audit: this sandbox's deliberate reuse
    /// across mutations is an accepted, *unproven*, not proven-safe risk
    /// — see `ProcessSupervisor`'s own "Remaining risks" doc comment for
    /// the full reasoning and the exact reopening trigger. No production
    /// mitigation here on purpose.
    private func runIncrementalWorker(
        id: String, queue: MutationQueue, baseline: BaselineContext
    ) async -> [MutationResult] {
        var results: [MutationResult] = []

        let sandbox: Sandbox
        do {
            sandbox = try await workspaces.createSandbox(id: id)
        } catch {
            while let point = await queue.next() {
                let result = await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "No persistent incremental-build sandbox could be created for this worker: \(error)",
                    durationSeconds: 0
                )
                results.append(result)
            }
            return results
        }

        while let point = await queue.next(forWorker: id) {
            let started = Date()
            let result = await evaluate(point, in: sandbox, baseline: baseline, startedAt: started)
            // Always attempted, regardless of how the mutant's own
            // evaluation went: the next mutant on this worker must start
            // from a pristine file no matter what happened to this one — a
            // build failure, a crash, an anchor rejection that never wrote
            // anything. `restoreFile` re-clones from `projectRoot`, which
            // is read-only and untouched, so this can only ever put the
            // sandbox back to a known-good state, never compound an error.
            try? await workspaces.restoreFile(relativePath: point.file, in: sandbox)
            results.append(result)
        }

        try? await workspaces.destroySandbox(sandbox)
        return results
    }

    /// `evaluate(_:baseline:)`'s counterpart for `Configuration.execution
    /// .incrementalBuild` and `Configuration.execution.testBatchSize`
    /// together: `resolvedWorkerCount()` persistent sandboxes build mutants
    /// incrementally and in place, exactly like `evaluateIncrementally` —
    /// but **pipelined** with a single test lane that tests a batch the
    /// moment it fills up, instead of waiting for every worker's build
    /// queue to drain first. A prepared mutant's build is cloned out to its
    /// own independent location (see `WorkspaceManager.cloneProducts`) the
    /// moment it is ready, handed to `PipelineCoordinator`, and the worker
    /// moves straight on to its next mutant's build — the same clone-and-go
    /// shape the previous two-phase design used, except the clone is
    /// consumed concurrently rather than only after every worker finishes.
    /// This overlaps the two dominant costs of a run — Swift compilation
    /// (CPU-bound, inside the worker sandboxes) and `xcodebuild test`
    /// (simulator-bound, inside the test lane) — which the strict two-phase
    /// design left serialized: the test lane sat idle for the whole build
    /// phase, and every build worker sat idle for the whole test phase.
    ///
    /// **Sandbox lifetime, and why it needs a live reference count, not a
    /// single barrier.** A cloned products directory only carries the
    /// mutant's *build products* (see `WorkspaceManager.cloneProducts`); a
    /// test that resolves a fixture through a source-relative path baked in
    /// at compile time (an ordinary, idiomatic pattern: `URL(fileURLWithPath:
    /// #filePath)` walked up to the project root) still resolves against the
    /// worker sandbox the source was compiled in, not the clone — so a
    /// worker's own sandbox must outlive every clone it produced, not just
    /// its own build loop (this is the same fact `PipelineCoordinator`'s doc
    /// comment, and the non-pipelined fix this generalizes, explain in more
    /// detail). With build and test now running concurrently instead of in
    /// two strict phases, there is no single point in time — no "every
    /// build is done" barrier — after which it is safe to destroy every
    /// worker's sandbox: a fast worker can finish its whole build queue
    /// while its own most recent clones are still sitting in the test
    /// lane's forming batch, not yet tested. `PipelineCoordinator` tracks,
    /// per worker, an outstanding-clone count (incremented the instant a
    /// clone is handed to the coordinator, decremented the instant the test
    /// lane finishes testing it — success, failure, or infrastructure
    /// error, every path decrements) and destroys that worker's sandbox
    /// exactly when its build loop has ended *and* its outstanding count has
    /// reached zero, whichever of those two events happens last, for that
    /// worker specifically. See `PipelineCoordinator` below for the actor
    /// that makes both halves of that check atomic.
    func evaluateIncrementallyInBatches(
        _ pending: [MutationPoint], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        let workers = max(1, configuration.execution.resolvedWorkerCount())
        let queue = MutationQueue(pending, stop: stop)
        let collector = PipelineCollector()
        let coordinator = PipelineCoordinator(workspaces: workspaces, workerCount: workers)

        // The test lane and the build workers are siblings in one task
        // group, not nested — nesting the build workers inside the lane (or
        // vice versa) would make one wait structurally for the other to be
        // spawned/joined, which is exactly the coupling pipelining exists to
        // remove. They coordinate only through `coordinator`: build workers
        // call `send`/`workerBuildFinished`, the test lane calls `receive`,
        // and `receive` returns `nil` on its own once every worker has
        // finished and every buffered clone has been drained — no outer
        // "finish" signal needs to be sent from here.
        // Neither side ever throws (see `runPipelinedBuildWorker`'s and
        // `runPipelinedTestLane`'s doc comments: both are fail-closed —
        // every failure becomes an `.infrastructureFailure` result rather
        // than a thrown error), so a plain, non-throwing task group is
        // enough; `evaluateIncrementallyInBatches` stays `throws` only for
        // signature parity with its sibling evaluation paths.
        await withTaskGroup(of: Void.self) { outer in
            outer.addTask { [self] in
                await runPipelinedTestLane(
                    coordinator: coordinator, collector: collector, baseline: baseline, batchSize: batchSize
                )
            }
            outer.addTask { [self] in
                await withTaskGroup(of: Void.self) { buildGroup in
                    for workerIndex in 0 ..< workers {
                        buildGroup.addTask {
                            await self.runPipelinedBuildWorker(
                                id: "incr-worker-\(workerIndex)", queue: queue, baseline: baseline,
                                collector: collector, coordinator: coordinator
                            )
                        }
                    }
                }
            }
            await outer.waitForAll()
        }

        let snapshot = await collector.snapshot()
        return (snapshot.results, snapshot.summary)
    }

    /// The pre-pipelining incremental-plus-batching path, kept only for
    /// wave-based early kill (see `evaluate(_:baseline:)`'s dispatch):
    /// build every mutant first (bounded by `resolvedWorkerCount()`), THEN
    /// test the ones that need it, through `testAndFinish` — which is what
    /// gives `testInWaves` a chance to dispatch at all. The pipelined
    /// `evaluateIncrementallyInBatches` above interleaves building and
    /// testing instead, which is strictly faster but has no way to run
    /// wave-based early kill's multi-round, one-test-per-wave protocol.
    func evaluateIncrementallyInBatchesSequential(
        _ pending: [MutationPoint], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        let workers = max(1, configuration.execution.resolvedWorkerCount())
        let queue = MutationQueue(pending, stop: stop)

        var collected: [MutationResult] = []
        var readyToTest: [PreparedMutant] = []
        var workerSandboxes: [Sandbox] = []

        try await withThrowingTaskGroup(
            of: IncrementalBuildWorkerOutcome.self
        ) { group in
            for workerIndex in 0 ..< workers {
                group.addTask {
                    await self.runIncrementalBuildWorkerSequential(
                        id: "incr-worker-\(workerIndex)", queue: queue, baseline: baseline
                    )
                }
            }

            for try await worker in group {
                collected.append(contentsOf: worker.results)
                readyToTest.append(contentsOf: worker.readyToTest)
                if let sandbox = worker.sandbox {
                    workerSandboxes.append(sandbox)
                }
            }
        }

        let (testResults, summary) = try await testAndFinish(readyToTest: readyToTest, baseline: baseline, batchSize: batchSize)
        collected.append(contentsOf: testResults)

        // Only now — every clone any worker produced has been tested and
        // its own result recorded — is it safe to tear down the sandboxes
        // that built them.
        for sandbox in workerSandboxes {
            try? await workspaces.destroySandbox(sandbox)
        }

        return (collected, summary)
    }

    /// One persistent sandbox's lifetime for
    /// `evaluateIncrementallyInBatchesSequential`: same build shape as
    /// `runIncrementalWorker`, but calls only `prepare(...)` per mutant
    /// (never tests in place), clones a `.readyToTest` mutant's artifact out
    /// before moving on instead of holding the worker's own sandbox open
    /// until it is tested, and returns its own sandbox to the caller instead
    /// of destroying it — the caller destroys it once every clone this
    /// worker produced has actually been tested by the shared `testAndFinish`
    /// barrier.
    ///
    /// A worker that cannot even create its sandbox fails exactly like
    /// `runIncrementalWorker`'s does: it drains the queue reporting
    /// `.infrastructureFailure` for every mutant it would have taken, rather
    /// than silently dropping its share of the plan. It returns `sandbox:
    /// nil` in that case — there is nothing for the caller to keep alive or
    /// destroy.
    ///
    /// Same accepted, unproven cross-mutant reuse risk as
    /// `runIncrementalWorker` — see that method's own doc comment and
    /// `ProcessSupervisor`'s "Remaining risks" section.
    private func runIncrementalBuildWorkerSequential(
        id: String, queue: MutationQueue, baseline: BaselineContext
    ) async -> IncrementalBuildWorkerOutcome {
        var results: [MutationResult] = []
        var readyToTest: [PreparedMutant] = []

        let sandbox: Sandbox
        do {
            sandbox = try await workspaces.createSandbox(id: id)
        } catch {
            while let point = await queue.next() {
                let result = await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "No persistent incremental-build sandbox could be created for this worker: \(error)",
                    durationSeconds: 0
                )
                results.append(result)
            }
            return IncrementalBuildWorkerOutcome(results: results, readyToTest: readyToTest, sandbox: nil)
        }

        while let point = await queue.next(forWorker: id) {
            let started = Date()
            switch await prepare(point, in: sandbox, baseline: baseline, startedAt: started) {
            case let .finished(result):
                results.append(result)
            case let .readyToTest(prepared):
                do {
                    let clone = try await workspaces.cloneProducts(
                        from: prepared.artifact.productsDirectory, id: point.id.rawValue
                    )
                    readyToTest.append(Self.relocating(prepared, to: clone))
                } catch {
                    let result = await evidenceAssembler.infrastructureFailureResult(
                        point: point,
                        diagnosis: "This mutant's build could not be cloned out for batched testing: \(error)",
                        evidence: evidenceAssembler.evidence(
                            prepared.applied, artifact: prepared.artifact, activation: prepared.activation
                        ),
                        durationSeconds: Date().timeIntervalSince(started)
                    )
                    results.append(result)
                }
            }
            // Always attempted, same reasoning as `runIncrementalWorker`: the
            // next mutant on this worker must start from a pristine file
            // regardless of how this one went — and by this point this
            // mutant's build artifact, if it produced one, has already
            // either been cloned out or given up on, so nothing here still
            // depends on the sandbox's current contents.
            try? await workspaces.restoreFile(relativePath: point.file, in: sandbox)
        }

        return IncrementalBuildWorkerOutcome(results: results, readyToTest: readyToTest, sandbox: sandbox)
    }

    /// One persistent sandbox's lifetime for the pipelined
    /// incremental-plus-batching path: same build shape as
    /// `runIncrementalWorker`, but calls only `prepare(...)` per mutant
    /// (never tests in place), and instead of collecting `.readyToTest`
    /// mutants into a return value, clones each one out and immediately
    /// hands it to `coordinator.send`, which both queues it for the test
    /// lane and records it against this worker's outstanding-clone count.
    /// A result that finishes during the build itself (`.noCoverage`, a
    /// build failure, a clone failure) goes straight to `collector` — it
    /// never touches the coordinator's count, because it never produced a
    /// clone for the test lane to owe a decrement for.
    ///
    /// A worker that cannot even create its sandbox fails exactly like
    /// `runIncrementalWorker`'s does: it drains the queue reporting
    /// `.infrastructureFailure` for every mutant it would have taken,
    /// rather than silently dropping its share of the plan. Either way,
    /// `coordinator.registerWorker` and `coordinator.workerBuildFinished`
    /// are called on every exit path — including this one — because the
    /// test lane's `receive` loop only ends once every worker has reported
    /// itself finished; a worker that returned early without reporting in
    /// would leave the test lane, and the whole pipeline, waiting forever.
    ///
    /// Same accepted, unproven cross-mutant reuse risk as
    /// `runIncrementalWorker` — see that method's own doc comment and
    /// `ProcessSupervisor`'s "Remaining risks" section.
    private func runPipelinedBuildWorker(
        id: String, queue: MutationQueue, baseline: BaselineContext,
        collector: PipelineCollector, coordinator: PipelineCoordinator
    ) async {
        let sandbox: Sandbox
        do {
            sandbox = try await workspaces.createSandbox(id: id)
        } catch {
            await coordinator.registerWorker(id, sandbox: nil)
            while let point = await queue.next() {
                let result = await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "No persistent incremental-build sandbox could be created for this worker: \(error)",
                    durationSeconds: 0
                )
                await collector.add(result)
            }
            await coordinator.workerBuildFinished(id)
            return
        }

        await coordinator.registerWorker(id, sandbox: sandbox)

        while let point = await queue.next(forWorker: id) {
            let started = Date()
            switch await prepare(point, in: sandbox, baseline: baseline, startedAt: started) {
            case let .finished(result):
                await collector.add(result)
            case let .readyToTest(prepared):
                do {
                    let clone = try await workspaces.cloneProducts(
                        from: prepared.artifact.productsDirectory, id: point.id.rawValue
                    )
                    await coordinator.send(Self.relocating(prepared, to: clone), workerID: id)
                } catch {
                    let result = await evidenceAssembler.infrastructureFailureResult(
                        point: point,
                        diagnosis: "This mutant's build could not be cloned out for batched testing: \(error)",
                        evidence: evidenceAssembler.evidence(
                            prepared.applied, artifact: prepared.artifact, activation: prepared.activation
                        ),
                        durationSeconds: Date().timeIntervalSince(started)
                    )
                    await collector.add(result)
                }
            }
            // Always attempted, same reasoning as `runIncrementalWorker`: the
            // next mutant on this worker must start from a pristine file
            // regardless of how this one went — and by this point this
            // mutant's build artifact, if it produced one, has already
            // either been handed to the coordinator or given up on, so
            // nothing here still depends on the sandbox's current contents.
            try? await workspaces.restoreFile(relativePath: point.file, in: sandbox)
        }

        // Not a destroy call: this worker's build loop is done, but clones
        // it produced may still be sitting in the test lane's forming batch
        // or mid-test right now. `workerBuildFinished` only destroys the
        // sandbox if the outstanding-clone count is already zero — see
        // `PipelineCoordinator`.
        await coordinator.workerBuildFinished(id)
    }

    /// The test lane's whole lifetime for the pipelined incremental-plus-
    /// batching path: pulls clones from `coordinator.receive()` as they
    /// arrive from every build worker, accumulates them into a batch, and
    /// tests a batch the moment it reaches `batchSize` — not waiting for
    /// every worker to finish first. `receive()` returns `nil` on its own
    /// once every worker has reported itself finished and every buffered
    /// clone has been drained, which is this loop's only exit condition; a
    /// final partial batch (fewer than `batchSize` clones, however many
    /// were left when the last worker finished) is still flushed after the
    /// loop ends, same as the non-pipelined path's last chunk.
    ///
    /// Runs as a single task: there is exactly one test lane regardless of
    /// worker count, so `batchIndex` (used only for the batch sandbox's
    /// name) is a plain local counter, not a shared actor — nothing else
    /// touches it concurrently.
    func runPipelinedTestLane(
        coordinator: PipelineCoordinator, collector: PipelineCollector,
        baseline: BaselineContext, batchSize: Int
    ) async {
        // `evaluate(_:baseline:)` only dispatches here when `test is any
        // BatchTestable` already held true, so this cannot actually fail —
        // but the fallback below costs nothing, and unlike
        // `testAndFinish`'s equivalent fallback it MUST keep draining and
        // reporting into the coordinator: a build worker's `send` is only
        // balanced by a matching `finishedTesting`, and this lane is the
        // only place that call is made. Abandoning the drain here would
        // leave every worker's outstanding count stuck above zero forever,
        // and their sandboxes never destroyed.
        guard let batchable = batchableTest else {
            while let next = await coordinator.receive() {
                let result = await finishAfterTest(
                    next.item, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: next.item.artifact.command,
                        resultArtifactPath: nil,
                        diagnosis: "The batch test adapter no longer conforms to BatchTestable."
                    ),
                    attribution: .standalone
                )
                try? await workspaces.destroy(next.item.workspace)
                await collector.add(result)
                await coordinator.finishedTesting(workerID: next.workerID)
            }
            return
        }

        var batch: [PreparedMutant] = []
        var batchOwners: [MutationID: String] = [:]
        var batchIndex = 0

        func flush() async {
            guard !batch.isEmpty else { return }
            let outcome = await testOneBatch(
                batch, batchIndex: batchIndex, baseline: baseline, batchable: batchable
            )
            batchIndex += 1
            await collector.addAll(outcome.results)
            await collector.recordBatch(configurations: outcome.configurations, duration: outcome.duration)
            // Every result `testOneBatch` produced owes exactly one
            // decrement to the worker whose build produced its clone —
            // looked up by mutation ID (not by array position) so this
            // stays correct regardless of any future reordering inside
            // `testOneBatch`.
            for result in outcome.results {
                if let workerID = batchOwners[result.point.id] {
                    await coordinator.finishedTesting(workerID: workerID)
                }
            }
            batch.removeAll(keepingCapacity: true)
            batchOwners.removeAll(keepingCapacity: true)
        }

        while let next = await coordinator.receive() {
            // An unattributed mutant (no covering-test attribution) runs its
            // own full configured test list — bundling it into a shared
            // batch, with narrowly-attributed mutants or with another
            // unattributed mutant, would let its cost multiply rather than
            // share: the same bug `Self.chunked` exists to prevent on the
            // non-pipelined path (see its doc comment). Tested alone,
            // immediately, rather than accumulated into `batch` — nothing is
            // gained by waiting for `batchSize` here, since this mutant
            // never shares an invocation with anything else regardless.
            guard next.item.selectedTests != nil else {
                let outcome = await testOneBatch(
                    [next.item], batchIndex: batchIndex, baseline: baseline, batchable: batchable
                )
                batchIndex += 1
                await collector.addAll(outcome.results)
                await collector.recordBatch(configurations: outcome.configurations, duration: outcome.duration)
                await coordinator.finishedTesting(workerID: next.workerID)
                continue
            }
            batch.append(next.item)
            batchOwners[next.item.point.id] = next.workerID
            if batch.count >= batchSize {
                await flush()
            }
        }
        await flush()
    }

    /// Rebuilds a `PreparedMutant` to point at a cloned products directory
    /// instead of the (still-alive, about-to-be-rebuilt) sandbox that built
    /// it. `productHash`/`command` describe the build itself, not where it
    /// happens to be stored, so they carry over unchanged — only the paths
    /// move. Reassigning `sandbox` alongside `artifact` (never one without
    /// the other) is what keeps `MutationConfirmationCoordinator.confirmKill`'s
    /// same-sandbox retest testing the actual mutant it is confirming,
    /// rather than whatever the worker has since rebuilt.
    ///
    /// Extracted from this type: `internal` (not `private`), because
    /// `MutationConfirmationCoordinator.confirmKillIfNeeded`, in its own
    /// file, calls this too — see that method's own doc comment.
    static func relocating(_ prepared: PreparedMutant, to clone: URL) -> PreparedMutant {
        let artifact = BuildArtifact(
            productsDirectory: clone,
            productHash: prepared.artifact.productHash,
            xctestrunPath: prepared.artifact.xctestrunPath.map { clone.appendingPathComponent($0.lastPathComponent) },
            command: prepared.artifact.command
        )
        return PreparedMutant(
            point: prepared.point,
            workspace: .productsClone(clone),
            applied: prepared.applied,
            artifact: artifact,
            activation: prepared.activation,
            observation: prepared.observation,
            selectedTests: prepared.selectedTests,
            startedAt: prepared.startedAt,
            buildDurationSeconds: prepared.buildDurationSeconds,
            // Untouched by this relocation: `confirmationSandbox` is its own,
            // separately established independent clone (see that field's own
            // doc comment) — relocating *this* mutant's primary-test home
            // (the whole point of this function, for a persistent worker's
            // own sandbox) has nothing to do with where its confirmation
            // retest, if any, already lives.
            confirmationSandbox: prepared.confirmationSandbox
        )
    }
}
