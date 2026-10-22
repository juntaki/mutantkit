import Dispatch
import Foundation
import MutationModel

/// Executes a plan in isolated mode and reports what it can prove.
///
/// The shape of a run is: establish a baseline, then for each planned mutation
/// build a sandbox, apply exactly one edit, build it, test it, classify it,
/// checkpoint it, and throw the sandbox away.
///
/// Two things are load-bearing:
///
/// 1. **The baseline is a gate, not a data point.** If the unmutated suite does
///    not build and pass, every mutant outcome measured against it is noise —
///    a "survived" mutant in a red suite means nothing at all. The run stops and
///    reports no score rather than producing numbers it cannot stand behind.
///
/// 2. **Order is a property of the plan, not of the schedule.** Mutants run
///    concurrently and finish in whatever order the machine decides, so results
///    are sorted back into `MutationID` order before anything reads them. Two
///    runs of the same plan produce the same report.
///
/// The adapters are injected: this type knows about building and testing, and
/// nothing about `xcodebuild`, `swift test`, or simulators.
public struct MutationRunner: Sendable {
    let plan: MutationPlan
    let configuration: Configuration
    let build: any BuildAdapter
    let test: any TestAdapter
    /// `test`'s `BatchTestable` conformance, resolved once here — `test` is
    /// a `let`, fixed for this runner's whole lifetime, so memoizing is
    /// bit-for-bit equivalent to re-casting on every call. Wrapper-aware
    /// (`testAdapterCapability`), never a bare `as?`, per the same
    /// reasoning as `MutationConfirmationCoordinator`'s memoized
    /// properties.
    let batchableTest: (any BatchTestable)?
    private let checkpoints: CheckpointStore?
    private let artifactsRoot: URL?
    private let resultCache: MutationResultCache?
    private let resultCacheDigest: String?
    let priorityStore: TestPriorityStore?
    let monotonicNow: @Sendable () -> TimeInterval
    let operationalIssues = OperationalIssueLog()
    private let progress: MutationModel.ProgressReporter?
    /// See `RunStopRequest`: once requested, no new mutant is started.
    let stop: RunStopRequest?

    /// Retesting a decided outcome (same-artifact confirmation for a kill,
    /// fresh-rebuild confirmation for a crash or a timeout) and the
    /// test-running primitive every one of those, and this runner's own
    /// primary test run, executes through — see that type's own doc
    /// comment. Extracted out of this type: constructed once in
    /// `init`, from the same `workspaces`/`build`/`test`/`configuration`
    /// this runner itself was given.
    let confirmationCoordinator: MutationConfirmationCoordinator

    /// Turning raw build/test/application observations into a reportable
    /// `MutationResult` — see that type's own doc comment. Extracted
    /// out of this type: constructed once in `init`, sharing
    /// this runner's own `operationalIssues` log by reference (not a copy),
    /// so a warning `finalize` records still reaches this run's own
    /// `RunReport.operationalIssues` below.
    let evidenceAssembler: MutationEvidenceAssembler

    /// The shared, immutable execution-session type both this runner and
    /// `SchemataMutationRunner` construct internally — see `RunSession`'s
    /// own doc comment. Built once, at the end of `init`, from parameters
    /// this initializer already receives (or derives, for
    /// `toolchain`/`policy`). An earlier restructuring pass migrated every
    /// one of this runner's own internal reads of
    /// `projectRoot`/`toolchain`/`workspaces`/`coverageCache`/
    /// `coverageCacheKey`/`preEstablishedBaseline` onto `session` — see the
    /// computed properties immediately below, which are now those fields'
    /// one reading path. `plan`/`configuration`/`build`/`test` and the
    /// isolated-only fields above stay this runner's own stored properties —
    /// `RunSession` carries no `configuration` field at all (see that type's
    /// own doc comment): it is read in far more places in this file than
    /// every field below combined, and the plan's Step 7 deliberately stops
    /// the migration short of it — a mechanical, low-information rename left
    /// for a future step if wanted.
    private let session: RunSession

    /// `session.projectRoot`, unwrapped: never `nil` for a `MutationRunner`
    /// itself — this runner's own `init` always supplies a real value.
    /// Only `SchemataMutationRunner`'s own session ever leaves this field
    /// `nil` (see `RunSession`'s doc comment for why the field is Optional
    /// at the shared-type level at all).
    var projectRoot: URL { session.projectRoot! }

    /// `session.toolchain`, unwrapped — the toolchain doing the running,
    /// which is not necessarily the one that did the planning; defaults to
    /// the plan's own (see `init`). Same non-`nil` guarantee as
    /// `projectRoot` above.
    var toolchain: ToolchainFingerprint { session.toolchain! }

