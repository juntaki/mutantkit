import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend

/// Combines the schemata backend's `SchemataMutationRunner` with the
/// existing, unmodified `MutationRunner` into one `RunReport` (ADR-0006
/// Stage 3) — a schemata run is never 100% embeddable, so anything
/// `SchemataChunkPlanner` routes to isolated fallback (an operator with no
/// registered `SchemataLowerer`, a multi-target conflict, a structural
/// conflict) still needs a real, isolated-mode verdict. Only
/// `BoolLiteralInversionOperator` has a registered lowerer today
/// (`SchemataLowererRegistry.builtIn`) — the one operator this session's
/// real-toolchain differential suites (`SchemataIsolatedDifferentialAcceptanceTests`,
/// `SchemataConfirmationDifferentialAcceptanceTests`, and their Xcode
/// counterparts) actually proved agrees with isolated mode, including under
/// confirmation. The registry itself is the operator gate: an operator
/// with no lowerer can never appear in `embeddedIDs` below, so it always
/// falls to isolated fallback — no separate gate type is needed on top of
/// it.
///
/// CLI-layer wiring only, not a reusable `MutationExecution` engine type:
/// `RunCommand` is the only caller. `MutationRunner.swift` is never edited
/// or called with anything other than its existing public API.
enum SchemataRunOrchestration {
    enum OrchestrationError: Error, CustomStringConvertible {
        case adapterNotSchemataCapable
        case sourceReadFailed(file: String, underlying: String)

        var description: String {
            switch self {
            case .adapterNotSchemataCapable:
                "the resolved project adapter does not support schemata execution (SwiftPM only in this release)"
            case let .sourceReadFailed(file, underlying):
                "could not read \(file) to plan schemata chunks: \(underlying)"
            }
        }
    }

    /// Everything about this run that stays constant across both the
    /// schemata and isolated-fallback portions — bundled so each private
    /// helper below takes one thing plus whatever is genuinely specific to
    /// its own step, rather than re-threading the same six values through
    /// every function's own parameter list.
    struct Context {
        let plan: MutationPlan
        let configuration: Configuration
        let projectRoot: URL
        let adapter: any ProjectAdapter
        let testAdapter: any TestAdapter
        let toolchain: ToolchainFingerprint
        /// The *same* cache instance and key `RunCommand` hands isolated
        /// mode through `IsolatedRunOptions` — one cache, one digest, both
        /// backends. Per-test coverage attribution depends on the source
        /// tree, tests and toolchain, not on which backend measured it, so a
        /// schemata run and an isolated run of the same unchanged project
        /// legitimately share the entry rather than each paying for the
        /// profiling pass separately.
        let coverageCache: CoverageProfileCache
        /// `nil` when the CLI's digest computation failed — best-effort, the
        /// same degradation isolated mode already accepts: coverage is
        /// re-measured, the run still succeeds.
        let coverageCacheKey: CoverageProfileCache.Key?
    }

