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
/// ## Hashing the *source* instead — measured, and also not a replacement
///
/// The investigation above only ever considered hashing the built
/// executable. Hashing normalized source is a different idea and does not
/// share that idea's non-determinism problem: a digest generated at build
/// time and embedded as a constant also sidesteps the "needs the source
/// checkout at runtime" objection, which applies to deriving a value *while
/// running*, not to code generation.
///
/// It was measured rather than argued about, over the 41 commits in the last
/// 200 that modified a Swift file under `Sources/MutationExecution`,
/// `Sources/AppleBuildAdapters` or `Sources/MutationPlanner`:
///
/// | what the digest covers | commits that would force a bump |
/// |---|---|
/// | raw file bytes | 41 of 41 (100%) |
/// | file contents, comments and formatting stripped | 33 of 41 (80%) |
/// | only declarations this contract names, normalized | 10 of 41 (24%) |
///
/// At file granularity this fails for the same reason the executable hash
/// did, and the normalization buys only 20 points: a constant that
/// invalidates every cached result on four out of five in-scope commits
/// defeats the cache rather than costing it hit rate. The 8 commits that
/// normalization *does* absorb were all doc-comment edits, which this
/// repository produces a lot of.
///
/// Declaration granularity is a different proposition — one bump decision
/// per four in-scope commits is ordinary review discipline for code this
/// sensitive. Two things are true of that 24% and should not be lost: the
/// measurement used brace matching rather than SwiftSyntax and could not
/// attribute a declaration for 11 of the 33 code-changing commits, so it is
/// a floor rather than a settled number; and the set of in-scope
/// declarations is still written by hand, so this automates *remembering*,
/// never *judging*.
///
/// Which is the honest summary of the whole question: no digest can decide
/// whether a change alters behaviour. What one can do is make the decision
/// impossible to skip silently — the gap named at the end of this comment,
/// and the one that let a real bump (version 2 below) land late.
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
/// `selectCoveringTests` or any other test-selection algorithm, the
/// per-test coverage *measurement* that algorithm consumes
/// (`TestSelecting.measurePerTestCoverage` and everything it is built from:
/// test enumeration, the `-only-testing:` argument shape,
/// `PerTestCoverageAttribution.attribute`'s retry and partial-attribution
/// policy, and the coverage readers), `WorkspaceManager`/sandbox
/// provisioning, or the schemata
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
    /// Version history, newest last:
    ///
    /// 1. Introduced to close the cache-soundness gap described above — no
    ///    prior value to have bumped from.
    /// 2. Per-test coverage attribution stopped discarding the whole map
    ///    over one unprovable test: an unmeasurable test is now carried in
    ///    `PerTestCoverageMap.unattributedTests` and folded into every
    ///    selection, and each test is retried once before it is given up
    ///    on. That is a change to `selectCoveringTests`' own algorithm and
    ///    to the measurement it consumes, which the maintenance contract
    ///    above requires a bump for — it landed without one, and this is
    ///    that bump. (Found by auditing which identities actually guard
    ///    which artifacts, not by anything failing: a verdict cached under
    ///    the old behaviour came from a *wider* test selection than the new
    ///    behaviour produces, so reusing one was never unsound in this
    ///    particular direction. The contract does not ask each change to be
    ///    re-argued case by case, and a bump costs one cold cache.)
    /// 3. Selection and the `.noCoverage` fast path stopped treating a line the coverage export has
    ///    no region for as a line no test reaches. A literal default argument such as
    ///    `isBuiltInDefault: Bool = false` has no counter, so it never appeared in any test's executed
    ///    lines; the mutant on it was scored `.noCoverage` (per-test granularity) or run against an
    ///    empty selection and scored `.survived`, although a test kills it. Found by re-running a
    ///    sample of survivors against the whole suite. A verdict cached under the old behaviour can be
    ///    that false one, so unlike version 2 reusing it is unsound; this bump drops those entries.
    /// 4. The instrumented build of a per-test coverage measurement wraps the initializer of every
    ///    `static let` and global in a closure, so a literal in one now has coverage lines. They were
    ///    unmeasured before, so every mutant on one ran the whole suite. A map cached before has no
    ///    lines there, which only means a wider selection, but the bump measures them once.
    /// 5. A multi-target MutationID aggregated as `.survived` although a sibling placement could not be
    ///    scored (`infrastructureFailure`, `flaky`, an unconfirmed timeout, ...), and a placement-level
    ///    fallback could discard a kill another placement had verified. Aggregation policy version 2 sends
    ///    the former to isolated mode and keeps the latter. A verdict cached under the old policy can be that
    ///    false survivor, so reusing one is unsound.
    /// 6. Process close-out now sends a group SIGKILL on every exit and verifies afterwards that the root,
    ///    every tracked descendant and every other member of its process group are gone; when that cannot be
    ///    verified the whole run aborts and discards what it persisted. A verdict cached before was observed
    ///    without that proof, possibly next to a stray process from an earlier observation, so it is not reused.
    /// 7. An exit 1 with no xunit report naming any test was credited as an assertion kill with no test
    ///    recorded, and a failing XCTest in a mixed package read as `infrastructureFailure` because only the
    ///    Swift Testing report was written. Ordinary runs now request the XCTest report too, and a run that
    ///    recorded no test is not a kill. A kill cached under the old reading can be that unrecorded one, so it
    ///    is not reused.
    public static let current = 7
}
