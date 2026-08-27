import Foundation

/// A manually-bumped identity for MutantKit's own execution-affecting
/// implementation — mutation discovery *routing* (which operator claims
/// which site), mutation application mechanics
/// (`MutationApplication.apply`), test selection (`selectCoveringTests`'s
/// own algorithm), and build/workspace orchestration.
///
/// This exists to close a real gap found during the P4 (cache soundness)
/// investigation (`Research/mutation-testing-hardening-2026-08/PROGRESS.md`):
/// `ToolVersion.version`/`.commitSHA` — the fields `RunContextProbe`'s
/// context digest already carries specifically to catch "the tool's own
/// implementation changed" — are hardcoded development-build placeholders
/// (`"0.1.0-dev"`/`nil`) until an actual release's own substitution step
/// runs, so they provide *zero* protection during any local `swift
/// build`/`swift run mutantkit` — exactly this whole session's own
/// development mode, every time.
///
/// **What this deliberately does *not* need to cover**, because it is
/// already covered elsewhere, more precisely, by mechanisms this
/// constant would only duplicate:
///
/// - An operator's own discovery/replacement-text logic changing for an
///   otherwise-identical site: `PlannedMutationRef.pointDigest` already
///   hashes `replacementText` (and `operatorVersion`) directly, so a
///   changed replacement already produces a different digest and a clean
///   cache miss — see `PlannedMutationRef.swift`'s own
///   `CanonicalPointContent`. An operator newly admitting or newly
///   excluding a candidate produces a `MutationID` that simply did not
///   exist before (`operatorVersion` is one of `MutationID.compute`'s
///   own inputs), never a stale hit against an existing one.
/// - Classification/verification rule changes (how a completed
///   `MutationObservations` gets judged): already `MutationVerdictVerifier
///   .currentVersion`'s own job, checked independently in
///   `MutationResultCache.load` already.
///
/// What's left, and what this constant is actually for: everything about
/// *how a mutation moves from "planned" to "an observed build/test
/// result"* — which tests actually get selected and run for it, how its
/// replacement text is spliced into the sandbox, how the sandbox/workspace
/// itself is built — none of which touches a `MutationPoint`'s own
/// content or the verifier's own rules, so neither existing mechanism
/// would ever notice a change here. A bug fix to `selectCoveringTests`
/// that starts including a previously-missed covering test, for example,
/// can turn a real "survived" into a real "killed" for an *unchanged*
/// `MutationID`/`pointDigest` — exactly the shape of stale cache hit nothing
/// else here would catch.
///
/// Checked directly by `MutationResultCache`, independent of
/// `RunContextProbe`'s context digest, the identical mechanism
/// `MutationVerdictVerifier.currentVersion` already uses: bumped by hand
/// whenever a change in scope lands, never inferred, never derived from
/// git state (a derived value would need the running binary to still
/// have access to the exact source checkout it was built from, which does
/// not hold once a binary is copied or installed elsewhere).
public enum ExecutionImplementationVersion {
    /// Introduced by the P4 cache-soundness gap fix — no prior value to
    /// have bumped from.
    public static let current = 1
}
