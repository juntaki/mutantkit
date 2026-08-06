# ADR-0005: An authoritative verdict pipeline, replacing per-consumer trust checks

- **Status:** In progress (PR A, PR B, PR C, PR D, PR E, PR F landed; see below)
- **Date:** 2026-07-29

## Context

ADR-0004 closed Phase C ("the schemata production-integration contract") by
fixing ten specific defects one at a time — each real, each independently
reviewed. But its own Stage 10 write-up already named the shape of problem
this ADR is about: "no new receipt-type is needed" *today*, because the real
`MutationRunner` integration and the real build orchestrator do not exist
yet. Once they do, the same question Stage 10 deferred comes back for real:
who decides a result is trustworthy enough to score, cache, and report — and
is that decision made once, or independently, several times, by code that
can disagree with itself?

Reading the current pipeline end to end shows it is the latter.

- **`IntegrityChecker.unactivatedScorableResultViolations`**
  (`Sources/MutationModel/Integrity.swift:268`) re-derives
  `provesInternalConsistency` for schemata evidence — an evidence bundle's
  *internal* self-consistency (its own fields agree with each other) — but
  never compares the evidence's own mutation identity against
  `result.point.id`. Nothing in this check would catch evidence for one
  mutant being attached to a `MutationResult` for another; it only checks
  that whatever evidence is attached is internally coherent.
- **`MutationRunner.run()`** (`Sources/MutationExecution/MutationRunner.swift:174-196`)
  stores each freshly-evaluated result into the cross-run cache
  (`cache.store(result, for: ...)`, line 176) *inside the same loop that
  produced `evaluated`*, before `IntegrityChecker.check(plan:results:
  baselinePassed:)` runs on the full `results` array at line 194. A
  duplicate-ID, phantom-mutant, or plan-mismatch violation discovered by
  that final, whole-run check cannot retroactively un-cache the individual
  results that already went in. `MutationResultCache.store` gates on
  `outcome.isCacheableResult && result.isReportable` — a per-result,
  local judgment — not on the run's own final integrity verdict.
- **`MutationResult`** (`Sources/MutationModel/MutationResult.swift:52`) is a
  plain struct combining an arbitrary `MutationOutcome` with an arbitrary
  `MutationEvidence?`. Nothing in the type prevents constructing
  `.survived` with `nil` evidence, or `.killedByAssertion` with evidence
  for a different mutation point — `isReportable`/`IntegrityChecker` catch
  some of these *after the fact*, but the type itself permits them, so
  every consumer that touches a `MutationResult` (classifier, cache,
  checkpoint, reporter) has to independently trust that whoever
  constructed the one it received already checked.

This is the pattern: the same question — "is this result real?" — is
answered by up to four different pieces of code (`ResultClassifier`/
`SchemataResultClassifier`, `IntegrityChecker`, `MutationResultCache`,
whatever reporter reads `MutationResult` last), each checking a different
subset of the real invariant, none checking all of it, and none able to see
what the others already decided. ADR-0004 fixed several concrete instances
of this (the `.noCoverage` contradiction in Stage 3, the evidence-union type
in Stage 1). It did not change the shape that keeps producing new instances.
Stage 10's two flagged gaps (evidence-attachment coupling enforced only by a
doc comment; cache reuse's undetected-non-determinism bet) are both this
same shape, deferred rather than fixed, because the code they depend on
(the real `MutationRunner` integration, the real build orchestrator) did not
exist yet to design against.

It exists soon. Before building it, or the next runtime/operator/Xcode
extension on top of the current shape, this ADR proposes changing the shape
itself: one type that only a single verifier can construct, so "was this
checked" becomes a fact the type system enforces rather than a convention
every consumer has to re-trust.

## Decision

Introduce a `VerifiedMutationVerdict` type that is the *only* form a result
can take once it is eligible for scoring, caching, checkpointing, or
reporting — constructible only by a single `MutationVerdictVerifier`, never
by a public initializer. Everything upstream of verification (build output,
test output, source-application proof, runtime proof, coverage proof) stays
a separate, unverified `RawMutationAttempt`. Downstream consumers stop
re-deriving trust from evidence internals and instead trust the type.

### 1. Split raw attempt from verified verdict

```swift
struct RawMutationAttempt {
    let point: MutationPoint
    let build: BuildObservation?
    let test: TestRunResult?
    let sourceProof: SourceApplicationProof?
    let runtimeProof: RuntimeProof?
    let coverageProof: CoverageProof?
}

struct VerifiedMutationVerdict: Codable, Sendable {
    let mutationRef: PlannedMutationRef
    let outcome: MutationOutcome
    let proof: VerdictProof
    let verificationVersion: Int
}

enum VerdictProof {
    case executed(ExecutedMutationProof)
    case noCoverage(NoCoverageProof)
    case unviable(BuildFailureProof)
    case excluded(ExclusionProof)
}
```

`VerifiedMutationVerdict`'s initializer is `internal`, callable only from:

```swift
MutationVerdictVerifier.verify(_ attempt: RawMutationAttempt, against: VerificationContext) -> VerifiedMutationVerdict
```

Report, score, checkpoint, and cross-run cache accept only
`VerifiedMutationVerdict` — never `RawMutationAttempt`, never a
free-standing `MutationOutcome`/`MutationEvidence` pair.

### 2. Bind every proof to a full planned-mutation reference, not just a MutationID

