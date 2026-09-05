/// A manually-bumped identity for MutantKit's own execution-affecting
/// implementation — mutation discovery *routing* (which operator claims
/// which site), mutation application mechanics
/// (`MutationApplication.apply`), test selection (`selectCoveringTests`'s
/// own algorithm), and build/workspace orchestration.
///
/// This exists to close a real gap: `ToolVersion.version`/`.commitSHA` —
/// the fields `RunContextProbe`'s context digest already carries
/// specifically to catch "the tool's own implementation changed" — are
/// hardcoded development-build placeholders (`"0.1.0-dev"`/`nil`) until
/// an actual release's own substitution step runs, so they provide
/// *zero* protection during any local `swift build`/`swift run
/// mutantkit` — exactly this whole session's own development mode,
/// every time.
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
///
/// ## Why this is a manual epoch, not an automatic executable-content hash
///
/// An automatic identity was investigated first, specifically to close the
/// one real weakness a manual epoch has: nothing stops a maintainer from
/// changing in-scope code and forgetting to bump this constant, in which
/// case the cache stays silently blind to exactly the class of change this
/// type exists to catch. The natural automatic candidate — hash the
/// *running MutantKit executable's own file* (`Bundle.main.executablePath`,
/// confirmed by direct experiment to resolve correctly across every
/// invocation shape: a direct path, a relative path, a symlink, and a
/// `$PATH` lookup) and fold that digest into the context instead of a
/// hand-maintained number — was spiked for real, not assumed to work, and
/// found to have a concrete, reproducible problem that rules it out as a
/// full replacement:
///
/// **Two clean builds (`rm -rf .build && swift build --product mutantkit`)
/// of the exact same, unchanged source produce two different executable
/// files.** Confirmed directly: identical source, `40.6M` both times, but
/// `cmp -l` found 5844 differing bytes, and `otool -l`'s `LC_UUID` load
/// command carried a different, randomly-generated UUID each time
/// (`D1A93999-...` vs `DB610FCF-...`) — the linker's own crash-
/// symbolication identifier, not derived from content, embedded fresh on
/// every link. That UUID also feeds the binary's ad-hoc code-signature
/// identifier (`codesign -dvvv` showed it verbatim in
/// `Identifier=mutantkit-<uuid-hex>`), which is itself embedded in the
/// binary — a second, cascading source of non-determinism from the same
/// root cause. A whole-executable hash would therefore treat *every fresh
/// build of unchanged code* — including every single CI run, which always
/// builds from a clean checkout — as a "new" execution implementation:
/// technically only ever a false *miss*, never a false hit (the strict bar
/// this investigation was told to hold to), but a false-miss rate of
/// "always, on every CI run and every local clean rebuild" defeats the
/// cache's entire purpose rather than merely costing it some hit rate.
///
/// A middle-ground fix (stripping the non-deterministic sections before
/// hashing, or forcing deterministic linking) was *not* pursued — it is
/// exactly the kind of extra machinery this investigation was told not to
/// invent without evidence that the simple spike specifically failed to
/// justify, and it would need its own dedicated correctness work (proving
/// the stripped hash still changes for every code change that matters,
/// which is a materially harder claim than "hash the whole file").
///
/// **The maintenance contract this manual epoch runs on, made explicit**:
/// bump `current` by one whenever a change lands to any of —
/// `MutationRunner`'s mutation-application/apply-to-sandbox path,
/// `selectCoveringTests` or any other test-selection algorithm,
/// `WorkspaceManager`/sandbox provisioning, or the schemata
/// build/embedding pipeline (`SchemataMutationRunner`,
/// `SchemataChunkPlanner` and lowerers) — any place that decides *how* an
/// already-identified mutation actually gets exercised, as opposed to
/// *which* mutation it is (already covered by `pointDigest`) or *how its
/// observation gets judged* (already covered by
/// `MutationVerdictVerifier.currentVersion`). Same enforcement shape as
/// that constant's own doc comment: bumped by hand, with a one-line reason
/// added to the version history below, checked automatically by
/// `MutationResultCache.load` — nothing currently checks that a qualifying
/// *source* change was actually accompanied by a bump (the same open
/// question `MutationVerdictVerifier.currentVersion` already lives with;
/// no corpus/lint enforcement exists for it either).
public enum ExecutionImplementationVersion {
    /// Introduced to close the cache-soundness gap described above — no
    /// prior value to have bumped from.
    public static let current = 1
}
