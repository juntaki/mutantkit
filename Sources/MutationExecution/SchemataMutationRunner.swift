import Foundation
import MutationModel
import SwiftFrontend

/// The schemata-backend orchestration loop — sibling to `MutationRunner`,
/// not a replacement for it. `MutationRunner` is never touched or called
/// from here; the two are combined by the CLI layer (`SchemataRunOrchestration`),
/// not by either engine type itself.
///
/// One sandbox and one build per chunk, one fresh test process per embedded
/// mutation — see the plan this was built from (the schemata production-integration contract's schemata
/// production-integration effort) for why: `swift test` leaves a
/// `swiftpm-testing-helper` descendant outside the launched process's own
/// group, so the harness can never know the real test process's PID in
/// advance. Every run therefore goes through the same nonce-primary
/// evidence protocol `SchemataEvidenceCollector` already provides for the
/// Xcode case — not Xcode-specific plumbing reused opportunistically, but
/// the one mechanism both backends need.
///
/// Chunks run concurrently, bounded by `workers` (mirrors isolated mode's
/// own `Configuration.execution.resolvedWorkerCount()` convention — see
/// that init parameter's own doc comment) — no checkpointing, no
/// cross-run cache participation. `workers: 1` (the default) reproduces
/// v1's original fully-sequential behaviour exactly, including entry
/// order, since a chunk is only ever launched once the previous one has
/// fully returned.
///
/// `public` (the re-enabled schemata scoring): schemata scoring is re-enabled, so
/// `SchemataRunOrchestration` (`CLI`) constructs and calls one directly
/// for whatever `SchemataChunkPlanner` embeds — everything else still
/// routes to isolated fallback.
public struct SchemataMutationRunner: Sendable {
    let planID: String
    /// A real per-shard identity — see `MutationRunner`'s own equivalent
    /// fix (the authoritative verdict pipeline): `planID` alone cannot distinguish two
    /// shards of the same plan.
    let workUnitID: String
    let programs: [SchemataProgram]
    let points: [MutationID: MutationPoint]
    /// Pristine, pre-lowering file content keyed by `MutationPoint.file` —
    /// the same `sources` map `SchemataChunkPlanner.plan(...)` was given.
    /// Needed to compute honest, non-fabricated source-level evidence
    /// (`MutationEvidence.sourceDiff` and friends) for each embedded
    /// mutation, since `SchemataProgram.loweredSources` only carries the
    /// final, already-rewritten chunk content.
    let originalSources: [String: Data]
    let build: any SchemataBuildable
    let test: any SchemataTestable
    /// `test`'s `TestSelecting` conformance, resolved once here rather than
    /// re-cast in `establishBaseline`'s per-test-coverage branch — `test`
    /// is a `let`, fixed for this runner's whole lifetime. This is the
    /// recommended-but-not-load-bearing half of row C (plan §6 Step 8):
    /// the site it replaces runs at most once per execution already, so
    /// this buys nothing functionally, but keeps this runner consistent
    /// with `MutationRunner`'s own equivalent migration rather than being
    /// the one inconsistent holdout. Wrapper-aware (`testAdapterCapability`),
    /// never a bare `as?`.
    let selectingTest: (any TestSelecting)?
    /// `test`'s `SchemataBatchTestable` conformance, resolved once here —
    /// same reasoning as `selectingTest` above, for row I
    /// (`prepareBatchedPrimaries`).
    let batchableTest: (any SchemataBatchTestable)?
    // `workspaces` migrated to `session.workspaces` — Step 8 of the
    // extraction plan; the same value, just read from the shared session.
    /// The whole `TimeoutSettings` block, not a single pre-resolved number
    /// — because schemata mode needs *two* structurally different limits and
    /// an earlier single-`timeoutSeconds` parameter silently collapsed them
    /// into one. `establishBaseline` runs the full, unmutated suite once and
    /// is bounded by `baselineLimitSeconds`; every per-entry
    /// `runSchemataToken` spawn runs one mutant and must be bounded by the
    /// same per-mutant limit isolated mode uses (`TimeoutController
    /// .mutantLimitSeconds`, resolved adaptively against this run's own
    /// measured baseline duration — see `run()`).
    ///
    /// Measured cost of the collapsed version, on a real 602-mutant corpus
    /// (`swift-async-algorithms`, 2026-08): every schemata mutant was given
    /// the 600 s *baseline* limit instead of the configured 186 s per-mutant
    /// one, and the 19 mutants that actually hit it burned 5.99 h of the
    /// 6.58 h total schemata wall time — ~4 h of a 21 h run. Isolated mode
    /// was correct throughout; only this backend was over-budgeted.
    let timeouts: TimeoutSettings
    /// The real toolchain/build-argument identity this run's plan was
    /// validated against (`ExecutableSchemataPlan.toolchainHash`/
    /// `buildArgumentsHash`) — hashed once into the `SHA256Digest` shape
    /// `SchemataBuildReceipt` requires. A genuine content hash of the
    /// plan's own already-validated identity strings, not a placeholder.
    let toolchainHash: SHA256Digest
    let buildArgumentsHash: SHA256Digest
    /// The same `VerdictVerificationPolicy` an isolated `MutationRunner`
    /// would be constructed with for this run — the one source of truth
    /// both backends ask `MutationVerdictVerifier.confirmationRequirement`
    /// against, so schemata mode gathers exactly the confirmations
    /// `retestKilledMutants`/`confirmCrashKills`/`confirmTimedOutMutants`
    /// promise, never a policy this runner invents on its own.
    /// Migrated to `session.policy` — Step 8 of the extraction plan (the
    /// same value: `session.policy` is built from this exact `policy`
    /// parameter, in `init`, below).
    /// `configuration.execution.selectCoveringTests`, mirrored the same way
    /// `MutationRunner` reads it: covering-test selection is opt-in, and
    /// `false` (the config schema's own default) must reproduce this
    /// runner's exact pre-existing behaviour — every embedded mutation's
    /// token run against the full configured test list, unrestricted.
    let selectCoveringTests: Bool
    /// Fail-closed timeout evidence's per-chunk hang budget: how many verifier-confirmed
    /// `.verifiedTimeout` entries one chunk may accumulate before its
    /// remaining not-yet-fully-finalized `MutationID`s are dropped from
    /// schemata scoring and routed to isolated-mode fallback instead (see
    /// `runEntries`). **Count-based, not wall-clock, and deliberately not a
    /// tuned production value** — the ADR itself leaves the exact budget
    /// composition open pending real-corpus data (§"Not Yet Decided"); this
    /// default exists only so every pre-the schemata timeout-isolation design call site keeps compiling,
    /// not as a considered choice. A future milestone's real-corpus
    /// validation should set the production default deliberately, not
    /// inherit this placeholder.
    let maxVerifiedTimeoutsPerChunk: Int
    /// How many `programs` chunks may run concurrently — the same
    /// `Configuration.execution.resolvedWorkerCount()` convention isolated
    /// mode's own `MutationRunner.evaluate` already resolves and bounds its
    /// worker pool by (`half the core count` when unset), mirrored here
    /// rather than reinvented. Defaults to `1`: every pre-existing call site
    /// that constructs a `SchemataMutationRunner` without this parameter
    /// keeps today's fully-sequential behaviour, unchanged.
    let workers: Int
    /// The same cross-run per-test coverage cache isolated mode's own
    /// `MutationRunner` already consults, reused verbatim rather than
    /// reinvented for this backend: the attribution pass it skips is the
    /// single most expensive thing either backend's baseline does, and it
    /// depends on the source tree/tests/toolchain — not on which backend or
    /// which mutants are running — so both backends are entitled to the same
    /// entry under the same key. `nil` (the default) means "not configured",
    /// which reproduces this runner's exact pre-cache behaviour: measure on
    /// every run, consult nothing, store nothing.
    /// Migrated to `session.coverageCache` — Step 8 of the extraction plan.
    /// The digest identifying *which* measured attribution a cache entry is
    /// (`RunContextProbe.computeContextDigest`, computed in the CLI layer).
    /// `nil` means the CLI could not compute one — a best-effort degradation,
    /// never a failed run — and, exactly as in `MutationRunner`, that means
    /// coverage is measured fresh and nothing is stored.
    /// Migrated to `session.coverageCacheKey` — Step 8 of the extraction plan.
    /// When supplied, `establishBaseline()` uses this instead of building
    /// and testing the project itself — see `SharedBaselineEstablisher`'s
    /// own doc comment. `nil` for every existing caller (a plain schemata
    /// run with no isolated-fallback portion), which is unaffected by this
    /// parameter's existence.
    /// Migrated to `session.preEstablishedBaseline` — Step 8 of the
    /// extraction plan.
    /// The most primary token attempts `runEntries` will fold into one
    /// shared `runSchemataTokenBatch` call, mirroring isolated mode's own
    /// `execution.testBatchSize` (the identical setting `testOneBatch`/
    /// `testWaveChunk` already use) rather than inventing a separate
    /// schemata-specific knob. Defaults to `1`: every pre-existing call
    /// site that constructs a `SchemataMutationRunner` without this
    /// parameter keeps today's fully-unbatched, one-fresh-process-per-token
    /// behaviour, unchanged — the same opt-in-by-default-value convention
    /// `workers` already uses above. `<= 1` disables batching outright
    /// (see `prepareBatchedPrimaries`): a "batch" of one token has no
    /// containment benefit over the unbatched path.
    let schemataTokenBatchSize: Int
    /// Kill baseline controls already run against a built chunk.
    let baselineControls = BaselineControlMemo()
    /// Counts *chunks*, not mutants: a chunk is this backend's unit of
    /// build-and-test work, so it is what a human watching the run is
    /// actually waiting on. The isolated backend counts mutants for the same
    /// reason — there, one mutant is one build-and-test cycle.
    let progress: MutationModel.ProgressReporter?

