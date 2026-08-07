# ADR-0004: The schemata production-integration contract

- **Status:** In progress (Stage 1 of 10 implemented; see below)
- **Date:** 2026-07-28

## Context

ADR-0003 built the schemata backend's evidence and plan contract in
isolation from `MutationRunner` — deliberately: every review cycle in that
ADR's history found real, sometimes serious, defects in each stage, and
attempting the real `MutationRunner` integration on top of an unproven
evidence contract would have compounded those errors rather than caught
them individually. Addendum 8 explicitly named this: "None of S5 ... or the
real `MutationRunner` integration should start until whichever of the above
items actually blocks them is addressed."

A sixth review (after addendum 9's fixes were merged) evaluated the
question ADR-0003 always deferred: what does it actually take to connect
the schemata backend to `MutationRunner` and have its results survive
report generation, integrity checking, and cross-run caching? It found the
answer is not a bounded bug fix — `MutationResult` itself cannot hold
schemata evidence at all yet (`evidence: MutationEvidence?` is
isolated-only in every way that matters), and even once it can, several
further gaps (a `.noCoverage`-vs-evidence contradiction, no multi-target
membership model, no runtime-verified artifact identity, plan validation
that never checks the current execution context, no cache-time verified-
evidence contract) stand between that and a safe, honest integration.

This ADR records the ten-item roadmap that review produced, and each
stage's implementation as it lands — the same "review → fix real defects →
verify end-to-end → merge" discipline ADR-0003 already established, applied
one stage at a time so each stage's own review surface stays small enough
to actually check.

## The ten items

In the reviewing order, grouped by what each depends on:

1. **`MutationResult` becomes backend-aware.** `MutationEvidence
   .activationEvidence: ActivationEvidence?` only ever represented isolated
   mode's proof; nothing could attach schemata evidence to a real result.
   Foundational — nothing else on this list can be exercised end-to-end
   without it. **Implemented — Stage 1, this addendum.**
2. **A runtime startup/hit evidence protocol**, distinct events rather than
   only a hit line, so a host does not need to predict `expectedProcessID`
   in advance (the Xcode path cannot: `xcodebuild` launches `xctest` as an
   unobserved descendant) and so `selectedToken` becomes a runtime-*observed*
   fact instead of one the collector assumed equal to `requestedToken`.
   **Implemented — Stage 2, this addendum.** (`schemaArtifactID`/`imageUUID`
   remain host-supplied, not yet runtime-observed — see item 8.)
3. **Loaded/selected proof separated from hit proof**, so a build/load/
   select failure and "loaded correctly but the mutated site was never
   reached" are distinguishable outcomes rather than both collapsing into
   the same undifferentiated "not proven." Depends on item 2 (a startup
   event is what would prove "loaded and selected" independent of any
   hit). **Implemented — Stage 3, this addendum.**
4. **`.noCoverage` classification rule for schemata**, so a genuine
   contradiction (a verified hit, but coverage reporting the mutated code
   as never executed) is surfaced as an integrity problem rather than
   silently absorbed into `.noCoverage`. **Implemented — Stage 3, this
   addendum** (bundled with item 3, since the fix reads directly off
   `SchemataMutationEvidence.verify(against:)`, which item 3 did not need
   to change).
5. **Multi-target/multi-image membership.** `SchemataTargetInfo` mapped one
   source file to exactly one target; a file compiled into more than one
   target (an app plus a widget extension plus a framework, all sharing a
   source) could not be represented at all. **Implemented — Stage 4, this
   addendum** — representable now (`targetInfo` is `[String: [SchemataTargetInfo]]`),
   but embedding into more than one target's independent build at once is
   deliberately still fallback-only; see Stage 4 below for why.
6. **Persisted compilation-unit identity.** `projectIdentity` (added in
   ADR-0003 addendum 9) closed the immediate cross-project chunk-merging
   bug at planning time, but `SchemataChunk`/`SchemataPlanEntry` didn't
   carry it forward. **Implemented — Stage 4, this addendum.**
7. **Source location mapping.** Prepending the runtime declaration (fixed
   in ADR-0003 addendum 9) shifts every original line below it in that one
   file — harmless for compilation, but wrong for anything that reports a
   *line number* against the original source (coverage attribution, crash
   stack traces, diagnostics). **Implemented — Stage 5, this addendum.**
8. **A real final-artifact manifest**, distinguishing `sourceEmbeddingID`
   (what the lowerer alone can see — source content and structure) from
   whatever a build orchestrator's actual output artifact identity turns
   out to be (toolchain, SDK, architecture, compiler/linker flags, runtime
   archive version). **Evaluated and found to already exist at the type
   level — Stage 6, this addendum**: `manifestHash` (on both
   `SchemataEmbeddingEvidence` and `SchemataActivationEvidence`) was
   already exactly this separate field, already compared in
   `provesInternalConsistency` — it simply had no doc comment explaining
   its role, which read as though `schemaArtifactID` alone conflated both
   meanings. No new type introduced: one would have had no real caller to
   validate its shape against — the same discipline item 9's own (partial,
   bounded) implementation below applies.
