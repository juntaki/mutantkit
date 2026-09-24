import Foundation
import MutationModel
import SwiftFrontend

/// Combines the schemata backend's `SchemataMutationRunner` with the
/// existing, unmodified `MutationRunner` into one `RunReport` (ADR-0006
/// Stage 3) — the shared engine `Sources/CLI/Commands/
/// SchemataRunOrchestration.swift` is being migrated onto (part of this
/// project's internal execution-engine restructuring; see its own,
/// private planning notes, not part of this public repo, for the full
/// rationale). This file is filled in incrementally,
/// one plan step at a time; each addition here is a verbatim relocation of
/// code that already lived (and was already tested) in
/// `SchemataRunOrchestration`, never a rewrite.
///
/// Populated so far (plan §3 Steps 1-4): the pure, already-directly-tested
/// helpers from Step 1 — `SchemataPortionResult`, `BaselineResolution`,
/// `resolveBaseline`, the four issue/count helper functions, and
/// `toolchainHash`; from Step 2, the plain-data `Context` and
/// `PortionCounts` types and the `adapterNotSchemataCapable` half of the
/// former `SchemataRunOrchestration.OrchestrationError`; from Step 3, the
/// renamed, public `SchemataClassification`; and from Step 4,
/// `establishSharedBaseline`/`SchemataPortionInputs`/`runSchemataPortion`/
/// `runFallbackPortion`/`merge`, plus the whole former `run()` body as the
/// new `runHybrid`; from Step 5, the plain-data `IsolatedRunOptions` and the
/// new `runIsolated` entry point. Everything else (`RunCommand.execute`'s
/// own two-case dispatch) still lives outside this file and moves in the
/// final plan step (6); `classify(_:)` and its
/// `read(files:projectRoot:into:)` helper stay CLI-side permanently, per
/// this plan's own §0 module-boundary finding.
public enum HybridExecutionEngine {
    /// The `.adapterNotSchemataCapable` half of the former, two-case
    /// `SchemataRunOrchestration.OrchestrationError` (plan §3 Step 2):
    /// thrown by the schemata-capability guard at the top of what is today
    /// still `SchemataRunOrchestration.run` and becomes `runHybrid` in
    /// Step 4. The other former case, `.sourceReadFailed`, stays a
    /// CLI-side `ClassificationError` — see `SchemataRunOrchestration
    /// .ClassificationError`'s own doc comment for why the split follows
    /// the module boundary, not just a cosmetic reshuffle.
    public enum EngineError: Error, CustomStringConvertible {
        case adapterNotSchemataCapable

        public var description: String {
            switch self {
            case .adapterNotSchemataCapable:
                "the resolved project adapter does not support schemata execution (SwiftPM only in this release)"
            }
        }
    }

    /// Everything about a hybrid run that stays constant across both the
    /// schemata and isolated-fallback portions — bundled so each private
    /// helper below takes one thing plus whatever is genuinely specific to
    /// its own step, rather than re-threading the same six values through
    /// every function's own parameter list. `public`: constructed in
    /// `RunCommand.swift`, a different module, moved verbatim from
    /// `SchemataRunOrchestration.Context` (plan §3 Step 2).
    public struct Context {
        public let plan: MutationPlan
        public let configuration: Configuration
        public let projectRoot: URL
        public let adapter: any ProjectAdapter
        public let testAdapter: any TestAdapter
        public let toolchain: ToolchainFingerprint
        /// The *same* cache instance and key `RunCommand` hands isolated
        /// mode through `IsolatedRunOptions` — one cache, one digest, both
        /// backends. Per-test coverage attribution depends on the source
        /// tree, tests and toolchain, not on which backend measured it, so a
        /// schemata run and an isolated run of the same unchanged project
        /// legitimately share the entry rather than each paying for the
        /// profiling pass separately.
        public let coverageCache: CoverageProfileCache
        /// `nil` when the CLI's digest computation failed — best-effort, the
        /// same degradation isolated mode already accepts: coverage is
        /// re-measured, the run still succeeds.
        public let coverageCacheKey: CoverageProfileCache.Key?

        public init(
            plan: MutationPlan, configuration: Configuration, projectRoot: URL, adapter: any ProjectAdapter,
            testAdapter: any TestAdapter, toolchain: ToolchainFingerprint, coverageCache: CoverageProfileCache,
            coverageCacheKey: CoverageProfileCache.Key?
        ) {
            self.plan = plan
            self.configuration = configuration
            self.projectRoot = projectRoot
            self.adapter = adapter
            self.testAdapter = testAdapter
            self.toolchain = toolchain
            self.coverageCache = coverageCache
            self.coverageCacheKey = coverageCacheKey
        }
    }