    /// Where each finalized mutant's raw observations are written when the run
    /// asked for an evidence archive. The same writer isolated mode records
    /// into; without it a schemata result could never be re-verified offline.
    let evidenceArchive: EvidenceArchiveWriter?

    /// The shared, immutable execution-session type `MutationRunner` also
    /// constructs internally — see `RunSession`'s own doc comment. Built
    /// once, at the end of `init`, from the subset of this initializer's
    /// parameters `RunSession`
    /// can actually represent (`workspaces`, `policy`, `coverageCache`,
    /// `coverageCacheKey`, `preEstablishedBaseline`) — `projectRoot`/
    /// `toolchain` are `nil` for this runner, since it never receives either
    /// (see `RunSession`'s doc comment; `configuration` isn't a `RunSession`
    /// field at all, for the same reason). This
    /// runner's own former `workspaces`/`policy`/`coverageCache`/
    /// `coverageCacheKey`/`preEstablishedBaseline` stored properties were
    /// removed in Step 8 in favor of reading these same values from
    /// `session` — a rename, not a re-derivation: every one of these fields
    /// is still set, once, straight from the identical `init` parameter it
    /// always came from.
    let session: RunSession

    public init(
        planID: String,
        workUnitID: String,
        programs: [SchemataProgram],
        points: [MutationID: MutationPoint],
        originalSources: [String: Data],
        build: any SchemataBuildable,
        test: any SchemataTestable,
        workspaces: WorkspaceManager,
        timeouts: TimeoutSettings,
        toolchainHash: String,
        buildArgumentsHash: String,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy,
        maxVerifiedTimeoutsPerChunk: Int = 3,
        selectCoveringTests: Bool = false,
        workers: Int = 1,
        coverageCache: CoverageProfileCache? = nil,
        coverageCacheKey: CoverageProfileCache.Key? = nil,
        preEstablishedBaseline: SharedBaselineEstablisher.Outcome? = nil,
        schemataTokenBatchSize: Int = 1,
        progress: MutationModel.ProgressReporter? = nil,
        evidenceArchive: EvidenceArchiveWriter? = nil
    ) {
        self.evidenceArchive = evidenceArchive
        self.planID = planID
        self.workUnitID = workUnitID
        self.programs = programs
        self.points = points
        self.originalSources = originalSources
        self.build = build
        self.test = test
        selectingTest = testAdapterCapability((any TestSelecting).self, for: test)
        batchableTest = testAdapterCapability((any SchemataBatchTestable).self, for: test)
        self.timeouts = timeouts
        self.toolchainHash = SHA256Digest.of(Data(toolchainHash.utf8))
        self.buildArgumentsHash = SHA256Digest.of(Data(buildArgumentsHash.utf8))
        self.maxVerifiedTimeoutsPerChunk = maxVerifiedTimeoutsPerChunk
        self.selectCoveringTests = selectCoveringTests
        self.workers = workers
        self.schemataTokenBatchSize = schemataTokenBatchSize
        self.progress = progress
        self.session = RunSession(
            projectRoot: nil,
            toolchain: nil,
            workspaces: workspaces,
            policy: policy,
            coverageCache: coverageCache,
            coverageCacheKey: coverageCacheKey,
            preEstablishedBaseline: preEstablishedBaseline
        )
    }