    /// `session.workspaces` — the sandbox lifecycle every build/test/
    /// confirmation path in this file goes through.
    var workspaces: WorkspaceManager { session.workspaces }

    /// `session.coverageCache` — when supplied with `coverageCacheKey`, the
    /// baseline pass's per-test coverage attribution is loaded from this
    /// cache instead of re-measured when the key matches a prior run. See
    /// `init`'s own doc comment for the full contract.
    var coverageCache: CoverageProfileCache? { session.coverageCache }

    /// `session.coverageCacheKey` — see `coverageCache` above.
    var coverageCacheKey: CoverageProfileCache.Key? { session.coverageCacheKey }

    /// `session.preEstablishedBaseline` — when supplied, `establishBaseline()`
    /// uses this instead of building and testing the project itself —
    /// `SchemataRunOrchestration`'s own mechanism for sharing one baseline
    /// between the schemata and isolated-fallback passes (see
    /// `SharedBaselineEstablisher`'s own doc comment). `nil` for every other
    /// caller, which is every existing one: this parameter changes nothing
    /// about a plain `mutantkit run --strategy isolated`.
    var preEstablishedBaseline: SharedBaselineEstablisher.Outcome? { session.preEstablishedBaseline }

    /// Cannot collide with a mutant's sandbox: every mutation ID starts `mut_`.
    static let baselineSandboxID = "baseline"

    /// - Parameters:
    ///   - checkpoints: when supplied, results are persisted as they land and
    ///     mutations already recorded there are not re-run.
    ///   - artifactsRoot: where to keep result bundles once their sandbox is
    ///     gone. Without it there is nowhere for an `.xcresult` to survive, and
    ///     the evidence records no path rather than a dangling one.
    ///   - toolchain: the toolchain doing the running, which is not necessarily
    ///     the one that did the planning. Defaults to the plan's.
    ///   - coverageCache: when supplied with `coverageCacheKey`, the baseline
    ///     pass's per-test coverage attribution is loaded from this cache
    ///     instead of re-measured when the key matches a prior run, and a
    ///     fresh measurement is stored back into it for the next run. The
    ///     baseline build and test still always run — coverage is the only
    ///     thing skipped, because every other responsibility of the baseline
    ///     (the suite-must-pass gate, the timeout calibration, the activation
    ///     hash) still has to be earned on every run.
    ///   - resultCache: when supplied with `resultCacheDigest`, a mutant whose
    ///     `MutationID` was already evaluated against an identical execution
    ///     context (same source, test suite, toolchain, configuration —
    ///     captured in the digest) is reused without rebuilding or retesting.
    ///     The baseline still always runs: the cache carries mutant verdicts,
    ///     not the suite-must-pass gate or timeout calibration those verdicts
    ///     were measured against. Checkpoint hits take priority over cache
    ///     hits — a checkpoint is always-trusted state from the same run,
    ///     while a cache entry is a cross-run inference.
    ///   - priorityStore: when supplied alongside `earlyAbortSelectedTests`
    ///     and `testBatchSize`, the test phase uses wave-based early kill
    ///     instead of ordinary batching: each wave batch-tests one
    ///     prioritised covering test per surviving mutant, and a mutant
    ///     that fails its wave's test is killed and drops out rather than
    ///     running its remaining covering tests — see `testInWaves`. Without
    ///     a store, batched testing runs every mutant's full selection in
    ///     one shot per `testAndFinish`, unchanged; early abort is then only
    ///     available through the CLI's per-invocation `PrioritizingTestAdapter`
    ///     wrapping, which does not require batching at all.
    ///   - monotonicNow: what the wave loop's cumulative-budget measurement
    ///     (`testWaveChunk`/`standaloneVerify`) reads elapsed time from.
    ///     Defaults to a monotonic uptime clock — never `Date`/wall-clock
    ///     time, which can jump backward or forward under a clock
    ///     correction or manual change mid-run, corrupting a budget that
    ///     must only ever measure elapsed time. Tests substitute a manually-
    ///     advanced fake clock so a wave's simulated duration is an exact,
    ///     deterministic quantity instead of `Task.sleep`'s real elapsed
    ///     time, which CPU contention from unrelated concurrently-running
    ///     tests can inflate past a budget boundary the test never intended
    ///     to cross.
    public init(
        plan: MutationPlan,
        configuration: Configuration,
        projectRoot: URL,
        build: any BuildAdapter,
        test: any TestAdapter,
        workspaces: WorkspaceManager,
        checkpoints: CheckpointStore? = nil,
        artifactsRoot: URL? = nil,
        toolchain: ToolchainFingerprint? = nil,
        coverageCache: CoverageProfileCache? = nil,
        coverageCacheKey: CoverageProfileCache.Key? = nil,
        resultCache: MutationResultCache? = nil,
        resultCacheDigest: String? = nil,
        priorityStore: TestPriorityStore? = nil,
        progress: MutationModel.ProgressReporter? = nil,
        evidenceArchive: EvidenceArchiveWriter? = nil,
        preEstablishedBaseline: SharedBaselineEstablisher.Outcome? = nil,
        stop: RunStopRequest? = nil,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    ) {
        self.plan = plan
        self.configuration = configuration
        self.build = build
        self.test = test
        batchableTest = testAdapterCapability((any BatchTestable).self, for: test)
        self.checkpoints = checkpoints
        self.artifactsRoot = artifactsRoot
        self.resultCache = resultCache
        self.resultCacheDigest = resultCacheDigest
        self.priorityStore = priorityStore
        self.progress = progress
        self.stop = stop
        self.monotonicNow = monotonicNow
        // Computed once, here, and handed to every collaborator below that
        // needs it (`confirmationCoordinator`, `evidenceAssembler`,
        // `session`) — the Step 1 factory this calls is already the one
        // canonical derivation from `Configuration.execution`, so computing
        // it three times inline (as before Step 9) was itself a small
        // instance of the exact duplication Step 1 exists to remove, even
        // though every call always agreed bit-for-bit.
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(configuration.execution)
        self.confirmationCoordinator = MutationConfirmationCoordinator(
            workspaces: workspaces, build: build, test: test, policy: policy, projectRoot: projectRoot
        )
        self.evidenceAssembler = MutationEvidenceAssembler(
            plan: plan,
            policy: policy,
            checkpoints: checkpoints,
            artifactsRoot: artifactsRoot,
            resultCache: resultCache,
            resultCacheDigest: resultCacheDigest,
            progress: progress,
            operationalIssues: operationalIssues,
            evidenceArchive: evidenceArchive,
            stop: stop
        )
        self.session = RunSession(
            projectRoot: projectRoot,
            toolchain: toolchain ?? plan.toolchain,
            workspaces: workspaces,
            policy: policy,
            coverageCache: coverageCache,
            coverageCacheKey: coverageCacheKey,
            preEstablishedBaseline: preEstablishedBaseline
        )
    }