    /// How many of the plan's mutations each backend actually accounted for,
    /// and why the planner sent the ones it did to the fallback — the three
    /// values `merge` turns into `ExecutionStrategyReport`, grouped so that
    /// adding the shared baseline's own issues to `merge` did not push it
    /// past the parameter count this repo lints for. Moved verbatim from
    /// `SchemataRunOrchestration.PortionCounts` (plan §3 Step 2).
    ///
    /// Narrowed from Step 2's deliberately-temporary `public` back to
    /// `internal` now (plan §3 Step 4): `merge`/`run` (renamed `runHybrid`
    /// below) — this type's only two call/construction sites — have now
    /// moved into this same module, so the Step 2 CLI-side access bridge is
    /// no longer needed. This is the plan's own literal final shape for
    /// this type ("a `MutationExecution`-internal detail of merge, moved
    /// but not exposed"), reached in the step the plan's own ordering
    /// requires. Access-level-only change, same as Step 2's widening: no
    /// behavior differs.
    struct PortionCounts {
        let embedded: Int
        let fallback: Int
        let plannerFallbackReasonCounts: [String: Int]
    }

    /// What `SchemataRunOrchestration.classify(_:)` determined about a
    /// plan: which programs were actually lowered, which `MutationID`s
    /// they cover, and the pristine pre-lowering source content
    /// `SchemataMutationRunner` needs for honest source-level evidence.
    /// Moved verbatim from the private `SchemataRunOrchestration
    /// .Classification`, renamed `SchemataClassification` and made
    /// `public` (plan §3 Step 3): it now crosses the `CLI` ->
    /// `MutationExecution` boundary the *other* direction from `Context` —
    /// produced by `classify(_:)`, which stays CLI-side per this plan's §0
    /// module-boundary finding, and consumed by the engine (`runHybrid`,
    /// from plan Step 4 onward). Every field type is already
    /// `MutationExecution`-reachable: `SchemataProgram` (`SwiftFrontend`),
    /// `MutationID`/`SchemataUnsupportedReason` (`MutationModel`).
    public struct SchemataClassification {
        public let programs: [SchemataProgram]
        public let embeddedIDs: Set<MutationID>
        public let sources: [String: Data]
        /// Gate 3 Phase H19: every non-embedded entry's own
        /// `SchemataPlanEntry.fallbackReason` — already computed by
        /// `SchemataChunkPlanner.plan`/each lowerer's own
        /// `analyze(_:source:)`, previously read only for `embeddedIDs`
        /// membership and discarded otherwise. Every `MutationID` not in
        /// `embeddedIDs` has an entry here (a plan's own completeness
        /// guarantee — `SchemataPlan.decodeAndValidate` requires exactly
        /// one entry per input mutation).
        public let plannerFallbackReasons: [MutationID: SchemataUnsupportedReason]

        public init(
            programs: [SchemataProgram], embeddedIDs: Set<MutationID>, sources: [String: Data],
            plannerFallbackReasons: [MutationID: SchemataUnsupportedReason]
        ) {
            self.programs = programs
            self.embeddedIDs = embeddedIDs
            self.sources = sources
            self.plannerFallbackReasons = plannerFallbackReasons
        }
    }

    /// `runSchemataPortion`'s outcome, distinguishing "nothing was
    /// embeddable" from "the schemata baseline genuinely failed" — folding
    /// both into the same case would let `merge`'s `baselinePassed`
    /// treat a real baseline failure as "not applicable, assume passed"
    /// and skip the `IntegrityChecker` `baselineMismatch` violation that
    /// failure is supposed to trigger.
    public enum SchemataPortionResult {
        case notApplicable
        case succeeded(SchemataMutationRunner.Outcome)
        /// `record` is the failed baseline as the runner observed it, so
        /// `merge` can attach the real one instead of a zeroed stand-in —
        /// see `RunError.baselineDidNotPass`'s own doc comment.
        case baselineFailed(record: BaselineRecord, diagnosis: String)
    }

    // MARK: - Step 4: establishSharedBaseline, runSchemataPortion,

    // runFallbackPortion, merge, and run()'s own body (now `runHybrid`) —
    // moved verbatim from `SchemataRunOrchestration`, kept as one step per
    // the plan's own reasoning (they already call each other and share
    // `PortionCounts`/`SchemataPortionResult`, moved in Steps 1-2).