    public func run() async throws -> Outcome {
        let established = try await establishBaseline()
        let baseline = established.record
        let perTestCoverage = established.perTestCoverage
        let coverage = established.coverage
        // Both paths in `establishBaseline` already throw on a baseline that
        // did not pass, each with its own observed diagnosis. What is left
        // here is the one case neither covers: a caller-supplied
        // `.established(_)` whose `record` nevertheless says it failed —
        // `SharedBaselineEstablisher` never produces one, but the type
        // permits it, and proceeding would score mutants against a suite
        // that was never green. Only here is a sentence reconstructed from
        // the counts, because here there is no observation left to quote.
        guard baseline.passed else {
            let summary = baseline.testSummary.map { "\($0.failed) of \($0.total) tests failed" }
            throw RunError.baselineDidNotPass(
                record: baseline, diagnosis: summary ?? "the baseline test run did not pass"
            )
        }

        // The post-hang recovery semantics(b): a `MutationID` embedded into more than one target
        // lands in a *different* `SchemataProgram`/chunk per target
        // (`SchemataChunkPlanner.classify`), so "is this MutationID fully
        // finalized" can never be answered from inside one chunk alone.
        // `expectedPlacementsByMutationID` is computed once, up front, from
        // every program's own entries; `completedPlacementsByMutationID` is
        // folded in only *after* each chunk fully returns (never mid-chunk),
        // so what a still-running chunk's own overflow check consults is
        // always "every *other* chunk's contribution so far" — its own
        // chunk's contribution is accounted for separately, inline, by
        // `runEntries` itself (see that function's overflow-closure comment).
        //
        // Now that chunks run concurrently (`workers` > 1), this is the one
        // piece of cross-chunk state that cannot stay a plain snapshot: two
        // concurrently-running chunks that both embed the same `MutationID`
        // may each hit their own hang-budget overflow around the same time,
        // and each must see the other's up-to-date-as-of-now contribution,
        // not one frozen at whichever moment they happened to start. Wrapped
        // in `CompletedPlacementsTracker` (an actor) for that reason — and,
        // just as importantly, the *read* point was moved, not only the
        // storage: a chunk that snapshotted once at its own start could sit
        // on a stale value for its entire (possibly long) run, missing a
        // concurrently-running sibling's fold-in that lands anywhere after
        // that start. `runEntries` instead reads the tracker fresh at the
        // one moment that actually matters — right where its own
        // hang-budget overflow fires, immediately before
        // `hangBudgetOverflowClosure` is called — so the value consulted is
        // always as current as the tracker allows, however long this
        // chunk's own run took to get there. The fold-in write is
        // unchanged: once per chunk, made only after that chunk fully
        // returns. `hangBudgetOverflowClosure` itself stays fully
        // synchronous, consulting a plain `[MutationID: Int]` handed to it
        // fresh by its caller, unaware this is backed by an actor.
        let expectedPlacementsByMutationID = Self.expectedPlacementCounts(programs: programs)
        let completedPlacements = CompletedPlacementsTracker()

        // The per-mutant limit, resolved exactly the way isolated mode
        // resolves its own (`MutationRunner.establishBaseline` ->
        // `TimeoutController.recordingBaseline`): adaptively, from the
        // measured duration of *this* run's own baseline test execution,
        // falling back to the configured ceiling when the baseline reported
        // no test duration at all. Never the baseline's own limit — a
        // baseline runs the whole unmutated suite once, one token run runs
        // one mutant, and conflating the two is what made a hanging schemata
        // mutant cost 600 s where isolated mode spent 186 s (see `timeouts`).
        //
        // The controller itself — not a single pre-resolved `Double` — is
        // threaded down to every chunk/entry from here on: each embedded
        // entry has its own `selectedTests` (resolved in `runPrimary`, the
        // same call site isolated mode's own `prepare` resolves it at), and
        // `TimeoutController.mutantLimitSeconds(selectedTests:)` needs the
        // live controller so an entry without a usable selection still falls
        // back to this whole-suite-scaled value, while an entry with a
        // known, non-empty selection gets the small, fixed 10...30s clamp
        // instead — see that method's own doc comment.

        let timeoutController = TimeoutController(settings: timeouts)
        let resolvedTimeoutController = baseline.testDurationSeconds
            .map { timeoutController.recordingBaseline(durationSeconds: $0) }
            ?? timeoutController

        // Bounded fan-out (mirrors `MutationRunner.evaluate`'s own "one in,
        // one out" `TaskGroup` pattern): at most `workers` chunks in flight
        // at once. `workers: 1` launches the next chunk only once
        // `group.next()` yields the previous one's result, which is exactly
        // today's sequential order — same chunk-start snapshot point, same
        // fold-in point, same `entryOutcomes`/`buildFailureEvents`
        // accumulation order as the old `for program in programs` loop.
        let chunkContext = ChunkRunContext(
            timeoutController: resolvedTimeoutController, perTestCoverage: perTestCoverage, coverage: coverage,
            expectedPlacementsByMutationID: expectedPlacementsByMutationID, tracker: completedPlacements
        )
        var entryOutcomes: [EntryRunOutcome] = []
        var buildFailureEvents: [SharedChunkBuildFailureEvent] = []
        var infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent] = []
        let workerCount = max(1, workers)