    // MARK: - Run

    public func run() async throws -> RunReport {
        let startedAt = Date()

        let baseline: BaselineContext
        switch await establishBaseline() {
        case let .failed(record, diagnosis):
            return failClosedReport(startedAt: startedAt, baseline: record, diagnosis: diagnosis)
        case let .established(context):
            baseline = context
        }

        // An injected baseline's retained control products belong to its owner.
        let owned = preEstablishedBaseline == nil ? baseline.control : nil
        return try await BaselineControlSource.disposing(owned) { try await finishRun(startedAt: startedAt, baseline: baseline) }
    }

    private func finishRun(startedAt: Date, baseline: BaselineContext) async throws -> RunReport {
        // Checkpoint hits first: same-run resume is always-trusted, so it
        // takes priority over the cross-run cache. A mutant already
        // recorded in a checkpoint is removed from the pool the cache is
        // consulted against, so the two stores cannot double-count.
        let resumed = ((try await checkpoints?.loadAll(plan: plan)) ?? []).map { $0.markedAsCheckpointResume() }
        let checkpointedIDs = Set(resumed.map(\.id))

        // Cross-run result cache: a mutant whose MutationID was evaluated
        // against an identical execution context (same source, tests,
        // toolchain, configuration) is reused without rebuilding or
        // retesting. The cache stores only reportable, integrity-safe
        // verdicts — infrastructure failures and other environmental state
        // are never cached (see `MutationResultCache.store`).
        var cacheHits: [MutationResult] = []
        var pending: [MutationPoint] = []
        for point in plan.mutations where !checkpointedIDs.contains(point.id) {
            if let digest = resultCacheDigest,
               let cached = await resultCache?.load(
                   MutationResultCache.Key(mutationID: point.id, contextDigest: digest),
                   point: point, planID: plan.planID, workUnitID: plan.workUnitID
               ) {
                cacheHits.append(cached)
            } else {
                pending.append(point)
            }
        }

        var results = resumed + cacheHits
        // Every freshly-evaluated mutant's own `finalize` call already wrote
        // it to the checkpoint and (when cacheable) the cross-run cache,
        // right next to the raw `MutationObservations` that produced it —
        // no separate store pass is needed here (the authoritative verdict pipeline, second
        // review round: `finalize`'s own doc comment explains why the write
        // moved there).
        var evaluated: [MutationResult] = []
        var batchExecution: BatchExecutionSummary?
        do {
            (evaluated, batchExecution) = try await evaluate(pending, baseline: baseline)
        } catch where stop?.isStopRequested == true {
            // A forced stop cancelled the run mid-flight. What this run
            // finished is exactly what its checkpoint holds, so rebuild from
            // that rather than from results the thrown error discarded.
            let persisted = ((try? await checkpoints?.loadAll(plan: plan)) ?? []).map { $0.markedAsCheckpointResume() }
            let known = Set(resumed.map(\.id))
            evaluated = persisted.filter { !known.contains($0.id) }
        }
        // Results of mutants cut short by a forced stop are artifacts of the
        // termination (see `MutationEvidenceAssembler.finalize`), not verdicts.
        if let stop { evaluated.removeAll { stop.wasDiscarded($0.id) } }

        results.append(contentsOf: evaluated)
        results.sort { $0.id < $1.id }

        // The authoritative verdict pipeline: the ledger, not the plain array, is this run's
        // authoritative result state — `results` above is retired to a
        // display-ordering convenience the moment every result has been
        // gathered. A duplicate insert here (the identical `MutationID`
        // reaching both a checkpoint/cache hit and a freshly-evaluated
        // result, say) is a real bug this construction surfaces
        // immediately, not a `Set`-based count mismatch `IntegrityChecker`
        // would have had to notice after the fact.
        var ledger = ResultLedger<MutationResult>()
        for result in results {
            try ledger.insert(result)
        }

        // Marked partial only when the stop actually left planned mutants
        // without a result; a signal that arrives after the last one finished
        // changes nothing about a complete report.
        let planned = Set(plan.mutations.map(\.id))
        let interruption: RunInterruption? = stop.flatMap { stop in
            guard stop.isStopRequested, !planned.isSubset(of: Set(ledger.mutationIDs)) else { return nil }
            return RunInterruption(
                signal: stop.signalName ?? "unknown",
                completedMutants: planned.intersection(ledger.mutationIDs).count,
                plannedMutants: planned.count
            )
        }

        return RunReport(
            planID: plan.planID,
            startedAt: startedAt,
            finishedAt: Date(),
            projectRoot: projectRoot.path,
            toolchain: toolchain,
            baseline: baseline.record,
            ledger: ledger,
            integrity: IntegrityChecker.check(
                plan: plan, ledger: ledger, baselinePassed: true, interruptedBy: interruption
            ),
            batchExecution: batchExecution,
            operationalIssues: await operationalIssues.snapshot(),
            interruption: interruption
        )
    }