9. **Execution-context-aware plan validation.** `SchemataPlan
   .decodeAndValidate` checked a plan against its own recorded parent
   `MutationPlan` (self-consistency) but never against the *current*
   execution environment (schema version, backend ID/version, toolchain
   hash, build arguments hash) — a stale or foreign-toolchain plan could
   still pass validation if its self-consistent hash matched its own
   (stale) contents. **Implemented — Stage 7, this addendum**, for exactly
   the fields `SchemataPlan` itself already records (schema version,
   backend ID/version, toolchain hash, build arguments hash); lowerer ID/
   version and runtime ABI version are per-*entry* facts, not plan-level
   ones, and checking those would need a `SchemataLowererRegistry` — a
   different module than `SchemataPlan` lives in, and still no real caller
   to validate the resulting shape against. Left for whichever future stage
   actually wires a lowerer registry into plan validation.
10. **A verified-verdict cache contract.** Schemata evidence is bound to a
    specific `runNonce`/`processID` that stops meaning anything once that
    process has exited — but `MutationResultCache` reuses a stored
    `MutationResult` across runs unconditionally on cache-key match, with
    no re-verification. **Evaluated and found already sound by the
    combination of items 1 and 4 — Stage 10 (final), this addendum**: no
    new contract was needed, for reasons that ADR text alone couldn't have
    confirmed without also checking `MutationOutcome.isCacheableResult`
    and `MutationResultCache.store`'s actual gate together, which this
    stage's write-up does explicitly.

## Stage 1: `MutationResult` becomes backend-aware

**What changed.** `MutationEvidence.activationEvidence: ActivationEvidence?`
is now `applicationEvidence: MutationApplicationEvidence?` — the
isolated/schemata union type ADR-0003 already defined but never wired up
anywhere. Isolated-mode construction (`MutationRunner.evidence(...)`) now
wraps its `ActivationEvidence` in `.isolated(...)`; nothing about isolated
mode's actual proof logic changed, only the field's declared type.

**Backward compatibility.** A report or checkpoint written before this
change has `activationEvidence: ActivationEvidence` under the old JSON key,
never `applicationEvidence`. `MutationEvidence`'s custom `init(from:)` tries
the new key first; only when it is entirely absent does it fall back to the
legacy key and wrap the result in `.isolated(...)` — the same
`decodeIfPresent`-based tolerant-decode convention `MutationResult`'s own
custom decoder already uses for fields that postdate it. A hand-written
`encode(to:)` accompanies it (required once `init(from:)` is hand-written
and reads a key with no synthesizable counterpart); every encode always
writes the current `applicationEvidence` key, never the legacy one.

**`Integrity.swift`'s `mutationNotActivated` check** — the "a scorable
outcome must have proven activation, even if it was loaded from a
checkpoint/cache written by an older classifier" defense-in-depth check —
now switches on `applicationEvidence`'s case: `.isolated` re-derives
`ActivationEvidence.provesActivation` exactly as before; `.schemata`
re-derives `SchemataMutationEvidence.provesInternalConsistency`, the
persisted, re-derivable-from-stored-data fact, rather than re-running
`verify(against:)` — which needs an external `SchemataScoringContext`
(expected process ID, run nonce) that only exists at classification time,
when the harness has just launched the process. A stored `MutationResult`
has no business persisting that transient state, so this is a deliberately
weaker re-check than `verify(against:)` itself — but the classifier is the
only thing that ever attaches a `.schemata` case to a result in the first
place, and it only does so for evidence whose `verify(against:)` already
returned `true`. This mirrors the isolated case's own posture exactly:
neither re-runs the classifier's original judgment, both re-derive a
boolean from what is already stored, as a guard against a checkpoint/cache
record written by a classifier that skipped the gate — not against
stale-run replay, which the classifier already ruled out once, at the only
point where it was possible to.