    /// Establishes the one baseline both passes below share — see
    /// `SharedBaselineEstablisher`'s own doc comment. Never throws: a
    /// sandbox-creation failure here becomes `.failed(...)`, the same
    /// fail-closed shape `SharedBaselineEstablisher.establish` itself
    /// already returns for a build/test failure, so every caller has
    /// exactly one shape to handle regardless of which step failed.
    private static func establishSharedBaseline(
        _ context: Context, workspaces: WorkspaceManager, operationalIssues: OperationalIssueLog
    ) async -> SharedBaselineEstablisher.Outcome {
        let started = Date()
        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: "shared-baseline")
        } catch {
            return .failed(
                record: BaselineRecord(
                    passed: false, testSummary: nil, durationSeconds: Date().timeIntervalSince(started),
                    buildProductHash: nil, buildCommand: nil, testCommand: nil
                ),
                diagnosis: "The shared baseline sandbox could not be created: \(error)"
            )
        }
        let outcome = await SharedBaselineEstablisher.establish(
            build: context.adapter.build, test: context.testAdapter, in: sandbox,
            configuration: context.configuration, projectRoot: context.projectRoot,
            coverageCache: context.coverageCache, coverageCacheKey: context.coverageCacheKey,
            operationalIssues: operationalIssues
        )
        try? await workspaces.destroySandbox(at: sandbox)
        return outcome
    }

    /// The schemata-specific inputs `runSchemataPortion` needs beyond
    /// `Context` — bundled so that function stays within SwiftLint's
    /// parameter-count threshold.
    private struct SchemataPortionInputs {
        let programs: [SchemataProgram]
        let embeddedIDs: Set<MutationID>
        let sources: [String: Data]
        let build: any SchemataBuildable
        let test: any SchemataTestable
        let policy: MutationVerdictVerifier.VerdictVerificationPolicy
        let sharedBaseline: SharedBaselineEstablisher.Outcome
    }

    private static func runSchemataPortion(
        _ context: Context, inputs: SchemataPortionInputs, workspaces: WorkspaceManager
    ) async throws -> SchemataPortionResult {
        guard !inputs.programs.isEmpty else { return .notApplicable }
        let points = Dictionary(
            uniqueKeysWithValues: context.plan.mutations.filter { inputs.embeddedIDs.contains($0.id) }.map { ($0.id, $0) }
        )
        let runner = SchemataMutationRunner(
            planID: context.plan.planID, workUnitID: context.plan.planID,
            programs: inputs.programs, points: points, originalSources: inputs.sources,
            build: inputs.build, test: inputs.test, workspaces: workspaces,
            // Both limits, from the same configuration isolated mode reads
            // — never one pre-resolved number standing in for both (see
            // `SchemataMutationRunner.timeouts`).
            timeouts: context.configuration.timeouts,
            toolchainHash: toolchainHash(context.toolchain), buildArgumentsHash: context.configuration.buildIdentityHash,
            policy: inputs.policy,
            selectCoveringTests: context.configuration.execution.selectCoveringTests,
            // Same bound isolated mode's own worker pool already resolves
            // and reads `execution.workers` through
            // (`MutationRunner.evaluate`) — schemata chunks are as
            // independent of one another as isolated-mode mutants are (own
            // sandbox, own build), so the same convention applies unchanged.
            workers: context.configuration.execution.resolvedWorkerCount(),
            // The same cache isolated mode already gets — so the second run
            // of an unchanged project skips schemata mode's profiling pass
            // too, instead of re-measuring the most expensive part of the
            // baseline on every single run.
            coverageCache: context.coverageCache,
            coverageCacheKey: context.coverageCacheKey,
            // `inputs.sharedBaseline` (see `runHybrid`) means this pass
            // never builds or tests the unmutated project itself either —
            // see `SharedBaselineEstablisher`'s own doc comment for why.
            preEstablishedBaseline: inputs.sharedBaseline,
            // Gate 3 Phase H5: the same `execution.testBatchSize` isolated
            // mode's own batching already reads (`MutationRunner
            // .testOneBatch`/`testWaveChunk`, Phase H3), not a separate
            // schemata-specific setting — `nil`/unset resolves to `1`
            // (batching disabled), the identical "no value configured, no
            // batching" fallback isolated mode uses at its own call site.
            schemataTokenBatchSize: context.configuration.execution.testBatchSize ?? 1,
            // The same live progress isolated mode has had. Without it a
            // schemata run is silent from the baseline until the final
            // report, which on a real project is hours — and "is it stuck or
            // just slow" then has no answer short of looking for the
            // backend's child processes in `ps`.
            progress: ProgressReporter(total: inputs.programs.count, label: "schemata chunks")
        )
        do {
            let outcome = try await runner.run()
            // ADR-0008 Addendum 4's fan-out/observability requirement, wired
            // through to a human watching the run live. The same events also
            // reach `RunReport.operationalIssues` in `merge` below (for a
            // reader of `report.json` afterward) — the identical
            // stderr-plus-report treatment `MutationRunner` already gives a
            // failed checkpoint write, for the same reason: a systemic,
            // many-mutant event that is invisible in both places is one
            // nobody ever learns about.
            for issue in sharedChunkBuildFailureIssues(outcome.sharedChunkBuildFailureEvents)
                + schemataInfrastructureFallbackIssues(outcome.infrastructureFallbackEvents) {
                print("! \(issue.diagnosis)")
            }
            return .succeeded(outcome)
        } catch let error as SchemataMutationRunner.RunError {
            // Mirrors `MutationRunner`'s own fail-closed convention (a failed
            // baseline never throws, it returns a report whose integrity
            // fails on `baselineMismatch`) — `merge` below applies the same
            // discipline once both portions are back, using `.baselineFailed`
            // to mean "the schemata baseline did not pass" rather than
            // aborting the whole run before the fallback portion even runs.
            let diagnosis = "\(error)"
            print("! Schemata baseline did not pass (\(diagnosis)); embedded mutants cannot be scored this run.")
            switch error {
            case let .baselineDidNotPass(record, _):
                return .baselineFailed(record: record, diagnosis: diagnosis)
            }
        }
    }

    /// **Preservation point (plan §2.1)**: deliberately not factored into
    /// one shared private helper with the `.isolated`-branch
    /// `MutationRunner` construction (Step 5) — this fallback portion gets
    /// none of `checkpoints`/`artifactsRoot`/`resultCache`/
    /// `resultCacheDigest`/`priorityStore`, only its own `progress`
    /// totalled on the fallback plan, not the whole plan. A hybrid run's
    /// fallback portion has never supported resume/result-cache/early-abort,
    /// and unifying the two constructions would make it one edit away from
    /// silently changing that.
    private static func runFallbackPortion(
        _ context: Context, fallbackIDs: Set<MutationID>, workspaces: WorkspaceManager,
        sharedBaseline: SharedBaselineEstablisher.Outcome
    ) async throws -> RunReport? {
        guard !fallbackIDs.isEmpty else { return nil }
        let plan = context.plan
        let fallbackPlan = MutationPlan(
            planID: plan.planID, createdAt: plan.createdAt, projectRoot: plan.projectRoot, toolchain: plan.toolchain,
            configurationHash: plan.configurationHash, sourceFileHashes: plan.sourceFileHashes,
            mutations: plan.mutations.filter { fallbackIDs.contains($0.id) }, skipped: plan.skipped,
            operators: plan.operators, planningHash: plan.planningHash
        )
        return try await MutationRunner(
            plan: fallbackPlan, configuration: context.configuration, projectRoot: context.projectRoot,
            build: context.adapter.build, test: context.testAdapter, workspaces: workspaces, toolchain: context.toolchain,
            // The same cache/key the schemata portion above already measures
            // into (see `Context.coverageCache`'s own doc comment): per-test
            // coverage attribution depends on the source tree, tests and
            // toolchain, never on which backend measured it, so this
            // isolated-fallback baseline must not pay to re-measure it from
            // scratch when the schemata baseline already has.
            coverageCache: context.coverageCache, coverageCacheKey: context.coverageCacheKey,
            // Totalled on the fallback plan, not the whole plan: only the
            // mutations that actually fell back run here, so the plan's own
            // count would leave the counter stalling permanently short of
            // completion — which reads exactly like a hung run.
            progress: ProgressReporter(total: fallbackPlan.mutations.count, label: "fallback mutants"),
            // `sharedBaseline` (see `runHybrid`) means this pass never
            // builds or tests the unmutated project itself — see
            // `SharedBaselineEstablisher`'s own doc comment for why.
            preEstablishedBaseline: sharedBaseline
        ).run()
    }

    /// One report from two passes that now share a single baseline (see
    /// `runHybrid`'s own `sharedBaseline` — previously each built and tested
    /// the unmutated project separately, ADR-0006's accepted v1
    /// inefficiency; Gate 3 measured that at ~9.5% of total wall on a real
    /// iOS project, so it is shared now, not duplicated). Only one
    /// `BaselineRecord` can go in the final report regardless — both
    /// passes' records are the *same* record by construction today, not
    /// independently-measured ones that happen to agree. A genuine shared-
    /// baseline failure is surfaced twice:
    /// `baselinePassed` is unconditionally `false` (so `IntegrityChecker`
    /// raises its real `baselineMismatch` violation, rather than only
    /// failing incidentally on orphaned embedded mutants), and the
    /// attached `BaselineRecord` itself is the failed one whenever it
    /// exists — a human reading the report must never see a passing
    /// `BaselineRecord` next to a failed integrity check with no visible
    /// cause. Only when the schemata portion did not fail (not applicable,
    /// or genuinely passed) does the isolated pass's baseline take
    /// priority — it is the one shape every existing reporter already
    /// knows how to render, and is the more informative of two genuinely-
    /// passing runs.
    private static func merge(
        _ context: Context, startedAt: Date, schemataPortion: SchemataPortionResult,
        fallbackReport: RunReport?, counts: PortionCounts, baselineIssues: [OperationalIssue]
    ) -> RunReport {
        let (embeddedCount, fallbackCount) = (counts.embedded, counts.fallback)
        let plannerFallbackReasonCounts = counts.plannerFallbackReasonCounts
        let schemataOutcome: SchemataMutationRunner.Outcome? = if case let .succeeded(outcome) = schemataPortion { outcome } else { nil }

        var ledger = ResultLedger<MutationResult>()
        for result in (schemataOutcome?.results ?? []) + (fallbackReport?.results ?? []) {
            try? ledger.insert(result)
        }

        let resolved = resolveBaseline(
            schemataPortion, schemataBaseline: schemataOutcome?.baseline, fallbackBaseline: fallbackReport?.baseline,
            embeddedCount: embeddedCount, fallbackCount: fallbackCount
        )
        let (baselinePassed, baseline, degradationReason) = (resolved.passed, resolved.record, resolved.degradationReason)
        let integrity = IntegrityChecker.check(plan: context.plan, ledger: ledger, baselinePassed: baselinePassed)
        let executionStrategy = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: embeddedCount, fallbackCount: fallbackCount, degradationReason: degradationReason,
            fallbackReasonCounts: schemataOutcome.map { fallbackReasonCounts($0.isolatedFallbacks) },
            // Same nil-vs-empty gating as `fallbackReasonCounts` above,
            // deliberately: `schemataOutcome` is non-nil only when
            // `embeddedIDs` was genuinely non-empty, which is exactly when
            // classification ran for real and `plannerFallbackReasonCounts`
            // reflects meaningful data (even a genuine, meaningful zero) —
            // not the fully-degraded case, where nothing was ever classified.
            plannerFallbackReasonCounts: schemataOutcome.map { _ in plannerFallbackReasonCounts }
        )

        return RunReport(
            planID: context.plan.planID, startedAt: startedAt, finishedAt: Date(), projectRoot: context.projectRoot.path,
            toolchain: context.toolchain, baseline: baseline, ledger: ledger, integrity: integrity,
            executionStrategy: executionStrategy,
            // The one shared baseline's own issues first of all — it is the
            // most run-level event there is, established once before either
            // portion existed, and nothing below it would carry the fact:
            // neither portion establishes its own baseline, so neither
            // portion's issue log ever sees it. Then the schemata portion's
            // own issues, then the isolated pass's — a shared-chunk build
            // failure is a run-level, many-mutant event, and it must not be
            // buried under whatever per-mutation issues the fallback pass it
            // caused went on to produce.
            operationalIssues: baselineIssues
                + sharedChunkBuildFailureIssues(schemataOutcome?.sharedChunkBuildFailureEvents ?? [])
                + schemataInfrastructureFallbackIssues(schemataOutcome?.infrastructureFallbackEvents ?? [])
                + (fallbackReport?.operationalIssues ?? [])
        )
    }

    /// The engine's own "one run" unit (plan §1.3/§6.3): one call per
    /// `mutantkit run --strategy schemata` invocation owns one shared
    /// baseline, one `RunReport`, and the isolated-vs-schemata routing —
    /// but explicitly does **not** unify the two runners' own `RunSession`s
    /// (`MutationRunner` and `SchemataMutationRunner` each still build
    /// their own internally, per Step 1's own §4.6 finding). Moved
    /// verbatim from `SchemataRunOrchestration.run`'s body (plan §3 Step 4)
    /// — the only substantive change is that `classification` and
    /// `startedAt` now arrive as parameters instead of being computed
    /// inline (an inline `classify(context)` call, and `Date()` right
    /// after this function's own capability guard): `classify(_:)` itself
    /// is untouched and stays CLI-side per this plan's §0 module-boundary
    /// finding, and `startedAt` must be captured before `classify(_:)`
    /// runs, at the caller, for the CLI-side capability guard and
    /// `startedAt`'s capture point to stay in their original relative
    /// order (see `RunCommand.execute`'s `.schemata` case, which now
    /// performs both before calling `classify(_:)`, exactly like
    /// `SchemataRunOrchestration.run`'s own former body did). Its own
    /// `GateTimingRecorder` "classify" span moved with the call, into
    /// `RunCommand.execute` — kept wrapped around the real work it
    /// measures, rather than left here where it would sit around a value
    /// already computed by the time this function receives it and so
    /// record ~zero elapsed time. A pure "the span moves with its call
    /// site" preservation, not a timing behavior change.
    ///
    /// **Preserved exactly (plan §2.2)**: `establishSharedBaseline` is
    /// called with `workspaces: workspaces` — the isolated/fallback
    /// manager — never `schemataWorkspaces`, even though the schemata
    /// portion runs first. Existing, observable behavior (the shared
    /// baseline sandbox's scratch-root parent), copied unchanged.
    ///
    /// The capability guard below is now the second check of the same
    /// fact — `RunCommand.execute` already verified it, before ever
    /// calling `classify(_:)`, so `startedAt`'s caller-side capture point
    /// is provably reachable only on a schemata-capable adapter. Kept here
    /// too (never expected to fail) so this function stays correct on its
    /// own if a future caller ever invokes it without that pre-check.
    public static func runHybrid(
        context: Context, classification: SchemataClassification,
        workspaces: WorkspaceManager, schemataWorkspaces: WorkspaceManager, startedAt: Date
    ) async throws -> RunReport {
        guard let schemataBuild = context.adapter.schemataBuild,
              let schemataTest = context.testAdapter as? SchemataTestable
        else {
            throw EngineError.adapterNotSchemataCapable
        }

        // The one source of truth both backends' confirmation gates are
        // asked against (`MutationVerdictVerifier.confirmationRequirement`)
        // — never a policy this orchestration re-derives independently of
        // what isolated mode itself would use for the identical
        // configuration.
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(context.configuration.execution)

        // One baseline, established here and shared by both passes below —
        // see `SharedBaselineEstablisher`'s own doc comment. Previously
        // each pass built and tested the unmutated project separately (an
        // accepted v1 inefficiency, ADR-0006); measured at Gate 3 to cost
        // ~104s (~9.5% of total wall) on a real iOS project. Established
        // before either pass runs — a fully-fallback run still needs
        // exactly the cost it always paid (one baseline), and a fully-
        // embeddable run likewise, so there is no case where this is
        // wasted relative to before.
        let sharedBaselineStart = GateTimingRecorder.shared.now()
        // Neither portion establishes this baseline, so neither portion's
        // own issue log can record what establishing it observed. This one
        // is handed to the establisher and merged into the final report
        // below.
        let baselineIssues = OperationalIssueLog()
        let sharedBaseline = await establishSharedBaseline(context, workspaces: workspaces, operationalIssues: baselineIssues)
        await GateTimingRecorder.shared.record("sharedBaseline.total", start: sharedBaselineStart)

        let schemataPortionStart = GateTimingRecorder.shared.now()
        let schemataPortion = try await runSchemataPortion(
            context, inputs: SchemataPortionInputs(
                programs: classification.programs, embeddedIDs: classification.embeddedIDs, sources: classification.sources,
                build: schemataBuild, test: schemataTest, policy: policy, sharedBaseline: sharedBaseline
            ),
            workspaces: schemataWorkspaces
        )
        await GateTimingRecorder.shared.record("schemata.portion.total", start: schemataPortionStart)

        // A mutation `SchemataChunkPlanner` embedded can still end up here:
        // `SchemataMutationRunner` itself may have found no runtime
        // activation proof for a passing test (`Outcome.isolatedFallbacks`
        // — Group 2, ADR-0006's no-HIT/no-STARTUP routing) and dropped it
        // from its own `results` entirely. Union'd into the *same*
        // `fallbackIDs` set the planner-time gap already uses, so both
        // reasons a mutation needs isolated mode converge on one fallback
        // portion, never two separate isolated runs for the same
        // MutationID.
        let dynamicFallbackIDs: Set<MutationID> = if case let .succeeded(outcome) = schemataPortion {
            Set(outcome.isolatedFallbacks.map(\.mutationID))
        } else {
            []
        }
        let fallbackIDs = Set(context.plan.mutations.map(\.id)).subtracting(classification.embeddedIDs).union(dynamicFallbackIDs)
        let fallbackPortionStart = GateTimingRecorder.shared.now()
        let fallbackReport = try await runFallbackPortion(
            context, fallbackIDs: fallbackIDs, workspaces: workspaces, sharedBaseline: sharedBaseline
        )
        await GateTimingRecorder.shared.record("fallback.portion.total", start: fallbackPortionStart)

        let mergeStart = GateTimingRecorder.shared.now()
        let report = merge(
            context, startedAt: startedAt, schemataPortion: schemataPortion, fallbackReport: fallbackReport,
            counts: PortionCounts(
                // Effective counts, not planner-time ones (ADR-0006 Group 2):
                // a mutation counted among `classification.embeddedIDs` that
                // then dynamically fell back is no longer schemata-scored, so
                // it must not still be counted in `effectiveCount` — it is
                // already folded into `fallbackIDs.count` above instead.
                embedded: classification.embeddedIDs.count - dynamicFallbackIDs.count, fallback: fallbackIDs.count,
                // Gate 3 Phase H19: `classification.plannerFallbackReasons`'
                // keys are already exactly the planner-time fallback set (every
                // `MutationID` not in `embeddedIDs`) — never overlaps
                // `dynamicFallbackIDs`, so no further filtering is needed here.
                plannerFallbackReasonCounts: plannerFallbackReasonCounts(
                    Array(classification.plannerFallbackReasons.values)
                )
            ),
            baselineIssues: await baselineIssues.snapshot()
        )
        await GateTimingRecorder.shared.record("merge", start: mergeStart)
        return report
    }

    // MARK: - Step 5: IsolatedRunOptions, runIsolated — moved verbatim from

    // `RunCommand+ExecutionContext.swift`/`RunCommand.swift`'s own
    // `.isolated` branch.

    /// The isolated-mode-only pieces `runIsolated` threads into
    /// `MutationRunner` — none of these participate in schemata mode v1 (no
    /// checkpoint, coverage cache, or cross-run result cache; schemata mode
    /// does not yet support them). Moved verbatim from
    /// `RunCommand+ExecutionContext.swift`'s own `IsolatedRunOptions` (plan
    /// §3 Step 5), made `public`: constructed in `RunCommand.swift`, a
    /// different module.
    public struct IsolatedRunOptions {
        public let checkpoints: CheckpointStore
        public let artifactsRoot: URL
        public let coverageCache: CoverageProfileCache
        public let coverageCacheKey: CoverageProfileCache.Key?
        public let resultCache: MutationResultCache?
        public let resultCacheDigest: String?
        public let priorityStore: TestPriorityStore?
        public let progress: ProgressReporter?

        public init(
            checkpoints: CheckpointStore, artifactsRoot: URL, coverageCache: CoverageProfileCache,
            coverageCacheKey: CoverageProfileCache.Key?, resultCache: MutationResultCache?, resultCacheDigest: String?,
            priorityStore: TestPriorityStore?, progress: ProgressReporter?
        ) {
            self.checkpoints = checkpoints
            self.artifactsRoot = artifactsRoot
            self.coverageCache = coverageCache
            self.coverageCacheKey = coverageCacheKey
            self.resultCache = resultCache
            self.resultCacheDigest = resultCacheDigest
            self.priorityStore = priorityStore
            self.progress = progress
        }
    }

    /// Moved verbatim from `RunCommand.execute`'s own `.isolated` case (plan
    /// §3 Step 5) — the existing, unmodified `MutationRunner`'s construction
    /// and `run()` call, parameter-for-parameter unchanged. `MutationRunner
    /// .swift` itself is not opened for editing by this step, only where the
    /// call to it textually lives.
    public static func runIsolated(
        context: Context, workspaces: WorkspaceManager, options: IsolatedRunOptions
    ) async throws -> RunReport {
        try await MutationRunner(
            plan: context.plan,
            configuration: context.configuration,
            projectRoot: context.projectRoot,
            build: context.adapter.build,
            test: context.testAdapter,
            workspaces: workspaces,
            checkpoints: options.checkpoints,
            artifactsRoot: options.artifactsRoot,
            toolchain: context.toolchain,
            coverageCache: options.coverageCache,
            coverageCacheKey: options.coverageCacheKey,
            resultCache: options.resultCache,
            resultCacheDigest: options.resultCacheDigest,
            priorityStore: options.priorityStore,
            progress: options.progress
        ).run()
    }
}