    /// Runs the pending mutations, at most `resolvedWorkerCount()` at a time.
    func evaluate(
        _ pending: [MutationPoint], baseline: BaselineContext
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        if let batchSize = configuration.execution.testBatchSize, batchSize > 0,
           batchableTest != nil {
            if configuration.execution.incrementalBuild {
                // Wave-based early kill (`testInWaves`, dispatched from
                // `testAndFinish`) has no pipelined equivalent: it tests one
                // mutant's ONE next prioritised test per wave and carries
                // survivors forward across rounds, which has no
                // correspondence in the pipelined test lane's model of "a
                // clone arrives once, is tested once, is done." Routing a
                // wave-mode configuration through pipelining would silently
                // disable early abort — every mutant would run its whole
                // selected-test list, and priority history would never be
                // read or updated — so it keeps using the sequential
                // (non-pipelined) build-then-test path instead, which still
                // reaches `testAndFinish` and therefore `testInWaves`. Only
                // when wave mode is NOT requested does pipelining apply.
                if configuration.execution.earlyAbortSelectedTests, priorityStore != nil {
                    return try await evaluateIncrementallyInBatchesSequential(pending, baseline: baseline, batchSize: batchSize)
                }
                return try await evaluateIncrementallyInBatches(pending, baseline: baseline, batchSize: batchSize)
            }
            return try await evaluateInBatches(pending, baseline: baseline, batchSize: batchSize)
        }

        if configuration.execution.incrementalBuild {
            return (try await evaluateIncrementally(pending, baseline: baseline), nil)
        }

        let workers = max(1, configuration.execution.resolvedWorkerCount())
        var collected: [MutationResult] = []

        try await withThrowingTaskGroup(of: MutationResult.self) { group in
            var remaining = pending.makeIterator()

            for _ in 0 ..< workers {
                guard stop?.isStopRequested != true, let point = remaining.next() else { break }
                group.addTask { await evaluate(point, baseline: baseline) }
            }

            // One in, one out: builds are the most expensive thing this tool
            // does and running more of them than the machine has workers for
            // buys contention, not throughput.
            while let result = try await group.next() {
                collected.append(result)
                if stop?.isStopRequested != true, let point = remaining.next() {
                    group.addTask { await evaluate(point, baseline: baseline) }
                }
            }
        }

        return (collected, nil)
    }
}
