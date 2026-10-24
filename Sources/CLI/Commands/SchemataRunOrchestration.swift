import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner

/// Combines the schemata backend's `SchemataMutationRunner` with the
/// existing, unmodified `MutationRunner` into one `RunReport` (the re-enabled schemata scoring)
/// — a schemata run is never 100% embeddable, so anything
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
    /// The `.sourceReadFailed` half of the former, two-case
    /// `OrchestrationError` (plan §3 Step 2 — see
    /// `HybridExecutionEngine.EngineError`'s own doc comment for the other
    /// half). Stays CLI-side because its only two throw sites,
    /// `classify(_:)` and `read(files:projectRoot:into:)`, both stay
    /// CLI-side per this plan's §0 module-boundary finding — same two
    /// diagnosis strings, unchanged wording, just under a smaller,
    /// single-case enum instead of a shared two-case one.
    enum ClassificationError: Error, CustomStringConvertible {
        case sourceReadFailed(file: String, underlying: String)

        var description: String {
            switch self {
            case let .sourceReadFailed(file, underlying):
                "could not read \(file) to plan schemata chunks: \(underlying)"
            }
        }
    }

    /// Everything about this run that stays constant across both the
    /// schemata and isolated-fallback portions — bundled so each private
    /// helper below takes one thing plus whatever is genuinely specific to
    /// its own step, rather than re-threading the same six values through
    /// every function's own parameter list. Moved to
    /// `HybridExecutionEngine.Context` (plan §3 Step 2); this alias keeps
    /// every existing unqualified `Context` reference below unchanged.
    typealias Context = HybridExecutionEngine.Context

    /// Moved to `HybridExecutionEngine.SchemataClassification` (plan §3
    /// Step 3); this alias keeps every existing unqualified `Classification`
    /// reference below unchanged. No longer `private` (plan §3 Step 6):
    /// `classify(_:)`'s return type must be at least as visible as
    /// `classify(_:)` itself, which is now called from `RunCommand.swift`.
    typealias Classification = HybridExecutionEngine.SchemataClassification

    /// Resolves target info and plans chunks. Any failure here (target
    /// resolution, chunk planning) degrades to "nothing is embeddable"
    /// rather than aborting the run — an infrastructure hiccup in the
    /// schemata-specific machinery must not prevent isolated mode from
    /// still producing a real result for every mutation, the same
    /// never-regress-isolated-mode discipline this whole effort is built
    /// on. The user explicitly opted into `.schemata`; a degraded-to-fully-
    /// isolated run still honors that better than a hard failure would.
    ///
    /// No longer `private` (plan §3 Step 6 — the former thin
    /// `SchemataRunOrchestration.run` wrapper that used to be this
    /// function's one caller is now inlined and deleted, so `RunCommand
    /// .execute`'s `.schemata` case calls this directly): the *only* thing
    /// only the CLI layer can compute (per this plan's §0 module-boundary
    /// finding), still handed to `HybridExecutionEngine.runHybrid` as an
    /// explicit parameter.
    static func classify(_ context: Context) async throws -> Classification {
        try await classify(
            Inputs(
                plan: context.plan, projectRoot: context.projectRoot, kind: context.adapter.kind,
                scheme: context.configuration.project.scheme,
                toolchainHash: HybridExecutionEngine.toolchainHash(context.toolchain),
                buildArgumentsHash: context.configuration.buildIdentityHash
            ),
            warn: { print($0) }
        )
    }

    /// What `classify` needs of a run, so `mutantkit execution-profile` can plan the same chunks without
    /// building a run context: the ids it derives from the toolchain and build arguments do not change
    /// which mutations embed.
    struct Inputs {
        let plan: MutationPlan
        let projectRoot: URL
        let kind: ProjectKind
        let scheme: String?
        let toolchainHash: String
        let buildArgumentsHash: String

        /// The same inputs over only `mutations`.
        func replacingMutations(_ mutations: [MutationPoint]) -> Inputs {
            Inputs(
                plan: MutationPlan(
                    planID: plan.planID, createdAt: plan.createdAt, projectRoot: plan.projectRoot,
                    toolchain: plan.toolchain, configurationHash: plan.configurationHash,
                    sourceFileHashes: plan.sourceFileHashes, mutations: mutations, skipped: plan.skipped,
                    operators: plan.operators, planningHash: plan.planningHash
                ),
                projectRoot: projectRoot, kind: kind, scheme: scheme,
                toolchainHash: toolchainHash, buildArgumentsHash: buildArgumentsHash
            )
        }
    }

    /// What the planner would do with a plan, for a report that must not run anything.
    struct Preview {
        /// Mutations in the plan.
        let total: Int
        /// Mutations the planner ran over: `total`, or an evenly spaced sample of it when the plan is large.
        let sampled: Int
        /// Of `sampled`.
        let embedded: Int
        /// Shared builds the sample needs.
        let chunks: Int
        /// Reason text to the number of sampled mutations falling back for it.
        let fallbackReasons: [String: Int]
        /// Set when the schemata machinery could not be set up at all (every mutation would run isolated), or
        /// when planning did not finish in time.
        let failure: String?

        init(
            total: Int, sampled: Int? = nil, embedded: Int, chunks: Int, fallbackReasons: [String: Int], failure: String?
        ) {
            self.total = total
            self.sampled = sampled ?? total
            self.embedded = embedded
            self.chunks = chunks
            self.fallbackReasons = fallbackReasons
            self.failure = failure
        }

        var isSample: Bool { sampled < total }
    }

    /// Most mutations `preview` plans; a larger plan is sampled. Planning a few thousand mutations takes
    /// minutes (every file of every target is read and lowered), which is too long for a report.
    static let previewSampleLimit = 500

    /// Longest `preview` waits for the planner.
    static let previewTimeLimitSeconds = 60.0

    /// `limit` elements of `mutations` at an even stride. A plan is sorted by mutation id, which is a hash, so
    /// this is spread over files and operators and does not follow file order. The same plan gives the same
    /// sample.
    static func evenlySpaced(_ mutations: [MutationPoint], limit: Int) -> [MutationPoint] {
        guard limit > 0, mutations.count > limit else { return mutations }
        return (0 ..< limit).map { mutations[$0 * mutations.count / limit] }
    }

    /// Plans the chunks for `inputs` without printing, building or running anything. A plan over
    /// `previewSampleLimit` is sampled, and the result says so; planning that has not finished within
    /// `previewTimeLimitSeconds` is reported as such.
    static func preview(_ inputs: Inputs) async -> Preview {
        let total = inputs.plan.mutations.count
        let sample = evenlySpaced(inputs.plan.mutations, limit: previewSampleLimit)
        let planned = sample.count == total ? inputs : inputs.replacingMutations(sample)
        let outcome = await withTimeLimit(seconds: previewTimeLimitSeconds) { await plannedPreview(planned, total: total) }
        return outcome ?? Preview(
            total: total, sampled: sample.count, embedded: 0, chunks: 0, fallbackReasons: [:],
            failure: "planning \(sample.count) mutation(s) did not finish within \(Int(previewTimeLimitSeconds)) s"
        )
    }

    private static func plannedPreview(_ inputs: Inputs, total: Int) async -> Preview {
        var warnings: [String] = []
        let sampled = inputs.plan.mutations.count
        do {
            let classification = try await classify(inputs, warn: { warnings.append($0) })
            var reasons: [String: Int] = [:]
            for reason in classification.plannerFallbackReasons.values { reasons["\(reason)", default: 0] += 1 }
            let failure = classification.programs.isEmpty && classification.embeddedIDs.isEmpty
                ? warnings.first { $0.hasPrefix("!") } : nil
            return Preview(
                total: total, sampled: sampled, embedded: classification.embeddedIDs.count,
                chunks: classification.programs.count, fallbackReasons: reasons, failure: failure
            )
        } catch {
            return Preview(total: total, sampled: sampled, embedded: 0, chunks: 0, fallbackReasons: [:], failure: "\(error)")
        }
    }

    /// The result of `work`, or `nil` if it has not finished after `seconds`. The work is not cancelled (it
    /// does not check for cancellation); the process ends soon after, so an abandoned plan costs nothing.
    private static func withTimeLimit<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = OneShot(continuation)
            Task { gate.resume(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.resume(nil)
            }
        }
    }

    /// Resumes a continuation once, whichever of two racing tasks gets there first.
    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static func classify(_ inputs: Inputs, warn: (String) -> Void) async throws -> Classification {
        var sources: [String: Data] = [:]
        try read(files: Set(inputs.plan.mutations.map(\.file)), projectRoot: inputs.projectRoot, into: &sources)

        let empty = Classification(programs: [], embeddedIDs: [], sources: sources, plannerFallbackReasons: [:])

        var targetInfo: [String: [SchemataTargetInfo]]
        let backendID: String
        var filesOutsideBuild: [String: String] = [:]
        do {
            switch inputs.kind {
            case .swiftPackageMacOS, .swiftPackageApple:
                targetInfo = try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: inputs.projectRoot)
                backendID = "swiftpm-schemata-v1"
            case .xcodeProject:
                let scoped = try await XcodeTargetResolver.resolveSchemeScopedTargetInfo(
                    projectRoot: inputs.projectRoot, scheme: inputs.scheme
                )
                targetInfo = scoped.targetInfo
                filesOutsideBuild = outsideSchemeReasons(scoped.filesOutsideScheme)
                backendID = "xcode-schemata-v1"
            case .xcodeWorkspace:
                let scoped = try await XcodeTargetResolver.resolveSchemeScopedWorkspaceTargetInfo(
                    projectRoot: inputs.projectRoot, scheme: inputs.scheme
                )
                targetInfo = scoped.targetInfo
                filesOutsideBuild = outsideSchemeReasons(scoped.filesOutsideScheme)
                backendID = "xcode-schemata-v1"
            case .auto:
                // `.auto` (never actually reached here — every
                // `ProjectAdapter` `AppleAdapterFactory.adapter(for:)`
                // constructs already reports a concrete kind, see
                // `SwiftPackageMacOSProjectAdapter.kind`/
                // `XcodeBuildProjectAdapter.kind`) are both explicitly out
                // of scope for schemata target resolution today — same
                // fail-closed-to-isolated degradation as a genuine
                // resolution failure below, just without pretending an
                // attempt was made.
                warn(
                    "! Schemata target resolution is not yet implemented for \(inputs.kind.rawValue); "
                        + "every mutation will run in isolated mode this run."
                )
                return empty
            }
        } catch {
            warn("! Schemata target resolution failed (\(error)); every mutation will run in isolated mode this run.")
            return empty
        }

        // One scheme build compiles every target it reaches from the same sandbox, so a lowered file that
        // two of those targets compile must declare the schemata runtime in both modules; a chunk is
        // planned per target and only declares it in its own. Such files run isolated, per mutation.
        if inputs.kind == .xcodeProject || inputs.kind == .xcodeWorkspace {
            let mutatedFiles = Set(inputs.plan.mutations.map(\.file))
            for (file, infos) in targetInfo where mutatedFiles.contains(file) && Set(infos.map(\.target)).count > 1 {
                targetInfo[file] = nil
                filesOutsideBuild[file] = "the file is compiled by several targets that one scheme build compiles together"
            }
        }
        // A mutated file with no resolved target (compiled only by targets the scheme does not build, or
        // listed through a mechanism the resolver does not read) gets its own isolated fallback; it must
        // not take the whole plan's schemata down with it.
        for file in Set(inputs.plan.mutations.map(\.file)).subtracting(targetInfo.keys) where filesOutsideBuild[file] == nil {
            filesOutsideBuild[file] = "the file's target membership could not be resolved"
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
        try read(files: targetFiles, projectRoot: inputs.projectRoot, into: &sources)

        let backend = SchemataBackendInfo(
            backendID: backendID, backendVersion: 1,
            toolchainHash: inputs.toolchainHash,
            buildArgumentsHash: inputs.buildArgumentsHash
        )
        do {
            let registry = try SchemataLowererRegistry()
            let result = try SchemataChunkPlanner.plan(
                mutationPlan: inputs.plan, registry: registry, sources: sources, targetInfo: targetInfo, backend: backend,
                filesOutsideBuild: filesOutsideBuild
            )
            let embeddedIDs = Set(result.schemataPlan.entries.filter(\.isEmbedded).map(\.mutationID))
            let plannerFallbackReasons = Dictionary(
                uniqueKeysWithValues: result.schemataPlan.entries.compactMap { entry in
                    entry.fallbackReason.map { (entry.mutationID, $0) }
                }
            )
            if let summary = plannerFallbackSummary(plannerFallbackReasons, embeddedCount: embeddedIDs.count) { warn(summary) }
            return Classification(
                programs: result.programs, embeddedIDs: embeddedIDs, sources: sources,
                plannerFallbackReasons: plannerFallbackReasons
            )
        } catch {
            warn("! Schemata chunk planning failed (\(error)); every mutation will run in isolated mode this run.")
            return empty
        }
    }

    private static func outsideSchemeReasons(_ files: some Sequence<String>) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: files.map { ($0, "the file belongs only to targets the run's scheme does not build") }
        )
    }

    private static func plannerFallbackSummary(
        _ plannerFallbackReasons: [MutationID: SchemataUnsupportedReason], embeddedCount: Int
    ) -> String? {
        guard !plannerFallbackReasons.isEmpty else { return nil }
        // The report records only counts per reason kind, and nothing at all when the whole plan
        // falls back; the detail (which target, which operand) is what a corpus owner needs.
        var detail: [String: Int] = [:]
        for reason in plannerFallbackReasons.values { detail["\(reason)", default: 0] += 1 }
        let lines = detail.sorted { $0.key < $1.key }.map { "  \($0.value) × \($0.key)" }
        return "Schemata planner: \(embeddedCount) embeddable, \(plannerFallbackReasons.count) isolated per mutation:\n"
            + lines.joined(separator: "\n")
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
                throw ClassificationError.sourceReadFailed(file: file, underlying: "\(error)")
            }
        }
    }
}
