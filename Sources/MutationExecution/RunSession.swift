import Foundation
import MutationModel

/// The fields both `MutationRunner` and `SchemataMutationRunner` already
/// agree on, in type and meaning, from their own current stored state —
/// see this project's internal execution-engine restructuring notes (not
/// part of this public repo) for the field-by-field justification/rejection
/// this type's shape comes from. Each runner builds its own `session`
/// *inside* its own `init`, from the parameters that `init` already
/// receives — this type never changes what either `init` accepts (both
/// initializers are a
/// public test surface, not an internal implementation detail).
///
/// Deliberately excluded (isolated-mode-only, per the plan's §1.2/§2):
/// `checkpoints`, `artifactsRoot`, `resultCache`, `resultCacheDigest`,
/// `priorityStore`, `monotonicNow`, `operationalIssues`. Also excluded:
/// `plan`/`programs`/`points`/`originalSources` (no common shape between the
/// two runners, per the plan's §4.4) and `build`/`test` (the two runners
/// need different protocol widths — `any BuildAdapter`/`any TestAdapter`
/// for `MutationRunner`, the narrower `any SchemataBuildable`/
/// `any SchemataTestable` for `SchemataMutationRunner` — per the plan's §2).
///
/// Wired into `MutationRunner`'s own construction path in Step 3, and into
/// `SchemataMutationRunner`'s in Step 4.
///
/// **Deviation from the extraction plan's §2 field list, found while doing
/// Step 4 and recorded here rather than silently reconciled**: the plan
/// lists `projectRoot` and `toolchain` as fields both runners supply, and
/// calls out `configuration` (§3 Step 4, option 4a) as needing to become
/// optional because `SchemataMutationRunner` has no `Configuration` to give
/// it. In fact the identical optionality problem applies to `projectRoot`
/// and `toolchain` too, for the same structural reason (no fabricated value
/// to invert scalars back into) plus one the plan's own inventory (§1.2)
/// already shows but its §2 field justification did not carry forward:
/// `SchemataMutationRunner` does not store a `projectRoot` field *at all* —
/// every path it needs is resolved through its own
/// `workspaces: WorkspaceManager`, whose own `projectRoot` is `private` on
/// an `actor` with no accessor. There is no value of the right type this
/// runner could supply even if the plan wanted a fabricated one. So both —
/// not just `configuration` — are optional here, extending the same 4a
/// precedent the plan already established for `configuration` rather than
/// inventing a new one: `nil` on the schemata side is an honest statement
/// of "this runner has none," never a reconstructed placeholder.
///
/// `configuration` itself is NOT a field here, despite the plan naming it:
/// nothing ever read `session.configuration` once wired in (`MutationRunner`
/// keeps and reads its own `private let configuration: Configuration`
/// directly, per Step 7's own note; `SchemataMutationRunner` never had one
/// to give), so carrying a write-only, always-`nil`-on-one-side duplicate of
/// a value one runner already owns outright would only invite the two
/// copies to silently disagree after a future edit. Reintroduce it here only
/// alongside an actual caller that reads `session.configuration`.
struct RunSession: Sendable {
    let projectRoot: URL?
    let toolchain: ToolchainFingerprint?
    let workspaces: WorkspaceManager
    let policy: MutationVerdictVerifier.VerdictVerificationPolicy
    let coverageCache: CoverageProfileCache?
    let coverageCacheKey: CoverageProfileCache.Key?
    let preEstablishedBaseline: SharedBaselineEstablisher.Outcome?
}