**`InspectCommand.swift`** renders both cases (report-only, no decision
logic) — refactored into `printEvidence(_:)`/`printConfirmation(...)`
helpers along the way, since the added `switch` pushed `run()` over
SwiftLint's complexity/length thresholds; `.swiftlint.yml`'s own comment
already flagged this function as "worth a real refactor... the next time
this file is touched substantively."

**What did *not* change:** `MutationResultCache` (keys and stores/loads
generically, unaware of evidence internals beyond `isReportable`), `RunReport`/
`MutationScore`/checkpoint machinery (operate on `MutationResult`/
`MutationOutcome`, not evidence internals), `MutationResult.isReportable`
(still delegates to `MutationEvidence.provesSourceApplication`, which is
backend-agnostic — a source diff is a source diff regardless of which
backend eventually proves activation).

**Verified:** full unit suite (819 tests), `swiftformat --lint` clean,
`swiftlint --strict --baseline` clean, and real acceptance suites —
`SwiftPackageMacOSAcceptanceTests` (proves every scored isolated-mode
mutant's `applicationEvidence.isolatedActivation` round-trips through a
real `swift build`/`swift test` run) and `XcodeUnlinkedSourceAcceptanceTests`
(same proof through the Xcode adapter). `SwiftPackageMacOSCoverageAcceptanceTests`
has two pre-existing failures (`Integrity reconciles across the coverage
fast path`, `Effective score is stable; Tested score improves with
noCoverage`) confirmed to reproduce identically on unmodified `main` —
unrelated to this change, not investigated further here (out of this
stage's scope).

## Stage 2: a runtime startup/hit evidence protocol

**What changed.** The C runtime (`mutantkit_schemata_runtime.c`) gained a
second event, distinct from a hit: an `__attribute__((constructor))`
function runs at image-load time — before `main`, before any Swift code,
independent of whether any mutated call site is ever reached — parses the
token exactly as before, and (if `MUTANTKIT_SCHEMATA_STARTUP_PATH` and a
valid, non-empty run nonce are both set) writes one line:
`<namespace>:<localIndex>:<pid>:<runNonce>`. A hit line is unchanged in
format and behavior.

`SchemataEvidenceCollector.collectActivationEvidence` is now
**nonce-primary, not PID-primary**: it no longer takes `expectedProcessID`
as a parameter at all. Instead, it looks for a startup line matching
`requestedToken` and `context.runNonce` — the nonce is something *every*
backend's host already generates and passes via `runNonceEnvironmentVariable`
before launch, unlike a PID, which the SwiftPM path can read directly off
its own `Process` but the Xcode path fundamentally cannot (`xcodebuild`
launches `xctest` as an unobserved descendant). Once a matching startup
line is found, its `pid` field becomes the PID hits are matched against in
`evidencePath`, and its `token` field becomes `selectedToken` — a real,
runtime-observed value now, not an assumption the collector made on its
own behalf. No startup match at all means `selectedToken` falls back to
`requestedToken` and `hitToken` stays `nil`, the same fail-closed shape as
before this change.

**Xcode evidence collection is now real, not absent.**
`SchemataXcodeRuntimeAcceptanceTests` previously only checked whether the
mutated test's pass/fail result flipped — addendum 8 named "the Xcode
acceptance suite collects no runtime evidence at all" as a known,
unaddressed gap. It now also injects `startupPathEnvironmentVariable`/
`evidencePathEnvironmentVariable`/`runNonceEnvironmentVariable` into the
`.xctestrun`'s environment (the same mechanism already used for the
requested token) and, after the real `xcodebuild test-without-building`
run, calls `collectActivationEvidence` and asserts `provesActivation` —
proving, against a real `xctest` process whose PID this host never
predicted or even queried, that the whole chain works.