/// The Step 1 "pure, already-directly-tested helpers" group, split into
/// its own extension (same file, same type) purely to keep the primary
/// enum body under this project's swiftlint type_body_length threshold as
/// the type grew through later steps -- no access-level or behavior change,
/// Swift resolves 'private' across same-file extensions of the same type
/// identically to within the primary declaration.
public extension HybridExecutionEngine {
    /// Which baseline the merged report carries, and whether the run has to
    /// declare itself degraded — the one decision in `merge` that a wrong
    /// answer makes invisible rather than loud, so it is separated out and
    /// tested directly (`SchemataDegradedBaselineTests`). Pure: `merge`'s
    /// other inputs (the plan, the ledger, the adapters) cannot change it.
    struct BaselineResolution {
        public let passed: Bool
        public let record: BaselineRecord
        public let degradationReason: String?
    }

    /// An all-`nil` record is a statement that nothing about the baseline is
    /// known — used only where that is genuinely true, never in place of a
    /// record that exists.
    private static var unknownBaseline: BaselineRecord {
        BaselineRecord(
            passed: false, testSummary: nil, durationSeconds: 0, buildProductHash: nil, buildCommand: nil, testCommand: nil
        )
    }

    /// Takes the two candidate records rather than the reports they came
    /// from: those are all this decision reads, and naming them directly is
    /// what keeps it a pure function of its inputs.
    static func resolveBaseline(
        _ schemataPortion: SchemataPortionResult, schemataBaseline: BaselineRecord?,
        fallbackBaseline: BaselineRecord?, embeddedCount: Int, fallbackCount: Int
    ) -> BaselineResolution {
        switch schemataPortion {
        case let .baselineFailed(record, diagnosis):
            // The baseline the schemata portion actually observed, not a
            // zeroed stand-in for it: this case is precisely the "genuine
            // shared-baseline failure" `merge`'s doc comment promises
            // attaches the failed record, and a synthesized all-`nil` one
            // told a reader nothing about whether the project even built.
            BaselineResolution(
                passed: false, record: record,
                degradationReason: "the schemata baseline did not pass: \(diagnosis)"
            )
        case .notApplicable:
            BaselineResolution(
                passed: fallbackBaseline?.passed ?? true,
                record: fallbackBaseline ?? unknownBaseline,
                degradationReason: embeddedCount == 0 && fallbackCount > 0
                    ? "no mutation in this plan was embeddable under the currently registered schemata lowerers"
                    : nil
            )
        case .succeeded:
            BaselineResolution(
                passed: (schemataBaseline?.passed ?? true) && (fallbackBaseline?.passed ?? true),
                record: fallbackBaseline ?? schemataBaseline ?? unknownBaseline,
                degradationReason: nil
            )
        }
    }