        await withTaskGroup(of: ChunkTaskOutcome.self) { group in
            var remainingPrograms = programs.makeIterator()

            for _ in 0 ..< workerCount {
                guard let program = remainingPrograms.next() else { break }
                group.addTask {
                    await self.runChunkTracked(program, context: chunkContext)
                }
            }

            while let result = await group.next() {
                entryOutcomes.append(contentsOf: result.outcomes)
                buildFailureEvents.append(contentsOf: result.buildFailureEvents)
                infrastructureFallbackEvents.append(contentsOf: result.infrastructureFallbackEvents)
                await progress?.recordCompletion()
                if let program = remainingPrograms.next() {
                    group.addTask {
                        await self.runChunkTracked(program, context: chunkContext)
                    }
                }
            }
        }

        // All-or-nothing per MutationID (never per placement): if *any* of
        // a mutation's target placements lacked runtime activation proof,
        // every placement's own schemata `TargetRecord` for that
        // `MutationID` — including one that individually verified fine —
        // is dropped before grouping. Never merge a schemata result for
        // one target with an isolated-fallback result for another; that
        // would double-ledger the same MutationID across two backends.
        var dynamicFallbackReasons: [MutationID: SchemataFallbackReason] = [:]
        for case let .isolatedFallback(mutationID, reason) in entryOutcomes {
            dynamicFallbackReasons[mutationID] = reason
        }
        let perTarget: [TargetRecord] = entryOutcomes.compactMap {
            guard case let .verified(record) = $0, dynamicFallbackReasons[record.record.mutationRef.mutationID] == nil else { return nil }
            return record
        }

