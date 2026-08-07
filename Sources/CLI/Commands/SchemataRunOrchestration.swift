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
    }

    static func run(
        context: Context, workspaces: WorkspaceManager, schemataWorkspaces: WorkspaceManager, timeoutSeconds: Double
    ) async throws -> RunReport {
        guard let schemataBuild = context.adapter.build as? SchemataBuildable,
              let schemataTest = context.testAdapter as? SchemataTestable
        else {
            throw OrchestrationError.adapterNotSchemataCapable
        }

        let startedAt = Date()
        let classification = try await classify(context)

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

        let schemataPortion = try await runSchemataPortion(
            context, inputs: SchemataPortionInputs(
                programs: classification.programs, embeddedIDs: classification.embeddedIDs, sources: classification.sources,
                build: schemataBuild, test: schemataTest, policy: policy
            ),
            workspaces: schemataWorkspaces, timeoutSeconds: timeoutSeconds
        )

        let fallbackIDs = Set(context.plan.mutations.map(\.id)).subtracting(classification.embeddedIDs)
        let fallbackReport = try await runFallbackPortion(context, fallbackIDs: fallbackIDs, workspaces: workspaces)

        return merge(
            context, startedAt: startedAt, schemataPortion: schemataPortion, fallbackReport: fallbackReport,
            embeddedCount: classification.embeddedIDs.count, fallbackCount: fallbackIDs.count
        )
    }

    /// What `classify` determined about a plan: which programs were
    /// actually lowered, which `MutationID`s they cover, and the pristine
    /// pre-lowering source content `SchemataMutationRunner` needs for
    /// honest source-level evidence.
    private struct Classification {
        let programs: [SchemataProgram]
        let embeddedIDs: Set<MutationID>
        let sources: [String: Data]
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

        let empty = Classification(programs: [], embeddedIDs: [], sources: sources)

        let targetInfo: [String: [SchemataTargetInfo]]
        do {
            targetInfo = try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: context.projectRoot)
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
            backendID: "swiftpm-schemata-v1", backendVersion: 1,
            toolchainHash: toolchainHash(context.toolchain), buildArgumentsHash: context.configuration.configurationHash
        )
        do {
            let registry = try SchemataLowererRegistry()
            let result = try SchemataChunkPlanner.plan(
                mutationPlan: context.plan, registry: registry, sources: sources, targetInfo: targetInfo, backend: backend
            )
            let embeddedIDs = Set(result.schemataPlan.entries.filter(\.isEmbedded).map(\.mutationID))
            return Classification(programs: result.programs, embeddedIDs: embeddedIDs, sources: sources)
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
        _ context: Context, inputs: SchemataPortionInputs, workspaces: WorkspaceManager, timeoutSeconds: Double
    ) async throws -> SchemataPortionResult {
        guard !inputs.programs.isEmpty else { return .notApplicable }
        let points = Dictionary(
            uniqueKeysWithValues: context.plan.mutations.filter { inputs.embeddedIDs.contains($0.id) }.map { ($0.id, $0) }
        )
        let runner = SchemataMutationRunner(
            planID: context.plan.planID, workUnitID: context.plan.planID,
            programs: inputs.programs, points: points, originalSources: inputs.sources,
            build: inputs.build, test: inputs.test, workspaces: workspaces, timeoutSeconds: timeoutSeconds,
            toolchainHash: toolchainHash(context.toolchain), buildArgumentsHash: context.configuration.configurationHash,
            policy: inputs.policy
        )
        do {
            return .succeeded(try await runner.run())
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
        _ context: Context, fallbackIDs: Set<MutationID>, workspaces: WorkspaceManager
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
            build: context.adapter.build, test: context.testAdapter, workspaces: workspaces, toolchain: context.toolchain
        ).run()
    }

    /// One report from two independent passes. Known, explicitly-accepted
    /// v1 inefficiency (see ADR-0006): both passes build and run their own
    /// baseline; only one `BaselineRecord` can go in the final report. A
    /// genuine schemata baseline failure is surfaced twice:
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
        embeddedCount: Int, fallbackCount: Int
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
            requested: .schemata, effectiveCount: embeddedCount, fallbackCount: fallbackCount, degradationReason: degradationReason
        )

        return RunReport(
            planID: context.plan.planID, startedAt: startedAt, finishedAt: Date(), projectRoot: context.projectRoot.path,
            toolchain: context.toolchain, baseline: baseline, ledger: ledger, integrity: integrity,
            executionStrategy: executionStrategy, operationalIssues: fallbackReport?.operationalIssues ?? []
        )
    }

    private static func toolchainHash(_ toolchain: ToolchainFingerprint) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(toolchain) else { return "unknown-toolchain" }
        return ContentHash.of(data)
    }
}