    /// ADR-0008 Addendum 4's required aggregate report: one issue per chunk
    /// whose shared lowered program failed to compile, carrying the
    /// `MutationID` count it cost and the chunk-level compiler diagnostic
    /// that caused it — never one issue per affected `MutationID`, which is
    /// exactly the "many individually-unremarkable fallbacks with no shared
    /// cause visible" shape the addendum forbids.
    ///
    /// `.warning`, not `.error`: every affected mutation still gets a real,
    /// verified verdict from the isolated fallback pass, so neither score
    /// nor integrity is in question — what is lost is schemata's fast path,
    /// which is a cost/health fact, and `operationalIssues` is where this
    /// codebase already puts exactly that (see `OperationalIssue`'s own doc
    /// comment). `mutationID` is `nil` because the event genuinely is
    /// chunk-level: attributing it to any one of the mutations it took down
    /// would misstate what failed.
    static func sharedChunkBuildFailureIssues(
        _ events: [SchemataMutationRunner.SharedChunkBuildFailureEvent]
    ) -> [OperationalIssue] {
        events.map { event in
            OperationalIssue(
                severity: .warning, kind: .schemataChunkBuildFailed, mutationID: nil,
                diagnosis: """
                Schemata chunk \(event.chunkID) failed to build (\(event.diagnosticReference)); \
                \(event.affectedMutationCount) \(event.affectedMutationCount == 1 ? "mutant" : "mutants") \
                forfeited schemata execution and ran in isolated mode instead.
                """
            )
        }
    }

