import MutationModel

/// Thread-safe result and batch-stat accumulator for the pipelined
/// incremental+batch path, where build workers and the test lane produce
/// results concurrently from separate tasks. Both sides `add`/`addAll` as
/// they go; `evaluateIncrementallyInBatches` takes a single `snapshot` once
/// every task has finished.
actor PipelineCollector {
    private(set) var results: [MutationResult] = []
    private(set) var batchCount = 0
    private(set) var totalConfigurations = 0
    private(set) var batchDurations: [Double] = []

    func add(_ result: MutationResult) {
        results.append(result)
    }

    func addAll(_ newResults: [MutationResult]) {
        results.append(contentsOf: newResults)
    }

    func recordBatch(configurations: Int, duration: Double?) {
        batchCount += 1
        totalConfigurations += configurations
        if let duration { batchDurations.append(duration) }
    }

    func snapshot() -> (results: [MutationResult], summary: BatchExecutionSummary) {
        (
            results,
            BatchExecutionSummary(
                batchCount: batchCount, totalConfigurations: totalConfigurations, batchDurations: batchDurations
            )
        )
    }
}

/// The single point of coordination between the pipelined incremental+batch
/// path's build workers and its one test lane: a many-producer,
/// one-consumer channel of cloned, ready-to-test mutants, *and* the
/// per-worker sandbox-lifetime tracker, combined into one actor on purpose.
///
/// **Why combined.** A worker's own persistent sandbox must stay alive
/// until every clone it produced has been tested — see
/// `evaluateIncrementallyInBatches`'s doc comment for why a single "all
/// builds are done" barrier (which is what the non-pipelined design could
/// rely on) no longer exists once build and test overlap. The natural fix
/// is a per-worker outstanding-clone reference count: incremented when a
/// clone is hand-off to the test lane, decremented when the test lane
/// finishes testing it, and the sandbox destroyed the instant a worker's
/// build loop has ended *and* that count is zero. That increment has to
/// happen atomically with the clone actually becoming visible to the test
/// lane — if `send` returned and only *then*, in a separate actor hop, bumped
/// the count, a test lane fast enough to receive and finish that clone in
/// between could call `finishedTesting` before the increment ever ran,
/// under-counting the outstanding total and destroying the sandbox while a
/// sibling clone from the same worker is still being tested. Making `send`
/// and the increment one isolated method on one actor removes that window
/// entirely: nothing can observe the state between "queued" and "counted".
///
/// **Channel half.** `send` delivers a clone to a waiting `receive` call
/// directly when the test lane is already waiting, or buffers it otherwise.
/// `receive` drains the buffer first, then waits, and returns `nil` once
/// every worker has called `workerBuildFinished` and the buffer is empty —
/// the only shutdown signal it needs, requiring no separate "close" call
/// from the runner.
///
/// **Lifetime half.** `registerWorker` records a worker's sandbox (or `nil`,
/// for a worker whose sandbox never got created); `send` bumps that
/// worker's outstanding count; `finishedTesting` decrements it;
/// `workerBuildFinished` marks the worker's build loop as ended. A worker's
/// sandbox is destroyed by `destroyIfEligible`, called after every state
/// change that could make a worker newly eligible (`workerBuildFinished`
/// and `finishedTesting`), exactly once — `destroyed` guards against a
/// worker whose build ends after its outstanding count is already zero
/// (the common case) *and* a worker whose last clone finishes testing after
/// its build has already ended (the concurrent case) both trying to tear
/// down the same sandbox.
actor PipelineCoordinator {
    /// One clone, still tagged with the worker whose build produced it —
    /// the test lane needs the tag to know which worker's outstanding count
    /// to decrement once this clone's test result is in hand.
    struct Delivery: Sendable {
        let workerID: String
        let item: MutationRunner.PreparedMutant
    }

    private struct WorkerState {
        var sandbox: Sandbox?
        var buildFinished = false
        var outstandingClones = 0
        var destroyed = false
    }

    private let workspaces: WorkspaceManager
    private var workers: [String: WorkerState] = [:]
    private var unfinishedWorkers: Int
    private var buffered: [Delivery] = []
    private var waiters: [CheckedContinuation<Delivery?, Never>] = []

    init(workspaces: WorkspaceManager, workerCount: Int) {
        self.workspaces = workspaces
        unfinishedWorkers = workerCount
    }

    /// Records a worker's own persistent sandbox — or `nil`, when that
    /// worker never managed to create one — before it starts (or, for the
    /// `nil` case, instead of) building. Must be called once per worker
    /// before that worker's first `send`, so `destroyIfEligible` always has
    /// a `WorkerState` to look up.
    func registerWorker(_ id: String, sandbox: Sandbox?) {
        workers[id] = WorkerState(sandbox: sandbox)
    }

    /// Hands a clone to the test lane and, atomically with that handoff,
    /// records it against `workerID`'s outstanding count. See the type's
    /// doc comment for why this has to be one call, not two.
    func send(_ item: MutationRunner.PreparedMutant, workerID: String) {
        workers[workerID, default: WorkerState()].outstandingClones += 1
        let delivery = Delivery(workerID: workerID, item: item)
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: delivery)
        } else {
            buffered.append(delivery)
        }
    }

    /// The test lane's pull side. Drains anything already buffered first;
    /// once nothing is buffered and every worker has finished building,
    /// returns `nil` — there is nothing left this channel will ever
    /// deliver. Otherwise suspends until the next `send` or the last
    /// `workerBuildFinished`.
    func receive() async -> Delivery? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        if unfinishedWorkers == 0 {
            return nil
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Marks `id`'s build loop as ended — it will never `send` again — and,
    /// if that was the last unfinished worker, wakes every still-waiting
    /// `receive` call with `nil`. (Safe to do unconditionally at that point:
    /// `send` only ever buffers when no one is waiting, so if a waiter
    /// exists here, the buffer is necessarily empty and there is truly
    /// nothing left to deliver.) Also re-checks whether `id`'s own sandbox
    /// is now eligible for destruction.
    func workerBuildFinished(_ id: String) async {
        workers[id, default: WorkerState()].buildFinished = true
        unfinishedWorkers -= 1
        if unfinishedWorkers == 0 {
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
            waiters.removeAll()
        }
        await destroyIfEligible(id)
    }

    /// The test lane's report that it has finished testing one clone —
    /// called exactly once per clone, on every path that finishes with one
    /// (a genuine result, a missing-from-batch fallback, a batch
    /// infrastructure failure): decrements `workerID`'s outstanding count
    /// and re-checks eligibility.
    func finishedTesting(workerID: String) async {
        if workers[workerID]?.outstandingClones ?? 0 > 0 {
            workers[workerID]?.outstandingClones -= 1
        }
        await destroyIfEligible(workerID)
    }

    /// A worker's sandbox is destroyed the instant both halves of its
    /// lifetime are done: its build loop has ended, and every clone it ever
    /// produced has been accounted for by the test lane. `destroyed` makes
    /// this idempotent — `workerBuildFinished` and `finishedTesting` can
    /// both land on the same worker becoming eligible from either side of
    /// an adversarial race, and only one of them may actually destroy it.
    private func destroyIfEligible(_ id: String) async {
        guard var state = workers[id],
              state.buildFinished, state.outstandingClones == 0, !state.destroyed,
              let sandbox = state.sandbox
        else { return }
        state.destroyed = true
        workers[id] = state
        try? await workspaces.destroySandbox(sandbox)
    }
}