        // Sorted by `MutationID`, not `entryOutcomes`'s own accumulation
        // order: with chunks now running concurrently, that accumulation
        // order follows completion order, not `programs` order, so it is no
        // longer deterministic run-to-run. `groupByMutation`'s own
        // first-appearance-in-`perTarget` order would otherwise leak that
        // nondeterminism into `results`/`multiTargetVerdicts` — sorted here
        // for the same reason `isolatedFallbacks` below already is.
        let grouped = try Self.groupByMutation(perTarget)
            .sorted { $0.verdict.mutationRef.mutationID.rawValue < $1.verdict.mutationRef.mutationID.rawValue }
        let verdicts = grouped.map { $0.verdict }
        let results = try grouped.map {
            try Self.projectAggregate($0, points: points, planID: planID, workUnitID: workUnitID)
        }
        // Deterministic order (sorted, not orchestration/completion order),
        // the same discipline `SchemataChunkPlanner`'s own chunk IDs use.
        let isolatedFallbacks = dynamicFallbackReasons
            .map { DynamicFallback(mutationID: $0.key, reason: $0.value) }
            .sorted { $0.mutationID.rawValue < $1.mutationID.rawValue }
        return Outcome(
            baseline: baseline, results: results, multiTargetVerdicts: verdicts, isolatedFallbacks: isolatedFallbacks,
            sharedChunkBuildFailureEvents: buildFailureEvents,
            infrastructureFallbackEvents: infrastructureFallbackEvents
        )
    }
}