**Verified:** full unit suite (823 tests, including new `parseStartupEvents`
and nonce-discovery coverage in `SchemataEvidenceCollectorTests`),
`swiftformat`/`swiftlint --strict --baseline` clean, and three real
end-to-end acceptance runs: `SchemataSwiftPMRuntimeAcceptanceTests` (a real
`swift build` + subprocess runs, including a redesigned stale-evidence test
that now distinguishes runs by nonce rather than PID — the property the new
design actually depends on), and `SchemataXcodeRuntimeAcceptanceTests` (a
real `xcodebuild build-for-testing` + `test-without-building`, now
collecting and verifying real composite evidence, not just a pass/fail
flip).

## Stage 3: loaded/selected proof separated from hit proof, and a real
`.noCoverage` contradiction check

**What changed.** `SchemataActivationEvidence` gained a `startupConfirmed:
Bool` field, set by `SchemataEvidenceCollector` (`true` when a matching
startup event was actually found, `false` on the fallback path where
`selectedToken` is only ever assumed equal to `requestedToken`). Without
this, `selectedToken == requestedToken` was ambiguous — true both when the
runtime genuinely confirmed it and when nothing was confirmed at all and
the collector merely assumed it. A new `provesLoadedAndSelected: Bool`
computed property (`startupConfirmed && requestedToken == selectedToken`)
makes the weaker, hit-independent proof explicit: "the process loaded the
right artifact and selected the right token" is now answerable on its own,
separate from `provesActivation`, which additionally requires a hit.
`provesActivation` itself is unchanged — a hit already implies successful
load/select, so it never needed `startupConfirmed` as an extra condition.

`SchemataResultClassifier.classifySchemataPassing` now checks for a
genuine coverage/evidence contradiction before trusting a coverage miss:
if `coverage.mutatedLineWasExecuted == false` but `evidence` has a real
hit token *and* `evidence.verify(against: context)` succeeds (the full
score-worthiness gate, not just internal consistency — this must be
evidence for *this* run, not a coincidentally-matching stale bundle), that
is `.infrastructureFailure` with a diagnosis naming the contradiction
directly, not `.noCoverage`. Unproven or absent evidence still yields
`.noCoverage` exactly as before — the fix only changes behavior in the one
case where coverage and evidence genuinely disagree about the same run.