    /// The identical fan-out/observability treatment as
    /// `sharedChunkBuildFailureIssues` above, for a chunk whose own shared
    /// build succeeded but whose build receipt could not be resolved
    /// (`SchemataFallbackReason.buildReceiptUnavailable`) — a structurally
    /// different event (the build itself did not fail), so it gets its own
    /// `OperationalIssue.Kind` rather than being folded into
    /// `schemataChunkBuildFailed`, which would misstate what happened.
    static func schemataInfrastructureFallbackIssues(
        _ events: [SchemataMutationRunner.SchemataInfrastructureFallbackEvent]
    ) -> [OperationalIssue] {
        events.map { event in
            OperationalIssue(
                severity: .warning, kind: .schemataChunkReceiptUnavailable, mutationID: nil,
                diagnosis: """
                Schemata chunk \(event.chunkID) built successfully but its build receipt could not be \
                resolved (\(event.diagnosis)); \(event.affectedMutationCount) \
                \(event.affectedMutationCount == 1 ? "mutant" : "mutants") \
                forfeited schemata execution and ran in isolated mode instead.
                """
            )
        }
    }

    /// A count histogram of every *dynamic* fallback reason the schemata
    /// backend reported, for `ExecutionStrategyReport.fallbackReasonCounts`.
    /// Keys are stable, machine-greppable strings derived from
    /// `SchemataMutationRunner.SchemataFallbackReason`'s own cases (and, for
    /// `.activation`, from the verifier's own raw reason value) — never a
    /// `String(describing:)` of an enum, whose text is not a stable contract.
    static func fallbackReasonCounts(_ fallbacks: [SchemataMutationRunner.DynamicFallback]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for fallback in fallbacks {
            let key = switch fallback.reason {
            case let .activation(reason): "activation.\(reason.rawValue)"
            case .hangBudgetExceeded: "hangBudgetExceeded"
            case .sharedChunkBuildFailure: "sharedChunkBuildFailure"
            case .knownUncovered: "knownUncovered"
            case .buildReceiptUnavailable: "buildReceiptUnavailable"
            }
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Gate 3 Phase H19: the *planner-time* counterpart to
    /// `fallbackReasonCounts` above, for
    /// `ExecutionStrategyReport.plannerFallbackReasonCounts` — a candidate a
    /// lowerer's own `analyze(_:source:)` (or `SchemataChunkPlanner.plan`,
    /// for a conflict it could not resolve) never embedded at all, before
    /// any token was ever attempted. Same stable-string-key discipline as
    /// `fallbackReasonCounts`: the case name alone for a free-form
    /// diagnostic payload (`structuralConflict`/`unsupportedOperand`/
    /// `platformUnsupported` all carry a `reason: String` that is a
    /// human-readable diagnosis, not a stable identifier, so it is
    /// deliberately dropped from the key); the operator ID *is* a stable
    /// identifier, so `operatorNotYetLowered` keeps its own as a suffix,
    /// the same way `fallbackReasonCounts` keeps `activation`'s.
    static func plannerFallbackReasonCounts(_ reasons: [SchemataUnsupportedReason]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for reason in reasons {
            let key = switch reason {
            case .resultBuilderBody: "resultBuilderBody"
            case .typeVarianceUnproven: "typeVarianceUnproven"
            case .processStartRequired: "processStartRequired"
            case let .operatorNotYetLowered(operatorID): "operatorNotYetLowered.\(operatorID)"
            case .structuralConflict: "structuralConflict"
            case .platformUnsupported: "platformUnsupported"
            case .unsupportedOperand: "unsupportedOperand"
            case .asyncOrThrowingExpression: "asyncOrThrowingExpression"
            case .ownershipSensitiveExpression: "ownershipSensitiveExpression"
            case .patternPosition: "patternPosition"
            case .controlFlowConstant: "controlFlowConstant"
            }
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Promoted to `public` because both the still-CLI-side `classify(_:)`
    /// and the now-engine-side schemata-portion machinery (moved in a later
    /// plan step) need to call the identical derivation; a second,
    /// duplicated copy would reopen exactly the kind of "one fact computed
    /// twice" duplication this extraction effort exists to remove.
    static func toolchainHash(_ toolchain: ToolchainFingerprint) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(toolchain) else { return "unknown-toolchain" }
        return ContentHash.of(data)
    }
}
