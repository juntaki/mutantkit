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
            toolchainHash: HybridExecutionEngine.toolchainHash(context.toolchain),
            buildArgumentsHash: context.configuration.buildIdentityHash
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
                throw ClassificationError.sourceReadFailed(file: file, underlying: "\(error)")
            }
        }
    }
}