    /// No `timeoutSeconds` parameter (removed deliberately): a single
    /// caller-supplied limit is what let `RunCommand` hand the *baseline*
    /// limit to every per-mutant schemata spawn. `Context.configuration
    /// .timeouts` already carries both limits, so the runner resolves each
    /// from the same `TimeoutSettings` isolated mode reads — there is no
    /// longer a place for a call site to pass the wrong one.
    static func run(
        context: Context, workspaces: WorkspaceManager, schemataWorkspaces: WorkspaceManager
    ) async throws -> RunReport {
        guard let schemataBuild = context.adapter.build as? SchemataBuildable,
              let schemataTest = context.testAdapter as? SchemataTestable
        else {
            throw OrchestrationError.adapterNotSchemataCapable
        }

        let startedAt = Date()
        let classifyStart = GateTimingRecorder.shared.now()
        let classification = try await classify(context)
        await GateTimingRecorder.shared.record("classify", start: classifyStart)

        // The one source of truth both backends' confirmation gates are
        // asked against (`MutationVerdictVerifier.confirmationRequirement`)
        // — never a policy this orchestration re-derives independently of
        // what isolated mode itself would use for the identical
        // configuration.
        let policy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: context.configuration.execution.retestKilledMutants,
            confirmCrashKills: context.configuration.execution.confirmCrashKills,
            confirmTimedOutMutants: context.configuration.execution.confirmTimedOutMutants
        )

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
        let sharedBaseline = await establishSharedBaseline(context, workspaces: workspaces)
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
            // Effective counts, not planner-time ones (ADR-0006 Group 2):
            // a mutation counted among `classification.embeddedIDs` that
            // then dynamically fell back is no longer schemata-scored, so
            // it must not still be counted in `effectiveCount` — it is
            // already folded into `fallbackIDs.count` above instead.
            embeddedCount: classification.embeddedIDs.count - dynamicFallbackIDs.count, fallbackCount: fallbackIDs.count,
            // Gate 3 Phase H19: `classification.plannerFallbackReasons`'
            // keys are already exactly the planner-time fallback set (every
            // `MutationID` not in `embeddedIDs`) — never overlaps
            // `dynamicFallbackIDs`, so no further filtering is needed here.
            plannerFallbackReasonCounts: Self.plannerFallbackReasonCounts(Array(classification.plannerFallbackReasons.values))
        )
        await GateTimingRecorder.shared.record("merge", start: mergeStart)
        return report
    }

    /// Establishes the one baseline both passes below share — see
    /// `SharedBaselineEstablisher`'s own doc comment. Never throws: a
    /// sandbox-creation failure here becomes `.failed(...)`, the same
    /// fail-closed shape `SharedBaselineEstablisher.establish` itself
    /// already returns for a build/test failure, so every caller has
    /// exactly one shape to handle regardless of which step failed.
    private static func establishSharedBaseline(
        _ context: Context, workspaces: WorkspaceManager
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
            coverageCache: context.coverageCache, coverageCacheKey: context.coverageCacheKey
        )
        try? await workspaces.destroySandbox(at: sandbox)
        return outcome
    }

    /// What `classify` determined about a plan: which programs were
    /// actually lowered, which `MutationID`s they cover, and the pristine
    /// pre-lowering source content `SchemataMutationRunner` needs for
    /// honest source-level evidence.
    private struct Classification {
        let programs: [SchemataProgram]
        let embeddedIDs: Set<MutationID>
        let sources: [String: Data]
        /// Gate 3 Phase H19: every non-embedded entry's own
        /// `SchemataPlanEntry.fallbackReason` — already computed by
        /// `SchemataChunkPlanner.plan`/each lowerer's own
        /// `analyze(_:source:)`, previously read only for `embeddedIDs`
        /// membership and discarded otherwise. Every `MutationID` not in
        /// `embeddedIDs` has an entry here (a plan's own completeness
        /// guarantee — `SchemataPlan.decodeAndValidate` requires exactly
        /// one entry per input mutation).
        let plannerFallbackReasons: [MutationID: SchemataUnsupportedReason]
    }

    /// Resolves target info and plans chunks. Any failure here (target
    /// resolution, chunk planning) degrades to "nothing is embeddable"
    /// rather than aborting the run — an infrastructure hiccup in the
    /// schemata-specific machinery must not prevent isolated mode from
    /// still producing a real result for every mutation, the same
    /// never-regress-isolated-mode discipline this whole effort is built
    /// on. The user explicitly opted into `.schemata`; a degraded-to-fully-
    /// isolated run still honors that better than a hard failure would.
    private static func classify(_ context: Context) async throws -> Classification {
        var sources: [String: Data] = [:]
        try read(files: Set(context.plan.mutations.map(\.file)), projectRoot: context.projectRoot, into: &sources)

        let empty = Classification(programs: [], embeddedIDs: [], sources: sources, plannerFallbackReasons: [:])

        let targetInfo: [String: [SchemataTargetInfo]]
        let backendID: String
        do {
            switch context.adapter.kind {
            case .swiftPackageMacOS, .swiftPackageApple:
                targetInfo = try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: context.projectRoot)
                backendID = "swiftpm-schemata-v1"
            case .xcodeProject:
                targetInfo = try await XcodeTargetResolver.resolveTargetInfo(projectRoot: context.projectRoot)
                backendID = "xcode-schemata-v1"
            case .xcodeWorkspace, .auto:
                // `.xcworkspace` (which can span more than one `.xcodeproj`)
                // and `.auto` (never actually reached here — every
                // `ProjectAdapter` `AppleAdapterFactory.adapter(for:)`
                // constructs already reports a concrete kind, see
                // `SwiftPackageMacOSProjectAdapter.kind`/
                // `XcodeBuildProjectAdapter.kind`) are both explicitly out
                // of scope for schemata target resolution today — same
                // fail-closed-to-isolated degradation as a genuine
                // resolution failure below, just without pretending an
                // attempt was made.
                print("! Schemata target resolution is not yet implemented for \(context.adapter.kind.rawValue); every mutation will run in isolated mode this run.")
                return empty
            }
        } catch {
            print("! Schemata target resolution failed (\(error)); every mutation will run in isolated mode this run.")
            return empty
        }

        // `SchemataChunkPlanner.lower` needs the *whole* target's source —
        // every file `filesByTarget` names, including a file with zero
        // mutation candidates of its own (a plain compiled dependency that
        // happens to sit in the same target as an eligible one) — to build
        // one valid, compilable chunk. Reading only `context.plan.mutations`'
        // own files above is not enough; a target member with no candidate
        // mutation was never read and `SchemataChunkPlanner.plan` fails
        // closed on it (`.missingSource`), degrading a real, otherwise-
        // embeddable target to isolated fallback for no structural reason.
        let targetFiles = Set(targetInfo.keys).subtracting(sources.keys)
        try read(files: targetFiles, projectRoot: context.projectRoot, into: &sources)

        let backend = SchemataBackendInfo(
            backendID: backendID, backendVersion: 1,
            toolchainHash: toolchainHash(context.toolchain), buildArgumentsHash: context.configuration.configurationHash
        )
        do {
            let registry = try SchemataLowererRegistry()
            let result = try SchemataChunkPlanner.plan(
                mutationPlan: context.plan, registry: registry, sources: sources, targetInfo: targetInfo, backend: backend
            )
            let embeddedIDs = Set(result.schemataPlan.entries.filter(\.isEmbedded).map(\.mutationID))
            let plannerFallbackReasons = Dictionary(
                uniqueKeysWithValues: result.schemataPlan.entries.compactMap { entry in
                    entry.fallbackReason.map { (entry.mutationID, $0) }
                }
            )
            return Classification(
                programs: result.programs, embeddedIDs: embeddedIDs, sources: sources,
                plannerFallbackReasons: plannerFallbackReasons
            )
        } catch {
            print("! Schemata chunk planning failed (\(error)); every mutation will run in isolated mode this run.")
            return empty
        }
    }

    /// Reads each of `files` (repository-relative, exactly as recorded on
    /// `MutationPoint.file`/`SwiftPMTargetResolver`'s own keys) as raw bytes
    /// via `URL.appendingPathComponent` — never a shell command, never a
    /// string split on whitespace — so a path containing spaces, Unicode,
    /// or any other character `appendingPathComponent` itself already
    /// handles correctly is read exactly the same as any other path.
    private static func read(files: Set<String>, projectRoot: URL, into sources: inout [String: Data]) throws {
        for file in files {
            do {
                sources[file] = try Data(contentsOf: projectRoot.appendingPathComponent(file))
            } catch {
                throw OrchestrationError.sourceReadFailed(file: file, underlying: "\(error)")
            }
        }
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

    /// `runSchemataPortion`'s outcome, distinguishing "nothing was
    /// embeddable" from "the schemata baseline genuinely failed" — folding
    /// both into the same case would let `merge`'s `baselinePassed`
    /// treat a real baseline failure as "not applicable, assume passed"
    /// and skip the `IntegrityChecker` `baselineMismatch` violation that
    /// failure is supposed to trigger.
    private enum SchemataPortionResult {
        case notApplicable
        case succeeded(SchemataMutationRunner.Outcome)
        case baselineFailed(diagnosis: String)
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
            toolchainHash: toolchainHash(context.toolchain), buildArgumentsHash: context.configuration.configurationHash,
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
            // `inputs.sharedBaseline` (see `run()`) means this pass never
            // builds or tests the unmutated project itself either — see
            // `SharedBaselineEstablisher`'s own doc comment for why.
            preEstablishedBaseline: inputs.sharedBaseline,
            // Gate 3 Phase H5: the same `execution.testBatchSize` isolated
            // mode's own batching already reads (`MutationRunner
            // .testOneBatch`/`testWaveChunk`, Phase H3), not a separate
            // schemata-specific setting — `nil`/unset resolves to `1`
            // (batching disabled), the identical "no value configured, no
            // batching" fallback isolated mode uses at its own call site.
            schemataTokenBatchSize: context.configuration.execution.testBatchSize ?? 1
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
            for issue in sharedChunkBuildFailureIssues(outcome.sharedChunkBuildFailureEvents) {
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
            return .baselineFailed(diagnosis: diagnosis)
        }
    }

    private static func runFallbackPortion(
        _ context: Context, fallbackIDs: Set<MutationID>, workspaces: WorkspaceManager,
        sharedBaseline: SharedBaselineEstablisher.Outcome
    ) async throws -> RunReport? {
        guard !fallbackIDs.isEmpty else { return nil }
        let plan = context.plan
        let fallbackPlan = MutationPlan(
            planID: plan.planID, createdAt: plan.createdAt, projectRoot: plan.projectRoot, toolchain: plan.toolchain,
            configurationHash: plan.configurationHash, sourceFileHashes: plan.sourceFileHashes,
            mutations: plan.mutations.filter { fallbackIDs.contains($0.id) }, skipped: plan.skipped, operators: plan.operators
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
            // `sharedBaseline` (see `run()`) means this pass never builds or
            // tests the unmutated project itself — see
            // `SharedBaselineEstablisher`'s own doc comment for why.
            preEstablishedBaseline: sharedBaseline
        ).run()
    }

    /// One report from two passes that now share a single baseline (see
    /// `run()`'s own `sharedBaseline` — previously each built and tested
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
        _ context: Context, startedAt: Date, schemataPortion: SchemataPortionResult, fallbackReport: RunReport?,
        embeddedCount: Int, fallbackCount: Int, plannerFallbackReasonCounts: [String: Int]
    ) -> RunReport {
        let schemataOutcome: SchemataMutationRunner.Outcome? = if case let .succeeded(outcome) = schemataPortion { outcome } else { nil }

        var ledger = ResultLedger<MutationResult>()
        for result in (schemataOutcome?.results ?? []) + (fallbackReport?.results ?? []) {
            try? ledger.insert(result)
        }

        let baselinePassed: Bool
        let baseline: BaselineRecord
        let degradationReason: String?
        switch schemataPortion {
        case let .baselineFailed(diagnosis):
            baselinePassed = false
            baseline = BaselineRecord(
                passed: false, testSummary: nil, durationSeconds: 0, buildProductHash: nil, buildCommand: nil, testCommand: nil
            )
            degradationReason = "the schemata baseline did not pass: \(diagnosis)"
        case .notApplicable:
            baselinePassed = fallbackReport?.baseline.passed ?? true
            baseline = fallbackReport?.baseline ?? BaselineRecord(
                passed: false, testSummary: nil, durationSeconds: 0, buildProductHash: nil, buildCommand: nil, testCommand: nil
            )
            degradationReason = embeddedCount == 0 && fallbackCount > 0
                ? "no mutation in this plan was embeddable under the currently registered schemata lowerers"
                : nil
        case .succeeded:
            baselinePassed = (schemataOutcome?.baseline.passed ?? true) && (fallbackReport?.baseline.passed ?? true)
            baseline = fallbackReport?.baseline ?? schemataOutcome?.baseline ?? BaselineRecord(
                passed: false, testSummary: nil, durationSeconds: 0, buildProductHash: nil, buildCommand: nil, testCommand: nil
            )
            degradationReason = nil
        }
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
            // The schemata portion's own issues first, then the isolated
            // pass's — a shared-chunk build failure is a run-level, many-
            // mutant event, and it must not be buried under whatever
            // per-mutation issues the fallback pass it caused went on to
            // produce.
            operationalIssues: sharedChunkBuildFailureIssues(schemataOutcome?.sharedChunkBuildFailureEvents ?? [])
                + (fallbackReport?.operationalIssues ?? [])
        )
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
            let key: String = switch reason {
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

    private static func toolchainHash(_ toolchain: ToolchainFingerprint) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(toolchain) else { return "unknown-toolchain" }
        return ContentHash.of(data)
    }
}