Today, result/plan reconciliation is mostly by `MutationID` set membership
(`IntegrityChecker.check`'s `plannedIDs`/`resultIDs` sets). Nothing confirms
`result.point`, the source hash a proof was taken against, and a schemata
embedding's own mutation ID all describe the *same* mutation content, only
that some `MutationID` exists on both sides.

```swift
struct PlannedMutationRef: Codable, Hashable {
    let planID: String
    let workUnitID: String
    let mutationID: MutationID
    let pointDigest: String
}
```

`pointDigest` is a full SHA-256 over a canonical encoding of: file,
`utf8Range`, original text, replacement text, source-file hash, operator
ID/version, enclosing declaration, execution mode.

Every proof type carries a `PlannedMutationRef`. The verifier's core
invariant:

```text
result.mutationRef
== plan.mutationRef
== sourceProof.mutationRef
== schemataEmbedding.mutationRef
== runtimeSelection.mutationRef
== coverageProof.mutationRef
```

Any mismatch is `.infrastructureFailure` — never scored, never cached.

### 3. Make `.noCoverage` its own proof, not an absence

ADR-0004 Stage 3 already added a *contradiction* check (verified hit +
coverage-miss ⇒ `.infrastructureFailure` instead of `.noCoverage`), which
this item subsumes rather than replaces. What Stage 3 did not add is a
positive proof for the coverage-miss fast path itself: today `.noCoverage`
is reached by *absence* of activation evidence, not by a proof that the
absence is the honest, coverage-tool-confirmed reason.

```swift
struct NoCoverageProof {
    let mutationRef: PlannedMutationRef
    let sourceApplication: SourceApplicationProof
    let coverageProfileID: String
    let coverageToolVersion: String
    let originalLocation: SourceLocation
    let profileSourceHash: String
    let testSelectionDigest: String
}
```

Classification rule, stated as a decision table so it is one thing the
verifier owns rather than logic re-derived at each classify call site:

```text
build/load/select/hit proof, tests pass         → survived
build/load/select proof, no hit, coverage-miss proof → noCoverage
hit proof + coverage-miss                       → infrastructureFailure  (already Stage 3)
coverage-miss with build/load/select unresolved  → infrastructureFailure
```

The isolated-mode pre-build coverage fast path issues a `NoCoverageProof`
that does not require build/load/select proof (none was attempted, by
design). The schemata path requires a startup event
(`provesLoadedAndSelected`, from ADR-0004 Stage 3) before `.noCoverage` is
available at all — a schemata mutant that never even loaded is
`.infrastructureFailure`, not `.noCoverage`.

### 4. Narrow `IntegrityChecker` to reconciliation only

`IntegrityChecker.unactivatedScorableResultViolations` currently re-derives
an activation judgment from evidence internals — the same judgment
`ResultClassifier`/`SchemataResultClassifier` already made once. Once
`MutationVerdictVerifier` is the only path to a `VerifiedMutationVerdict`,
that re-derivation has no work left to do: a `VerifiedMutationVerdict`
cannot exist without having already passed it.

```text
MutationVerdictVerifier
  owns: is this one result trustworthy — outcome and proof decided together.

IntegrityChecker
  owns: does the *set* of verified verdicts reconcile against the plan —
  counts, duplicates, coverage of every planned mutation. No evidence
  interpretation.

MutationResultCache
  accepts only VerifiedMutationVerdict. Does not re-derive isReportable
  or isCacheableResult from outcome/evidence — those are already-verified
  facts on the type it was handed.
```

`unactivatedScorableResultViolations` is deleted, not weakened: its job
moves into the verifier, where it is not a defense-in-depth re-check but
the actual, only judgment.

### 5. Verify before persisting, not after

Fix the ordering bug named in Context directly: nothing reaches
`MutationResultCache`/checkpoint storage before verification, and
verification happens per-attempt, so there is no "verify the whole run,
then it's too late" step to get the ordering wrong at.

```text
RawMutationAttempt → MutationVerdictVerifier.verify → VerifiedMutationVerdict → checkpoint / cache / report
```

Resume needs raw, pre-verification state for an interrupted attempt; that
lives in a separate store, never scored:

```text
attempt-checkpoint/        re-run input only, never contributes to a score.
verified-verdict-cache/    verifier output only, safe to reuse across runs.
```

Cache records carry the verifier's own version so a rule change invalidates
old entries automatically:

```swift
struct VerifiedVerdictReceipt {
    let verdict: VerifiedMutationVerdict
    let verificationVersion: Int
    let verifierDigest: String
    let executionContextDigest: String
}
```

A stale `verificationVersion` (or `verifierDigest`, covering a change to the
verifier's own logic without a version bump) is a cache miss. This replaces
the current convention of manually bumping a cache-namespace string
(`resultCache2`-style) when cache-trust rules change.

### 6. Runtime evidence: exactly two events

ADR-0004 Stage 2 already built the startup/hit split this item assumes;
this item only fixes it at exactly two events and stops the runtime
protocol from growing further ad hoc fields:

```text
STARTUP: protocol version, run ID/nonce, final artifact ID, manifest ID,
         selected token, PID, image UUID, runtime ABI
HIT:     run ID/nonce, selected token, hit token, PID, image UUID, sequence
```

No host-side PID prediction (Xcode's `xctest` is an unobserved descendant
of `xcodebuild` — Stage 2 already established this cannot work). The
verifier's chain: plan entry → source-embedding manifest → final-artifact
manifest → STARTUP → HIT → test result.

### 7. Build graph: multi-target from the start

`SchemataChunkPlanner`'s `targetInfo` is already `[String: [SchemataTargetInfo]]`
(ADR-0004 Stage 4) but multi-membership still falls back to isolated mode
rather than embedding into every target. This item is the eventual
embedding work Stage 4 explicitly deferred, modeled as a real many-to-many
graph rather than retrofitted onto a one-file-one-target map later:

```swift
struct SourceCompilationMembership {
    let sourceID: String
    let compilationUnits: [CompilationUnitID]
}

struct CompilationUnitID: Codable, Hashable {
    let projectID: String
    let targetGUID: String
    let configuration: String
    let platform: String
    let architecture: String
    let productID: String
}
```

Chunk, plan entry, and artifact manifest all carry `CompilationUnitID`
directly — no target name or project path re-guessed by a build
orchestrator later.

## Implementation order

Six stacked PRs, each independently reviewable, same discipline ADR-0004
used (review → fix → verify end-to-end → merge one stage at a time). New
operator work, runtime extension, and Xcode integration work pause until
PR A and B land, since both change the type every later consumer depends on.

```text
A. refactor/verified-verdict-model
   RawMutationAttempt, VerifiedMutationVerdict, PlannedMutationRef, VerdictProof.
   No behavior change yet — isolated-mode classify path adapted to produce
   the new type via a verifier that, for now, reproduces existing decisions.

B. refactor/central-verifier
   MutationVerdictVerifier for real; isolated-mode path migrated fully;
   IntegrityChecker narrowed to reconciliation-only (item 4).

C. refactor/verified-persistence
   Verified checkpoint/cache split (item 5); verifier-version auto-invalidation;
   legacy cache entries discarded, not migrated.

D. feature/coverage-proof
   NoCoverageProof (item 3); repairs the two pre-existing
   SwiftPackageMacOSCoverageAcceptanceTests failures ADR-0004 Stage 1 found
   and explicitly left uninvestigated.

E. feature/schemata-startup-hit-protocol
   Runtime event v2 (item 6, tightened from ADR-0004 Stage 2) and the real
   final-artifact manifest producer ADR-0004 Stage 6 found had no caller yet.

F. feature/compilation-unit-membership
   Multi-target embedding (item 7), replacing the Stage 4 fallback.
```

## PR A: the verified-verdict model, additive

**What changed.** Four new types landed in `MutationModel`, none yet called
from `MutationRunner`:

- `PlannedMutationRef` (`Sources/MutationModel/PlannedMutationRef.swift`) —
  `planID`/`workUnitID`/`mutationID` plus `pointDigest`, a SHA-256 over a
  canonical JSON encoding (`MutationPlan.encoder()`, already used for plan
  files — reused rather than inventing a second canonical encoder) of
  exactly the fields item 2 named: file, UTF-8 range, original/replacement
  text, source-file hash, operator ID/version, enclosing declaration path,
  execution mode. Deliberately excludes `line`/`column` (display-only) and
  the anchor token fingerprints (derived from, not independent of, the
  included fields) — a moved-but-otherwise-identical mutation keeps the
  same digest, a same-location mutation with different replacement text
  does not.
- `VerdictProof` (`Sources/MutationModel/VerdictProof.swift`) — `.executed`/
  `.noCoverage`/`.unviable`/`.excluded`, each wrapping a proof struct that
  reuses the existing `MutationEvidence`/`TestOutcomeSummary` types rather
  than inventing parallel ones. `NoCoverageProof` today carries only
  `mutationRef` and `sourceApplication` — item 3's positive-proof fields
  (coverage profile ID, tool version, etc.) are explicitly PR D's job, not
  fabricated here ahead of a real producer, the same restraint ADR-0004
  applied to items 6/8/9.
- `RawMutationAttempt` (`Sources/MutationModel/RawMutationAttempt.swift`) —
  the pre-verification input: a point, a candidate outcome (today's
  classifier output, unchanged), evidence, test summary, diagnosis. Not
  `Codable`: in-memory only for now, per-run; PR C is where a persisted,
  pre-verification checkpoint shape gets designed.
- `VerifiedMutationVerdict` (`Sources/MutationModel/VerifiedMutationVerdict.swift`)
  — `mutationRef`/`outcome`/`proof`/`verificationVersion`. Declares no
  explicit initializer at all: because the type is `public` with no custom
  `init`, Swift synthesizes only the *implicit* memberwise initializer,
  which is `internal` — construction is possible only from within
  `MutationModel`. (An explicit `internal init` was tried first and
  rejected by `swiftformat`'s `redundantMemberwiseInit` rule for exactly
  this reason: it duplicated what the compiler already provides for free.)

`MutationVerdictVerifier` (`Sources/MutationModel/MutationVerdictVerifier.swift`,
same module, so it can call the implicit init) is the only call site:
`verify(_:planID:workUnitID:)` builds a `PlannedMutationRef` from the
attempt's point and picks a `VerdictProof` case matching
`candidateOutcome`'s shape — `.killedByAssertion`/`.killedByCrash`/
`.verifiedTimeout`/`.survived` with evidence → `.executed`; the same four
with no evidence → `.excluded` (a fabricated `.executed` proof with nothing
behind it would be worse than admitting no strong proof exists — the
existing pipeline's own `IntegrityChecker.phantomMutant` check already
catches this exact combination today); `.noCoverage` with evidence →
`.noCoverage`; `.unviable` → `.unviable`; everything else (`.skipped`,
`.notApplied`, `.baselineMismatch`, `.timedOut`, `.flaky`,
`.infrastructureFailure`) → `.excluded`. `currentVersion = 1` is the seed
for PR C's cache-invalidation gate.

**What did *not* change.** `MutationRunner`, `ResultClassifier`,
`SchemataResultClassifier`, `IntegrityChecker`, `MutationResultCache` —
nothing production-facing calls any of this yet. This stage is scoped
exactly as the table above states: establish the type and its exclusive
construction path, prove it reproduces today's classification shape
correctly in isolation, and stop there. PR B is where `MutationRunner`'s
isolated-mode path actually migrates to call it.

**Verified:** full unit suite (950 tests, including 13 new in
`MutationVerdictVerifierTests.swift` — `pointDigest` determinism and its
reaction to each claimed field, indifference to display-only fields, and
the verifier's outcome-to-proof mapping across every `MutationOutcome`
case), `swiftformat --lint` clean, `swiftlint --strict` clean. No
acceptance suite exercises this stage (nothing in the real pipeline calls
it yet, by design).

## PR B: the isolated-mode classify path routes through the verifier

**Scope, narrowed from the original plan.** The ADR's PR B description
above also named "IntegrityChecker narrowed to reconciliation-only (item
4)." That narrowing is deferred: `IntegrityChecker
.unactivatedScorableResultViolations` is still the only defense-in-depth
check protecting the schemata path (`SchemataMutationRunner` is untouched
by this stage — only isolated mode migrates here), so removing it now would
weaken schemata-mode integrity checking for no gain. It gets removed once
the schemata path also migrates to the verifier, not before.

**What changed.** `MutationRunner.swift` gained one private method,
`verifiedResult(point:outcome:evidence:testSummary:diagnosis:
durationSeconds:buildDurationSeconds:testDurationSeconds:
confirmationDurationSeconds:)`, which wraps its arguments in a
`RawMutationAttempt`, calls `MutationVerdictVerifier.verify(_:planID:
workUnitID:)` (`workUnitID` is `plan.planID` — this runner has no narrower
work-unit concept than the plan/shard it was handed), and returns a
`MutationResult` built from the resulting `VerifiedMutationVerdict`.

Two call sites were migrated to it — not all ten `MutationResult(...)`
construction sites the file has. Reading the file found only two real
*classification* choke points: `prepare(...)`'s local `finished(...)`
closure (every outcome that does not need a test run — anchor mismatch,
`.noCoverage`, a build failure — and the shared entry point every other
classification funnels through via its own `infrastructureFailure(...)`
helper) and `finishAfterTest(...)` (every outcome that follows a real test
run — killed, survived, timed out, flaky — shared identically by the plain,
batched, pipelined, and wave-based-early-kill paths per its own doc
comment: "`run` may have come from `runMutantTests` ... or from a batch —
this function does not know or care which"). Migrating these two covers
every mutant `ResultClassifier` ever actually classifies, across every
execution mode this file supports, in one change.

The other ~8 `MutationResult(...)` sites (line ~308's "no persistent
incremental-build sandbox," line ~1856's "no sandbox for this mutant," line
~1892's "the mutant's tests could not be run," and their batch/pipelined
counterparts) are pre-classification infrastructure failures: a sandbox
never existed, or tests never launched, so there is no `ResultClassifier
.Classification` for the verifier to sit in front of — these already hardcode
`.infrastructureFailure` with no judgment to verify. Left as direct
`MutationResult(...)` construction; routing them through the verifier too
would add churn with no real proof to attach, since `RawMutationAttempt`
has no build/test data at all at these call sites.

`MutationVerdictVerifier.verify`'s outcome always equals its input
`candidateOutcome` (PR A's design — see that stage's write-up), so this
change is behavior-preserving by construction: every mutant scores exactly
as it did before. What changed is structural — it is no longer possible
for the isolated-mode classify path to hand a classification straight to
`MutationResult` without it passing through
`MutationVerdictVerifier` first.

**Housekeeping found along the way.** `swiftlint --strict --baseline` failed
after this change — not on anything new, but because `MutationRunner.swift`
was already over both the `file_length` (2700 lines) and `type_body_length`
(1500 lines) thresholds before this stage, and `.swiftlint-baseline.json`
keys those two rules on exact line number and violation text (see
`.swiftlint.yml`'s own comment on this fragility). Adding ~50 lines shifted
both past what the baseline recognized. Regenerated with `swiftlint lint
--write-baseline .swiftlint-baseline.json Sources Tests` (explicit paths —
the default recursive scan also picked up stray, gitignored
`.claude/worktrees/` directories left over from earlier agent sessions on
this machine, which are not part of the repository and would have polluted
the committed baseline with irrelevant entries) and diffed
programmatically against the prior baseline to confirm the multiset of
`(rule, file)` violations was unchanged — only line numbers and violation
counts moved, nothing genuinely new got swept in unnoticed.

**Verified:** full unit suite (950 tests, unchanged pass count — this stage
does not add new tests of its own, since `MutationVerdictVerifierTests`
already covers the verifier and this stage does not change its behavior),
`swiftformat --lint` clean, `swiftlint --strict --baseline` clean against
the regenerated baseline.

## PR C: verified-verdict cache gating (checkpoint split deferred)

**Scope, narrowed from the original plan.** Item 5's full design (a
separate, never-scored `attempt-checkpoint/` store distinct from the
verified-verdict cache) is deferred: `CheckpointStore` is untouched by this
stage. Checkpoints are same-run-only and already scoped to one exact
`RunContextFingerprint` — the specific risk item 5 names (a verdict bound to
a `runNonce`/`processID` that stops meaning anything once that process
exits) is a *cross-run* reuse risk, which only the cache faces. Splitting
checkpoint storage too, with no concrete case yet showing it needs the same
treatment, would be exactly the speculative-abstraction risk ADR-0004
(items 6, 8, 9) and this ADR's own PR A (`NoCoverageProof`) already declined
for the same reason.

**What changed.** `MutationResultCache.store` gained a required
`verificationVersion: Int` parameter — not optional, so a future call site
cannot forget to stamp it. `CacheRecord` carries it, and `load` now checks
`record.verificationVersion == MutationVerdictVerifier.currentVersion`
before serving a hit; any mismatch is treated exactly like a miss (falls
through to `nil`, the same fail-closed path a corrupted file already takes).
A record written before this field existed decodes it via `decodeIfPresent`
to `CacheRecord.unknownVerificationVersion` (`-1`, which can never equal a
real version, since `MutationVerdictVerifier.currentVersion` starts at `1`
and only increases) — a legacy record is discarded, not migrated, exactly
as item 5 specified. This replaces the previous convention (never actually
used in this codebase, but named explicitly in `.swiftlint.yml`'s own
comment about a different manual-bump pattern, and in ADR-0005's own
Decision section) of hand-bumping a cache-namespace string whenever
cache-trust rules changed — a version bump to `MutationVerdictVerifier
.currentVersion` now invalidates every existing cache entry automatically.

The only production call site (`MutationRunner.run()`'s cache-store loop)
passes `MutationVerdictVerifier.currentVersion` directly, not a value
threaded through `MutationResult` itself: every cacheable outcome in
isolated mode already came from `verifiedResult` (PR B), so "this run's
current verifier version" is always the correct stamp — there is no
scenario where a cacheable result exists that did not just pass through
`MutationVerdictVerifier.verify`.

**Verified:** full unit suite (952 tests — 2 new: a superseded-version
record is a miss, and a hand-encoded legacy record with no
`verificationVersion` key at all is a miss), `swiftformat --lint` clean,
`swiftlint --strict --baseline` clean (baseline regenerated again, same
line-shift-only procedure as PR B — diffed to confirm the `(rule, file)`
multiset was unchanged before adopting it).

## PR D: NoCoverageProof gains a real field, and a real defect gets fixed

**The actual bug, found by running the acceptance suite ADR-0004 Stage 1
left uninvestigated.** `IntegrityChecker.unactivatedScorableResultViolations`
flagged `.noCoverage` outcome, always — every one of them. `.noCoverage` is
`isScorable`, but by design the coverage fast path (`MutationRunner
.prepare`) never builds, so it never has application evidence to offer;
the check read that absence as "unproven activation" rather than "this
outcome doesn't need activation evidence in the first place." That made
`integrity.passed` false on any run with a `.noCoverage` mutant, which is
exactly why `SwiftPackageMacOSCoverageAcceptanceTests`'s "Integrity
reconciles across the coverage fast path" and "Effective score is stable;
Tested score improves with noCoverage" failed — not flakily, but on every
run, confirmed by running both with `MUTANTKIT_ACCEPTANCE=1` before
touching anything. `MutationRunner.prepare`'s own fast-path comment already
promised the behavior the code didn't deliver: "`isReportable` is satisfied
by the source diff alone, and `noCoverage` is not flagged by the activation
check" — a real, previously undelivered invariant, now actually true.

**The fix.** `unactivatedScorableResultViolations`'s loop now excludes
`result.outcome == .noCoverage` outright. `isReportable` still gates it —
a `.noCoverage` result with no proof the mutation even reached the source
is still `.phantomMutant` — only the activation-evidence requirement is
lifted, and only for this one outcome.

**`NoCoverageProof` gains `coverageSource: String?`** — the one positive
fact this codebase's coverage readers actually produce
(`CoverageObservation.source` in `MutationExecution`, e.g.
`"swift-package-codecov"`), mirrored as a plain `String` rather than
depending on that type directly (`MutationModel` cannot depend on
`MutationExecution`). `RawMutationAttempt` gained the same field, threaded
from `MutationRunner.prepare`'s coverage-fast-path `observation?.source`
through `verifiedResult`. The richer fields item 3 originally sketched
(coverage profile ID/tool version, original location, profile source hash,
test-selection digest) stay un-invented — no coverage reader in this
codebase produces any of them, so adding fields with no real producer would
be the same speculative-abstraction risk ADR-0004 (items 6, 8, 9) already
declined.

**Verified:** full unit suite (955 tests — 3 new: the Integrity fix's
positive case, and two on `NoCoverageProof.coverageSource` — threaded when
present, `nil` and not fabricated when absent), `swiftformat --lint` clean,
`swiftlint --strict --baseline` clean (baseline regenerated a third time,
same diffed-line-shift-only procedure). Both previously-failing acceptance
tests now pass (`MUTANTKIT_ACCEPTANCE=1 swift test --filter
SwiftPackageMacOSCoverageAcceptanceTests`, all 5 green), and the full
non-coverage `SwiftPackageMacOSAcceptanceTests` suite (7 tests) still
passes, confirming the `.noCoverage` exclusion did not weaken the check for
any other outcome.

## Schemata-path migration to the verifier (unblocks, but does not itself
complete, the deferred IntegrityChecker narrowing)

**What changed.** `SchemataMutationRunner` gained a required `planID:
String` (threaded from `context.plan.planID` at its one production call
site, `SchemataRunOrchestration.runSchemataPortion`). Its one real
classification choke point — `runEntry`'s tail, immediately after
`ResultClassifier.classifySchemata(...)` — now routes through a
`verifiedResult` helper mirroring `MutationRunner`'s own (PR B) exactly:
wrap in `RawMutationAttempt`, call `MutationVerdictVerifier.verify`, build
`MutationResult` from the outcome it returns. `failureResult` (pre-
classification sandbox/build/test-launch failures with no
`ResultClassifier.Classification` to verify) is untouched, the same
scoping PR B used for isolated mode's equivalent early exits. Both
production and schemata-execution paths in this codebase now construct
every classified `MutationResult` through `MutationVerdictVerifier` — no
path left that hands a classification straight to `MutationResult`.

**Reconsidering the deferred `IntegrityChecker` narrowing — do not delete
`unactivatedScorableResultViolations` yet.** PR B's write-up said this
check "gets removed once the schemata path also migrates to the verifier,
not before," implying migration alone would make deletion safe. Re-checking
that reasoning while actually landing the schemata migration found it
incomplete: `MutationResult`'s initializer is `public`, with no restriction
at all — any code in this repository (tests do it constantly via
`makeResult(...)`, and any future bug could too) can still construct one
with an arbitrary outcome/evidence pairing that never passed through
`MutationVerdictVerifier`. Migrating both *production* execution paths
closes the gap for results a real run produces, but `MutationResultCache`
and `CheckpointStore` reuse whatever `MutationResult` they are handed
regardless of how it was constructed — so `unactivatedScorableResultViolations`
still catches a corrupted, hand-crafted, or wrongly-constructed
`MutationResult` reaching either store, a class of bug migration alone does
not close. Item 4's full plan (only `VerifiedMutationVerdict` reaches
persistence, `MutationResult` becomes a report-only derived view) is what
would actually let this check retire — that view was deliberately
descoped from PR B/C (both explicitly narrowed to avoid the larger
Reporting-layer rewrite; see PR B's own write-up), so the check it would
retire stays in place until that larger change happens, not before. This
corrects PR B's own stated deferral condition rather than blindly following
it now that the precondition it named is technically true.

**Housekeeping found along the way.** `SchemataRunOrchestrationAcceptanceTests`
fails identically on unmodified `main` (confirmed with `git stash` before
attributing the failure to this change) — a real `mutantkit` subprocess
spawned through the CLI reports `"the chunk build could not be run:
schemata execution requires MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE..."`
even with that variable set in the parent test process's environment,
unlike `SchemataMutationRunnerAcceptanceTests` (in-process, same variable,
passes cleanly). A pre-existing environment/subprocess-inheritance issue,
not investigated further here — out of this stage's scope, and not a
regression this stage introduced.

**Verified:** full unit suite (955 tests, unchanged pass count — this
stage's behavior is a pure structural reroute, like PR B), `swiftformat
--lint` clean, `swiftlint --strict --baseline` clean (no baseline shift
this time). Real end-to-end verification: `MUTANTKIT_ACCEPTANCE=1
MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE=.build/arm64-apple-macosx/debug
swift test --filter SchemataMutationRunnerAcceptanceTests` — the real
SwiftPM schemata backend, a real build, a real killed and a real survived
mutant, both routed through the verifier — passes.

## PR E: the runtime observes its own image UUID (not yet wired into the trust decision)

**The gap, precisely.** `SchemataMutationRunner.embeddingEvidence`'s own
comment already named it: "no adapter can yet extract a real per-image UUID
from a SwiftPM build product... [so] the artifact's own product hash
[`manifestHash`]" stands in for it, on *both* sides —
`SchemataEmbeddingEvidence.imageUUIDs` (the expected value, computed before
the process ever runs) and `SchemataActivationEvidence.imageUUID` (what the
running process reported) were literally the same host-supplied value
passed to two different fields in one function call. `provesInternalConsistency`'s
`embedding.imageUUIDs.contains(activation.imageUUID)` check could therefore
never fail — not because the images genuinely matched, but because both
sides were set from an identical local variable, self-consistent by
construction rather than by any real cross-validation. ADR-0004 Stage 2
flagged this directly: "`schemaArtifactID`/`imageUUID` remain host-supplied,
not yet runtime-observed."

**What changed — the runtime half.** `mutantkit_schemata_runtime.c` gained
`mutantkit_compute_image_uuid`: `dladdr` on a function pointer inside the
runtime's own translation unit finds which Mach-O image contains this
code (the standard "which image am I actually running in" technique —
correct for a statically-linked runtime regardless of whether it ends up
in a test executable, a framework, or an XCTest bundle, unlike assuming
"the main executable"), then walks that image's load commands for
`LC_UUID` and hex-encodes its 16 bytes. Computed once, in the
`mutantkit_startup` constructor (before the startup event is written),
cached in a static buffer used by both event writers. Empty string, not a
fabricated value, when no `LC_UUID` is found (an unsigned or hand-linked
image) or the header/`dladdr` call fails — the same "unknown stays
unknown" discipline every other honesty-over-completeness field in this
runtime already follows.

**Protocol version, and the new line formats.** Both STARTUP and HIT lines
gained a leading `protocolVersion` field (`MUTANTKIT_PROTOCOL_VERSION = 2`)
and an `imageUUID` field, placed *before* `runNonce` (which must stay last:
it can contain any character but a newline, so it is always "everything
after the last known field," and the image UUID would otherwise be
swallowed by an unusually-shaped nonce):

```text
STARTUP: <protocolVersion>:<namespace>:<localIndex>:<pid>:<imageUUID>:<runNonce>
HIT:     <protocolVersion>:<namespace>:<localIndex>:<pid>:<eventSequence>:<imageUUID>:<runNonce>
```

`SchemataEvidenceCollector.parseHits`/`parseStartupEvents` check the first
field against the host's own `protocolVersion` constant and throw a new
`ParseError.unsupportedProtocolVersion` case on any mismatch, rather than
misinterpreting a reordered or added field as something else — the belt-
and-suspenders check named in the C runtime's own new doc comment, for the
case where a stale prebuilt `libMutantKitSchemataRuntime.a` ends up linked
against a newer host or vice versa (both build from the same package
normally, so this is not a real migration path, just a loud failure mode
instead of a silent misparse).

**What deliberately did NOT change: `SchemataActivationEvidence.imageUUID`
still comes from the host-supplied placeholder, not the newly-parsed
`StartupEvent.imageUUID`.** Wiring only this one side in would make
`provesInternalConsistency` check the real runtime-observed image UUID
against `embedding.imageUUIDs`, which is still `[manifestHash]` — a
content hash, not a linker-generated `LC_UUID`. Those two values have no
reason to ever coincide, so wiring only the runtime-observed half in now
would flip every schemata result's `provesInternalConsistency` to `false`,
breaking scoring for the entire backend. The real fix needs the other half
too: reading the actual built test executable's own `LC_UUID` from disk
(a build-time fact, deterministic per link, knowable right after
`buildSchemataChunk` finishes — no need to wait for the runtime to report
it) to populate `embedding.imageUUIDs` with something the runtime's
observation could genuinely be checked against. That is real, additional
work — parsing a Mach-O file's load commands from Swift, locating the
right binary inside the build output, threading it through
`embeddingEvidence` — deliberately out of scope for this stage. `StartupEvent
.imageUUID`/`RawHit.imageUUID` are real, parsed, and available to a future
caller; nothing consumes them into a trust decision yet, the same
restraint PR A applied to `NoCoverageProof`'s un-invented richer fields.

**Verified:** full unit suite (959 tests — 4 new: an image-UUID field
parses and round-trips in both hit and startup lines, empty when absent,
and a mismatched `protocolVersion` is rejected in both line kinds),
`swiftlint --strict --baseline` clean (no shift), `swiftformat --lint`
clean on the Swift side (`.c` files are outside its scope — no C formatter
is configured in this project). Real end-to-end verification against a
freshly rebuilt `libMutantKitSchemataRuntime.a` (deleted and rebuilt before
testing, so no stale pre-PR-E archive could mask a build failure):
`SchemataSwiftPMRuntimeAcceptanceTests` (3 tests — real chunk compile/link/
activate, including the stale-nonce-rejection test) and
`SchemataMutationRunnerAcceptanceTests` (the full baseline+chunk+per-mutant
run against a real, MutantKit-unaware `Package.swift`) both pass with
`MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` pointed at the rebuilt archive.

## PR F: multi-target embedding, with a product decision on merge semantics

**The product question, resolved before writing any code.** ADR-0004
Stage 4 made a multi-target file's memberships representable
(`SchemataTargetInfo`'s caller maps one file to a list, not one) but never
embeddable — each fell back to isolated mode, with `SchemataUnsupportedReason
.multipleTargetsNotYetSupported` explaining why. Actually embedding into
every target raised a question this ADR's original sketch never answered:
one `MutationID`, compiled into N targets, runs and classifies
independently in each — how do N independent verdicts collapse into the
one result every downstream consumer (`RunReport`, `IntegrityChecker`,
scoring) requires? Asked directly: **killed in any target counts as
killed.** A mutation fragile in even one compiled target is a real gap in
that target's own test suite; a target where it happened to be harmless
does not erase that.

**The persisted-plan schema redesign this required.** `SchemataPlan
.decodeAndValidate` has always rejected more than one entry per
`MutationID` (`ValidationError.duplicateEntry`) — a real, deliberate
invariant, not an oversight. Embedding one mutation into N targets without
violating it meant `SchemataPlacement.embedded` had to carry a *list* of
placements, not one flat set of fields:

```swift
public enum SchemataPlacement: Codable, Sendable, Hashable {
    case embedded(placements: [SchemataEmbeddedPlacement])
    case isolatedFallback(reason: SchemataUnsupportedReason)
}

public struct SchemataEmbeddedPlacement: Codable, Sendable, Hashable {
    let chunkID: String
    let selectorToken: SchemataSelectorToken
    let sourceEmbeddingID: String
    let lowererID: String
    let lowererVersion: Int
    let projectIdentity: String
    let target: String
    let module: String
    let product: String
    let expectedImages: [String]
}
```

`SchemataPlanEntry` dropped its own `expectedImages` field (moved into each
placement — a shared value made no sense once each placement can be a
different target's own build) and its `chunkID`/`selectorToken`/
`sourceEmbeddingID`/`lowererID`/`lowererVersion` accessors became
"first placement's own value" — correct and unambiguous for a lowerer's
own single-placement, pre-merge output (which is all `SchemataMutationRunner
.runEntry` ever consumes, per-chunk, unchanged by this stage), with the
full per-target detail available via `.placements` for the one caller that
actually needs it. `SchemaVersion.schemataPlan` bumped 1 → 2: a plan
written under the old shape cannot decode against the new type, by design.

**Where the merging actually happens.** `SchemataChunkPlanner.classify`
no longer requires exactly one target membership — a point eligible for
embedding (eligibility depends only on point/source content, never on
target) is added to *every* target's own group, producing one
single-placement entry per target from independent `lower(...)` calls
(each chunk is still one target's own build, chunked and namespaced
entirely on its own). `SchemataPlanEntry.merged(_:)` then collapses a
mutation's several single-placement entries into the one multi-placement
entry the persisted plan requires, before `SchemataPlan` is built.
`SchemataUnsupportedReason.multipleTargetsNotYetSupported` is deleted, not
deprecated — it can no longer occur.

**Where the scoring merge happens.** `SchemataMutationRunner
.mergeMultiTargetResults` (a `static` pure function on `[MutationResult]`,
deliberately not `private` — see below) collapses same-`MutationID`
results by the resolved policy: kill outcomes rank highest, then
`.survived`, then `.noCoverage`, then `.unviable`, then the
environmental/indeterminate outcomes, `.infrastructureFailure` lowest.
Ties keep whichever result appears first, a deterministic pick independent
of target name. A merged result's diagnosis notes how many targets
contributed, so a report reader can tell a genuinely single-target verdict
from a collapsed multi-target one.

**Scope simplification from the ADR's original sketch.** The Decision
section above (item 7) sketched a `CompilationUnitID` type
(`projectID`/`targetGUID`/`configuration`/`platform`/`architecture`/
`productID`) as the eventual multi-target identity. Nothing that granular
was built — this stage reuses the existing `SchemataTargetInfo`
(`projectIdentity`/`target`/`module`/`product`) throughout, which was
already sufficient to keep every target's embedding distinct and was
already the type every call site in this codebase speaks. Recorded here
rather than silently diverging from the sketch: `CompilationUnitID`
remains a real idea for whenever configuration/platform/architecture
actually need to be distinguished within one project/target pair (multiple
destinations building the same target, say), not something this stage
needed or built.

**What was NOT built: a real multi-target acceptance fixture.** No new
Xcode/SwiftPM project fixture with genuinely shared, multi-target source
exists in `Fixtures/` — building one (plus wiring a real multi-destination
build through `SwiftPMTargetResolver`/an Xcode equivalent) is real,
separate work. Verification here is unit-level: `SchemataChunkPlannerTests`
(two tests rewritten for the new embed-into-every-target behavior, proving
the planner itself groups, chunks, and merges correctly) and the new
`SchemataMutationRunnerMergeTests` (`@testable import`, since
`mergeMultiTargetResults`/`multiTargetRank` are `static` but not `public` —
exercising the rank/tie-break policy directly against synthetic
`MutationResult` values, which needs no real build at all). Every existing
*real*, single-target acceptance suite (`SwiftPackageMacOSAcceptanceTests`,
`SchemataSwiftPMRuntimeAcceptanceTests`, `SchemataMutationRunnerAcceptanceTests`,
`BoolLiteralSchemataCompileViabilityAcceptanceTests`,
`SwiftPackageMacOSSchemataAdapterAcceptanceTests`) was re-run end to end
against a freshly rebuilt runtime and passes unaffected — proving the
schema redesign is behavior-preserving for the case every real fixture
today actually exercises, not that multi-target embedding itself has been
proven against a real multi-target build.

**Verified:** full unit suite (969 tests — 11 new: two rewritten
`SchemataChunkPlannerTests` covering multi-target embedding into every
group and a shared-target sibling-chunk check, nine new
`SchemataMutationRunnerMergeTests` covering the full rank/tie-break/
diagnosis-annotation policy), `swiftformat --lint` clean, `swiftlint
--strict --baseline` clean (one genuine new baseline entry — `SchemataMutationRunner
.swift` crossed `type_body_length`'s 300-line threshold for real, from the
merge logic itself, not a line-shift artifact; confirmed via the same
diffed-multiset procedure before adopting). Real end-to-end acceptance
runs as described above, all green.

## Required negative tests, per PR touching the verifier or persistence

None of these may be skipped or weakened; each maps to a specific gap named
above.

```text
evidence for a different mutant attached           → verifier rejects
same MutationID, point content changed              → verifier rejects
sourceBeforeHash differs from plan                   → verifier rejects
unverified survivor reaches cache storage            → not expressible in the type system
noCoverage without a NoCoverageProof                  → verifier rejects
hit proof + coverage-miss                             → verifier rejects (already Stage 3; re-assert under new type)
stale verificationVersion in cache                    → cache miss
wrong artifact / manifest / image identity             → verifier rejects
one source file, two target memberships                → both manifests retain the mutation
```

## Consequences

Reviewing this pipeline afterward narrows to three questions, replacing
"does every consumer independently re-check the same invariant correctly":

```text
Can MutationVerdictVerifier construct an invalid VerdictProof?
Can any persistence path accept something other than a VerifiedMutationVerdict?
Do runtime/build-graph observations reach the proof correctly?
```

`IntegrityChecker`, `MutationResultCache`, and every reporter stop being
places a new invariant gets added to; they become places that consume a
type already carrying its own proof of trustworthiness. This directly
closes ADR-0004 Stage 10's Gap 1 (evidence-attachment coupling: enforced by
the verifier's exclusive construction path, not a doc comment) and gives
Gap 2 (build-artifact determinism) a concrete home — `VerifiedVerdictReceipt
.executionContextDigest` — rather than leaving it as an open caveat with no
type to attach to.

This is a large, multi-PR change to the pipeline's most load-bearing types.
New operators, runtime extensions, and Xcode integration work pause until
PR A/B land; per this repository's own working discipline, each PR gets its
own review cycle before the next starts, rather than landing as one
large diff.