**Verified:** full unit suite (829 tests, including new
`provesLoadedAndSelected` coverage in `SchemataEvidenceTests` and three new
classifier tests distinguishing "no evidence," "unproven evidence," and "a
verified hit" against the same coverage-miss input), `swiftformat`/
`swiftlint --strict --baseline` clean, and a real
`SchemataSwiftPMRuntimeAcceptanceTests` run confirming the collector's new
`startupConfirmed` field doesn't disturb the real end-to-end path.

## Stage 4: multi-target membership becomes representable; compilation-unit
identity is persisted

**What changed.** `SchemataChunkPlanner.plan`'s `targetInfo` parameter is
now `[String: [SchemataTargetInfo]]`, not `[String: SchemataTargetInfo]` —
a source file can genuinely belong to more than one target's own Compile
Sources (a shared model file added directly to both an app target and a
widget extension, say), which the old one-target-per-file map simply had
no way to express. When a file's memberships list has more than one entry,
every mutation point in that file now falls back to isolated execution
with a new reason, `SchemataUnsupportedReason.multipleTargetsNotYetSupported`
— **representable, but not yet embeddable**: each target membership is a
genuinely separate build, and embedding into only one of them while
silently leaving the mutation absent from every other target's compiled
copy would misrepresent what was actually tested. Isolated mode already
handles this case correctly (it rebuilds every affected target from the
mutated source), so falling back loses nothing real; the alternative
(guessing one target) would have been actively wrong, not just
incomplete. Actually embedding into every membership at once — separate
chunks, separate selector namespaces, separate evidence per target — is
real future work, deliberately out of scope for this stage.

Separately, `SchemataChunk` and `SchemataPlanEntry` both gained a
`projectIdentity: String` field, threaded from `SchemataTargetInfo
.projectIdentity` (added in ADR-0003 addendum 9, but only ever used
transiently inside the planner's own grouping key until now). A build
orchestrator reading a persisted `schemata-plan.json` back later can now
tell which project/target an entry belongs to directly from the entry
itself, without needing to re-consult the planner's `targetInfo` map — the
same self-containment principle `sourceEmbeddingID`/`chunkID` already
follow.

**Verified:** full unit suite (830 tests, including a new planner test
proving a multi-target file falls back rather than being silently assigned
to one target), `swiftformat`/`swiftlint --strict --baseline` clean, and
real `SchemataSwiftPMRuntimeAcceptanceTests`/`BoolLiteralSchemataCompileViabilityAcceptanceTests`
runs confirming the single-target path (the only path any acceptance
fixture exercises) is unaffected.

## Stage 5: source location mapping for the declaration-carrying file

**What changed.** `SchemataSourceFile` gained `prependedLineCount: Int`
(default `0`, so every existing call site compiles unchanged) — how many
whole lines were prepended ahead of a lowered file's own original content.
`BoolLiteralSchemataLowerer` sets it to `runtimePreamble`'s own real
newline count (computed from the literal, never hardcoded, so it cannot
drift out of sync) on whichever file actually received the declaration,
and leaves it `0` on every other file. A caller mapping a line number the
*built* artifact reports — coverage attribution, a compiler diagnostic,
crash symbolication — back to original source now has what it needs:
`originalLine = builtLine - prependedLineCount` for the one file that
carries a shift, no adjustment at all for every other file in the chunk
(splicing a mutation in place never changes line count for this lowerer,
since neither the original nor replacement text for a boolean literal ever
contains a newline).

Deliberately scoped to exactly this: a plain integer field the lowerer
computes and reports, not a general line-mapping abstraction. Nothing
today consumes it (no schemata-aware coverage or diagnostic tooling exists
yet), so there was no real call site to design a richer API against
without guessing — the same reasoning ADR-0003 addendum 9 already applied,
and the same reasoning item 9's own bounded scope (below) applies again.

**Verified:** full unit suite (831 tests, extending the existing
single-point and untouched-file-passthrough lowerer tests to also assert
on `prependedLineCount`, computed independently by counting newlines
rather than asserting a hardcoded number), `swiftformat`/`swiftlint
--strict --baseline` clean, and real `SchemataSwiftPMRuntimeAcceptanceTests`/
`BoolLiteralSchemataCompileViabilityAcceptanceTests` runs confirming the
change is compile/link/activation-neutral.

## Stage 6: the final-artifact manifest already exists — it needed a doc
comment, not a new type

**What changed.** Re-reading `SchemataEmbeddingEvidence` and
`SchemataActivationEvidence` closely to scope item 8 found that `manifestHash`
was already the field the review asked for: a build-orchestrator-computed
identity (toolchain/SDK/architecture/flags/runtime-archive — how the chunk
was built), kept fully separate from `schemaArtifactID`/`sourceEmbeddingID`
(what the lowerer alone can see — source content and structure), and
already checked in `provesInternalConsistency`
(`embedding.manifestHash == activation.manifestHash`, alongside the
`schemaArtifactID` check). The review's premise — that `schemaArtifactID`
"conflates" the two by doc-comment convention only — was accurate about
the *documentation* but not about the *type*: nothing needed to change
structurally, `manifestHash` simply had no doc comment of its own
explaining what it was for, so a reader had no way to know it was the
answer to this exact concern. Both fields on both structs now have doc
comments spelling out their distinct roles and cross-referencing each
other.

Deliberately did not introduce a new `SchemataArtifactManifest`-style type
(as an earlier draft of this ADR's own item 8 description sketched): with
no real build orchestrator caller yet to construct one, any such type
would be guessing at a shape nothing exercises. When a real build
orchestrator exists, it populates `manifestHash` with a real value instead
of a placeholder; the verification chain the review asked for (plan →
manifest → runtime → image) already exists via `manifestHash`/
`schemaArtifactID`/`imageUUIDs`/`imageUUID`, wired together in
`provesInternalConsistency` and `verify(against:)`.

**Verified:** doc-only change — full unit suite unaffected (not rerun for
this stage beyond a build+lint check), `swiftformat`/`swiftlint --strict
--baseline` clean.

## Stage 7: execution-context-aware plan validation, for the fields
`SchemataPlan` already records

**What changed.** `SchemataPlan.decodeAndValidate` gained an optional
`executionContext: SchemataExecutionContext? = nil` parameter (default
`nil`, so every existing caller compiles and behaves unchanged). When
supplied, it additionally checks the decoded plan's `schemaVersion`,
`backendID`, `backendVersion`, `toolchainHash`, and `buildArgumentsHash`
against the caller's own record of what is true *right now* — closing the
exact gap the review named: a plan whose self-consistency hash still
matches its own (stale) contents passes every existing check even if it
was built yesterday, under a different toolchain, for a different
backend. Five new `ValidationError` cases (one per field) report which
specific mismatch fired, mirroring the existing error cases' shape and
`description` style.

Scoped to exactly the fields `SchemataPlan` itself already records at the
plan level. The review's fuller ask also named lowerer ID/version and
runtime ABI version — deliberately not attempted here: those are per-
*entry* facts (each `SchemataPlanEntry.placement` carries its own
`lowererID`/`lowererVersion` when `.embedded`), and checking them against
"the current registry's own lowerer versions" would need a
`SchemataLowererRegistry` value, which lives in the `MutationPlanner`
module — a different, higher-level module than `SchemataPlan`
(`MutationModel`) can depend on without an inversion. That check belongs
at whichever call site already has both a decoded plan and a live
registry in scope — which, per this ADR's own running theme, does not
exist yet either.

**Verified:** full unit suite (836 tests, split into a new
`SchemataPlanExecutionContextTests.swift` file — folding the five new
tests into `SchemataPlanTests.swift` directly would have pushed it over
SwiftLint's `type_body_length` cap — reusing that file's own fixture
helpers rather than duplicating them), `swiftformat`/`swiftlint --strict
--baseline` clean.

## Stage 10 (final): the cache contract — traced where code exists, two
real gaps flagged where it doesn't yet

**The question.** A stored `MutationResult`'s `.schemata` evidence carries
`runNonce`/`processID` that only ever meant something for the one process
that produced them, and that process is long gone by the time
`MutationResultCache` might reuse the result on a later run. Does reusing
it anyway need a new, explicit "verified verdict receipt" contract
distinct from a freshly-classified result — or does item 1's existing
"verify once, at classification time, persist only the outcome" design
already cover this?

An adversarial re-check of this stage's first draft (which claimed to have
"traced, not assumed" the whole argument) found the first draft overclaimed
in two places — corrected below. The conclusion ("no new receipt-type is
needed") still holds, but two real, worth-recording gaps sit underneath it.

**What is actually traced, in code that exists today:**

1. `MutationResultCache.store(_:for:)` gates on `result.outcome
   .isCacheableResult && result.isReportable`. `isCacheableResult`
   (`MutationOutcome.swift`) allow-lists exactly `.survived`, `.noCoverage`,
   `.killedByAssertion`, `.killedByCrash`, `.verifiedTimeout` — and
   explicitly excludes `.infrastructureFailure`. `CacheRecord` is private
   and constructed nowhere else; this is the cache's only write path.
2. `SchemataResultClassifier.classifySchemata`/`classifySchemataPassing`'s
   own *decision logic* only returns `.survived`/`.killedByAssertion`/
   `.killedByCrash` after `evidence.verify(against: context)` already
   succeeded; an unproven bundle is always reclassified to
   `.infrastructureFailure` first. This part is genuinely verified by
   reading the classifier.

**Gap 1 — the evidence-*attachment* half is a documented convention, not
code, because the code doesn't exist yet.** `SchemataResultClassifier
.Classification` carries only `outcome`/`diagnosis`, no evidence — the step
that would actually set `MutationEvidence.applicationEvidence =
.schemata(...)` on a `MutationResult` is part of the real `MutationRunner`
integration this whole ADR exists to prepare for, and that integration has
not been built (`SchemataResultClassifier.swift`'s own doc comment already
says so: "`MutationRunner` does not call any of this yet"). The rule "only
ever attach `.schemata` evidence for a mutation whose `verify(against:)`
already returned `true`" is currently enforced by a doc comment on
`MutationEvidence.applicationEvidence`, not by the type system or by any
code path that runs today. Fact 2 above is real; the *coupling* between
fact 2's classification decision and what actually gets stored on a
`MutationResult` is a contract the eventual `MutationRunner` integration
must honor, not something already proven by running code. Whoever builds
that integration should re-read this stage's reasoning and confirm the
coupling holds, rather than trust that it already does.

Related and worth naming precisely rather than glossing: `.verifiedTimeout`
is in `isCacheableResult`'s allow-list, but no schemata code path produces
it today — `classifySchemata`'s `.timedOut` case always returns plain
`.timedOut` (not cacheable), and the only real `.verifiedTimeout` producer
(`ResultClassifier.confirmTimeout`) is isolated-mode-only, keyed on
`ActivationEvidence`, not `SchemataMutationEvidence`. The claim "every
schemata path producing `.verifiedTimeout` requires `verify` first" is true
today only because there is no such path yet, not because one exists and
was checked.

**Gap 2 — cache reuse assumes schema builds are deterministic, and nothing
detects a violation.** The argument that "a fresh verification's conclusion
remains permanently true, independent of whether the process still exists"
is correct only if a rebuild under the identical cache key would produce
the identical schema artifact (`schemaArtifactID`/`manifestHash`/
`imageUUIDs`/selector-token assignment). `MutationResultCache.Key
.contextDigest` (`RunContextProbe.computeContextDigest`) is built from
source-tree identity, configuration hash, and toolchain *version strings*
— it contains no actual build-artifact hash. Isolated mode makes the
identical determinism bet with less at stake (one whole-binary hash);
schemata evidence carries strictly more state that has to reproduce
identically (artifact ID, manifest hash, image UUIDs, selector token
assignment) for reuse to mean what this stage claims it means. `Integrity
.swift`'s `mutationNotActivated` re-check (Stage 1) only re-derives
`provesInternalConsistency` — self-consistency of the *stored* bundle,
never a comparison against what a fresh build would actually produce — so
a schema build orchestrator with any non-determinism in chunk/token
assignment could produce a false "still valid" read with nothing today
positioned to catch it. This is a real, open caveat for whichever future
stage designs the actual build orchestrator (items 6/8's "not yet built"
territory), not a flaw in anything currently shipped — nothing in this
codebase's schemata path is non-deterministic today, since there is no
real build orchestrator yet for it to be non-deterministic *in*.

**No new type or contract introduced, still the right call.** Given both
gaps trace back to code that does not exist yet (the `MutationRunner`
integration, and the real build orchestrator), inventing a "verified
verdict receipt" type now would be guessing at a shape neither gap's real
fix has been designed against — the same speculative-abstraction risk
items 6, 8, and 9 already declined for the same reason. The right fix for
both gaps is to design them alongside whichever future stage actually
builds the code they depend on, with this stage's reasoning (and its two
flagged gaps) as the starting point, not to pre-build machinery now.

**Verified:** analysis-only stage — traced `MutationResultCache.swift`,
`MutationOutcome.isCacheableResult`, and `SchemataResultClassifier.swift`
directly, then re-verified adversarially (catching the two gaps above,
which the first draft of this stage missed) rather than trusting a single
read-through; no code changed, so no new test run beyond confirming the
full suite still passes from a clean checkout.

---

All ten items from the sixth review are now addressed: eight implemented
with real code changes (1–7, 9 — six stages, several items bundled two to
a stage), and two (8, 10) evaluated and found to need documentation or
analysis rather than new code — for item 10, that analysis surfaced two
real, explicitly-flagged gaps that belong to future, not-yet-built stages
rather than anything shipped today. Phase C — the schemata
production-integration contract — is complete as scoped by that review.
Building the real `MutationRunner` integration this whole ADR exists to
prepare for, and S5 (a second operator's schemata lowering), remain the
next real body of work — and per every prior addendum's own closing
discipline, should get their own review cycle before starting, explicitly
re-checking this stage's two flagged gaps (the evidence-attachment
coupling, and build-artifact determinism) rather than assuming this ADR's
closed items mean nothing is left to verify.
