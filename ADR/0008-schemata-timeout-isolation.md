# ADR-0008: Schemata-mode per-mutant hang/timeout isolation

- **Status:** Frozen — spec only, ready for future implementation. No
  implementation performed under this ADR. Three-round Codex adversarial
  review: revision 1 (Critical=1/High=3/Medium=2) → revision 2
  (Critical=0/High=1/Medium=3) → revision 3 (Critical=0/High=0/Medium=1,
  final wording fix applied) — see Addenda 1–3. **Amended 2026-08-19,
  post-freeze, by real-corpus evidence — see Addendum 4.** The typed-
  `BuildFailure`-always-becomes-`.unviable` rule in §4(d) and §5 item 8,
  as originally written, is **superseded** for the shared-schemata-chunk-
  build case specifically (unchanged for isolated mode, and unchanged for
  the other three §4(d) failure shapes). Do not implement §4(d)/§5 item 8
  as originally written without reading Addendum 4 first.
- **Date:** 2026-08-15

## Context

The recently-completed Experimental Operator Readiness milestone gave both
`arithmetic-operator-replacement` and `range-boundary-replacement` a
base-operator READY-FOR-SCHEMATA disposition, but both carry a named,
load-bearing, unresolved **schemata-supportability** prerequisite (one of
the milestone's three readiness axes — isolated-readiness,
schemata-supportability, current profile — where schemata-supportability is
explicitly *not* closable by more corpus evidence, only by direct
architecture work). The prerequisite, quoted from
`mutantkit-private-operator-readiness/Research/operator-catalog/phase4-readiness-gate.md`
(read-only, external worktree, for context only):

> "schemata batching (ADR-0003/0004) compiles many real mutants into one
> binary with runtime selectors, so a hanging mutant selected mid-batch
> risks tainting that whole batch's result — the same failure shape that
> originally misclassified 9 isolated-mode mutants under `testBatchSize: 10`
> batching, before the `confirmTimeout` fix. No schemata-specific analogue
> of isolated mode's per-mutant `confirmTimeout`/re-isolation has been
> designed, because no schemata lowerer exists yet for this operator to
> exercise."

That same milestone found hangs are not arithmetic-specific: independently
reconfirmed `verifiedTimeout`s occurred for `nil-coalescing-fallback` and
`assignment-operator-replacement` on the same third-party corpus
(`swift-algorithms`), explicitly framed as "a cross-operator concern, not
an arithmetic-specific one." This ADR treats the problem accordingly: a
general schemata-mode architecture gap, not a per-operator patch.

This ADR is Track B of a two-track effort and does not depend on or
coordinate with the concurrent Track A work. It produces a frozen design
only. Implementation is a separate, future milestone.

## 1. Current Architecture

### 1.1 Process model: fresh subprocess per mutant, shared sandbox per chunk

Schemata mode's process model is precisely characterized, not speculative,
from `Sources/MutationExecution/SchemataMutationRunner.swift`:

- **One sandbox and one compiled build artifact per chunk** (`runChunk`,
  lines ~300–397): `workspaces.createSandbox(id: program.chunkID)` runs
  once, `build.buildSchemataChunk` runs once, then the runner iterates
  `for entry in embeddedEntries { results.append(await runEntry(entry,
  artifact:..., in: sandbox)) }` — sequentially, entry by entry, all
  against the same sandbox and the same compiled binary. The sandbox is
  destroyed once, after the entire chunk finishes (`destroySandbox`, best
  effort).
- **Each entry (`runEntry` → `runSchemataToken`) spawns a brand-new OS
  process.** `SwiftPackageMacOSAdapter.runSchemataToken` calls
  `ProcessSupervisor.run(executable: xcrun, arguments: ["swift", "test",
  "--skip-build", ...], environment: [MUTANTKIT_SCHEMATA_TOKEN: ...,
  MUTANTKIT_SCHEMATA_RUN_ID: ...])` — a fresh `posix_spawn` per mutant, not
  a reused long-lived process with the selector env var changed between
  calls. This is deliberate and documented (`SchemataMutationRunner.swift`
  doc comment): "one fresh test process per embedded mutation" is required
  because `swift test` spawns a `swiftpm-testing-helper` descendant whose
  PID cannot be known in advance, so process identity is proven by a
  per-run nonce (`RunID`), not by process supervision alone. Confirmation
  runs (`confirmSchemataToken`) also always get their own fresh `RunID` and
  process — never reuse the primary run's process.

**Precise answer to "can one hanging mutant contaminate a different
mutant's evaluation":** not via a shared process — there is none — and not
via a shared timeout budget — each `swift test` invocation gets its own
`TimeoutController`-derived limit. The actual shared-state surface is
narrower and specific: **the sandbox filesystem and the compiled build
product are shared across up to `maxChunkSize` (default 200,
`SchemataChunkPlanner.swift:113`) sequential subprocess invocations**, and
schemata mode has no per-entry reset of that shared state between
invocations (see 1.4). A hang cannot corrupt a sibling mutant's *verdict
data* — verdicts are derived per-entry from that entry's own transcript and
`TestRunResult`, and a killed process cannot inject false STARTUP/HIT
records for another mutant's RunID (see 1.3, cardinality/identity checks
are fail-closed). What a hang *can* do to a sibling mutant sharing the
chunk is: (a) consume wall-clock budget serially — chunk evaluation is
sequential, so a hang plus its timeout-then-kill latency (`ProcessSupervisor`
grace period + confirmation re-run, see 1.2/1.3) delays every subsequent
entry in the same chunk, and (b) leave filesystem residue in the shared
sandbox (stray temp files, partially written files from a `SIGKILL`ed
process, locked resources) that the *next* sequential `swift test`
invocation in that sandbox runs against, with no verified-clean-state
guarantee before it starts.

### 1.2 Process supervision: shared by both modes, group-aware, but with a known escape hatch

`Sources/MutationExecution/ProcessSupervisor.swift` and
`Sources/MutationExecution/ProcessTree.swift` are used identically by
isolated and schemata mode — there is no schemata-specific supervision
path. Spawns use `POSIX_SPAWN_SETPGROUP`/`setpgroup(0)` (not
`Foundation.Process`) so the child is a process-group leader the tool can
signal without hitting its own process group. On timeout, the supervisor
snapshots the live descendant tree via `sysctl(KERN_PROC_ALL)` *before*
killing (children reparent to launchd on parent death, losing identifiable
ancestry), then sends `SIGTERM` to the group and every individually-tracked
descendant, waits a grace period, then `SIGKILL`s both. A documented,
measured limitation: `swiftpm-testing-helper` (the process that actually
executes mutated tests) puts itself into a *new* process group, escaping
the parent's group; the descendant-snapshot-plus-individual-kill logic
exists specifically to cover this, but the code comment records an incident
where one escaped grandchild survived a kill with `PPID == 1`, "still
burning half a core" — i.e., termination is best-effort-plus-belt-and-braces,
not a hard kernel guarantee, for this class of process. This is directly
relevant to hang containment: whatever isolation design is chosen must
tolerate "the terminate call returned, but a stray process might still
exist," not assume kill is atomic and total.

### 1.3 Verdict authority and fail-closed timeout classification

`Sources/MutationModel/MutationVerdictVerifier.swift` is confirmed, by its
own doc comment and by ADR-0005/0006, as "the only place a
`VerifiedMutationRecord` is constructed... the only place a mutation's
outcome is decided." `SchemataMutationRunner` collects only raw
observations (`SchemataExecutionObservation`: expectation + build receipt +
unfiltered runtime transcript) and decides nothing.

Fail-closed timeout logic (confirmed to live in `MutationVerdictVerifier`,
not in `TimeoutController.swift` — `TimeoutController` only computes
wall-clock limits from measured baseline duration, it contains no
classification logic):

- A raw `.timedOut` observation is never directly trusted as a kill.
  `confirmationRequirement` requires a `.confirmTimeout` re-run when policy
  says so.
- `confirmTimeout`: if the confirming re-run itself times out, the result
  is `.verifiedTimeout` only if the confirming run's own activation
  evidence proves the mutation was built/selected/hit
  (`unprovenActivation(...) == nil`). If the confirming re-run instead
  resolves normally, the **load-bearing fail-closed line** is: `guard
  original.decidingRun?.status == .timedOut, original.decidingRun?
  .isBatchAttributedTimeout == true else { return .flaky }` — the
  confirmation's own self-reported `wasBatchAttributed` flag is
  deliberately never trusted, only the *original* run's independently
  observed flag, specifically to prevent a corrupted/hand-edited
  confirmation record from turning a should-stay-`.flaky` result into a
  false kill.
- Schemata mode structurally never reaches the batch-attributed-timeout
  cascade at all today: it never batches (one fresh process per embedded
  mutation), so `isBatchAttributedTimeout` is always `false` for a
  schemata-mode primary timeout. Consequence, proven by an existing test
  (`SchemataConfirmationVerifierTests
  .timeoutConfirmationFinishingNormallyIsFlakyNotCascaded`): a schemata
  timeout whose confirmation run finishes normally is unconditionally
  `.flaky`, never promoted to a verified kill. **This existing behavior is
  a load-bearing invariant this ADR must not weaken** — it is the reason a
  transient schemata-mode slowdown cannot masquerade as a confirmed hang.

The HIT/STARTUP proof chain (`MutationVerdictVerifier.verifySchemataChain`,
`SchemataEvidenceCollector`, `SchemataEvidence.swift`) proves a specific
mutant selector was reached at runtime via: a per-invocation `RunID` nonce
carried in the environment and echoed into a binary transcript, exact
semantic-identity matching (`RunID` + compilation unit + source-embedding
ID + selector token + built-image UUID) before any cardinality check, and
`exactlyOne`-style fail-closed cardinality checks at every chain stage
(zero or multiple candidates both throw — never `.first`/`.max` picking).
Duplicate STARTUP/HIT within one process throws; an orphan HIT with no
matching STARTUP in the same process throws. Events are grouped by process
ID, and multiple legitimate processes hitting the same mutation both count
as proof, not ambiguity.

One existing seam worth noting precisely: today's no-HIT → isolated-fallback
routing (`schemataIsolatedFallbackReason`) is scoped only to *passing* runs
with no STARTUP/HIT — a genuinely hanging mutant (which never completes,
hence is never a "passing run") does not go through this fallback path at
all; it goes through `.timedOut` classification and `confirmTimeout`
instead. The isolated-fallback mechanism and the hang-containment mechanism
this ADR designs are therefore complementary, not overlapping.

### 1.4 Chunk sizing and the absence of any per-mutant reset in schemata mode

`Sources/MutationPlanner/SchemataChunkPlanner.swift`: `maxChunkSize`
defaults to 200 mutants per chunk; grouping is conservative
(`(lowererID, projectIdentity, target, module, product)` only, plus a
same-file byte-range non-overlap constraint), and chunk-size capping is a
"simplest possible" consecutive-slice split with no tuning tied to
build-time cost or per-operator hang propensity — the doc comment
describes 200 as a placeholder pending a real chunking strategy. Chunking
is purely structural: it has no concept of "this operator hangs more
often, use a smaller chunk for it."

Comparing teardown behavior directly:

- **Schemata mode**: teardown is per-*chunk* only. The `for entry in
  embeddedEntries` loop has no per-entry sandbox reset. The only per-entry
  cleanup is the mutant's own small evidence directory (transcript file),
  not the shared sandbox contents, `.build` artifacts, or anything the
  mutated test process wrote/left behind.
- **Isolated mode** (`MutationRunner.swift`) is itself a mix: a fully
  independent per-mutant path (its own fresh sandbox and fresh build every
  time, full teardown after each mutant) coexists with
  persistent-worker/incremental-build paths that, like schemata mode, reuse
  one sandbox across many mutants sequentially — but those paths call
  `workspaces.restoreFile(relativePath: point.file, in: sandbox)` after
  each mutant (a targeted per-mutant reset of the mutated source file) and
  always trigger a fresh, independent build for the next mutant. Schemata
  mode has no analogue of `restoreFile`, because there is no per-mutant
  source edit to restore (selection is a runtime env-var token against one
  already-built binary) — but it also has no other per-mutant reset for
  anything a killed test process might leave behind in the shared sandbox
  before the next sequential invocation runs against the same directory.

**This is the precise gap this ADR addresses**: not a shared process, not
a shared verdict-decision path (both are already correctly isolated per
mutant), but an *unverified-clean shared filesystem/build-product state*
carried across up to 200 sequential subprocess invocations, with no
existing mechanism to detect or repair contamination of that shared state
after a hang/kill, and no existing mechanism to bound the serial
wall-clock cost one hang imposes on every mutant queued after it in the
same chunk.

## 2. Compared Designs

All three designs are evaluated against the same hard constraint: **must
preserve `MutationVerdictVerifier` as the sole verdict authority — no
design may introduce a second, competing source of truth for verdicts.**
All three are also evaluated against the fresh-process-per-mutant baseline
already in place today (§1.1) — none of them touch that; the process model
is not the gap. What varies is: (a) how the shared sandbox/build-product
state is protected or rebuilt around a detected hang, and (b) how
wall-clock blast radius to sibling mutants in the same chunk is bounded.

### Option A — Per-mutant subprocess re-invocation, unchanged (status quo, no new mechanism)

Do nothing beyond what exists: rely on `ProcessSupervisor`'s existing
kill-and-move-on behavior and `confirmTimeout`'s existing fail-closed
confirmation. After a kill, proceed directly to the next sequential entry
in the same sandbox with no verified-clean-state check and no chunk
wall-clock budget beyond the sum of per-mutant timeouts.

- **Verdict authority**: preserved trivially (nothing changes).
- **Performance cost vs. baseline**: zero — this *is* the baseline.
- **Implementation complexity/risk**: zero new code, but it does not close
  the identified gap: sandbox filesystem contamination after a kill is
  never detected or repaired, and one hang can still serially delay every
  remaining mutant in a 200-mutant chunk by its full timeout-plus-grace
  duration with no upper bound on how many mutants in one chunk hang.
  **Rejected as insufficient** — included here only as the explicit
  baseline the other options are measured against, per the milestone's own
  prerequisite ("no schemata-specific analogue... has been designed").

### Option B — Sandbox/build-product re-verification and forced chunk-rebuild after a detected hang, with a per-chunk hang budget

This option deliberately separates two questions that must not be
conflated (a distinction the first Codex review round of this ADR found
missing, and which the design below now makes explicit): **"is it safe to
keep using this sandbox?"** (a scheduling/containment question) and **"was
this mutant's timeout actually caused by the mutation?"** (a verdict
question, already correctly and exclusively owned by
`MutationVerdictVerifier`'s `confirmTimeout`, §1.3). Gating containment on
the verdict question — as an earlier draft of this design did — is unsafe:
`ProcessSupervisor` forcibly kills a process once it exceeds its timeout
*regardless* of what the confirmation run later decides, so a killed
process may already have left filesystem residue or an escaped descendant
(§1.2) even in the common case where the confirmation run resolves
normally and the verifier correctly classifies the mutant as `.flaky`. If
containment waited for `.verifiedTimeout`, every `.flaky`-resolving timeout
would leave the shared sandbox trusted with no basis for that trust. Two
independent sub-mechanisms follow from this separation:

1. **Containment trigger — fires on any forced timeout-kill, independent of
   eventual verdict.** Whenever `ProcessSupervisor` reports that a process
   it launched inside a chunk's shared sandbox was killed for exceeding its
   timeout (`ProcessResult.timedOut == true`), for *either* a primary run
   or a timeout confirmation run, the runner treats that sandbox and its
   compiled artifact as no longer trusted, unconditionally — before the
   verifier has classified anything. The runner destroys the sandbox,
   re-creates it, and rebuilds the schemata artifact *before any further
   process is spawned against it* — including the confirmation re-run
   itself when it follows a primary timeout, and including the next
   chunk entry after that. This is a real behavior change from today: a
   schemata timeout confirmation currently reuses the primary run's same
   sandbox/artifact (§1.3); under this ADR, a confirmation that follows a
   primary timeout-kill always runs against a freshly rebuilt
   sandbox/artifact, making schemata's timeout confirmation a genuinely
   independent rebuild for the first time, matching the "independent
   rebuild" framing this ADR uses elsewhere. Containment cost is paid once
   per forced kill, never gated on `.verifiedTimeout` vs `.flaky` — this
   bounds contamination risk to zero for everything evaluated after any
   forced kill in a chunk, whether or not that kill is later confirmed as
   mutation-caused.
2. **Per-chunk hang budget — fires only on verifier-confirmed
   `.verifiedTimeout`, governs isolated-mode overflow only, never
   containment.** A chunk-level ceiling, incremented only when
   `MutationVerdictVerifier` classifies a mutant as `.verifiedTimeout` (not
   on a raw kill, not on `.flaky`), tracks cumulative confirmed-hang cost.
   Once the ceiling is crossed, the chunk's remaining not-yet-finalized
   mutants fall back to isolated mode in their entirety (§4(b) specifies
   the exact granularity), rather than continuing to pay repeated rebuild
   costs in a chunk that turns out to be unusually hang-prone. This reuses
   the existing isolated-fallback plumbing
   (`SchemataMutationRunner.Outcome.isolatedFallbacks`) as the overflow
   valve, rather than inventing a new fallback path. Because this budget is
   verdict-derived, it cannot be used to trigger containment itself without
   reintroducing the Critical flaw above — it exists purely to bound
   *repeated* rebuild cost, a distinct concern from containment
   correctness.

- **Verdict authority**: fully preserved. `MutationVerdictVerifier` is
  untouched; this option only changes when a rebuild happens and when
  isolated fallback is triggered, both of which are runner-side scheduling
  decisions upstream of verdict decisions, exactly matching the existing
  ADR-0006 boundary ("`SchemataMutationRunner` decides nothing about
  outcomes").
- **Performance cost vs. baseline**: near-zero in the common case (no
  forced kills → no rebuilds, identical to today). Cost is paid on every
  forced timeout-kill (§3.2), not only on those the verifier later
  confirms as `.verifiedTimeout` — a primary timeout that resolves
  `.flaky` on confirmation still costs one rebuild (it must, to close the
  Critical gap in Addendum 1), and a primary-plus-confirmation pair that
  both time out costs two. Cost is therefore proportional to *forced-kill*
  frequency, a superset of confirmed-hang frequency, plus
  isolated-mode-per-mutant cost for any chunk that crosses the
  verdict-derived hang budget (§3.3). This directly answers the "quantify
  the tension" requirement: schemata's performance advantage (avoid N
  builds by sharing 1 build across N mutants) is given up in proportion to
  how often processes get forcibly killed for exceeding their timeout, not
  universally and not only in proportion to confirmed-mutation-caused
  hangs — a chunk with zero forced kills keeps the full advantage; a chunk
  that kills on every mutant degrades toward (but does not exceed)
  isolated-mode's per-mutant cost, because of the fallback overflow valve.
- **Implementation complexity/risk**: moderate. Requires: two distinct,
  independently testable trigger points in the runner's chunk loop — a
  containment trigger keyed directly off `ProcessResult.timedOut` on any
  spawn in the chunk (see §3, deliberately *not* keyed off
  `confirmTimeout`'s output), and a separate hang-budget accounting trigger
  keyed off the verifier's `.verifiedTimeout` classification; wiring a
  mid-chunk rebuild path (today's `runChunk` builds once up-front; this
  requires making that build re-enterable mid-loop, including
  re-enterable *before* a confirmation re-run, not only between chunk
  entries); explicit fail-closed handling for rebuild-itself failures
  (§4(c)); and extending the isolated-fallback plumbing to accept a
  "chunk gave up" reason distinct from today's build-time and no-HIT
  fallback reasons, applied at `MutationID` granularity (§4(b)) to stay
  consistent with the existing all-or-nothing-per-`MutationID` fallback
  model. Moderate-to-elevated risk because it touches `runChunk`'s control
  flow in two places (around any forced kill, and around confirmation
  scheduling) rather than one, but *not* `MutationVerdictVerifier` or the
  proof chain.

### Option C — Chunking strategy change: shrink chunk size for hang-prone contexts

Reduce blast radius structurally by capping chunk size well below the
current placeholder default of 200, either globally or adaptively (e.g.
smaller chunks for operators/files with above-baseline hang rates observed
in prior runs). This reduces how many mutants share one sandbox/build
product, so a hang (even under Option A's do-nothing containment) affects
fewer siblings.

- **Verdict authority**: preserved — this is a pure planning-time change in
  `SchemataChunkPlanner`, upstream of both the runner and the verifier.
- **Performance cost vs. baseline**: this is the *same tradeoff already
  implicit in the planner* (per its own doc comment: chunk size trades
  build-time overhead against — previously unstated — blast radius), made
  explicit and precise. Smaller chunks mean proportionally more separate
  builds (schemata's core cost-saving lever is exactly "1 build instead of
  N"), so shrinking chunk size directly and linearly gives back schemata's
  performance advantage; it does not eliminate the contamination gap
  identified in §1.4 (a hang can still corrupt the smaller shared sandbox
  for the mutants remaining in that smaller chunk), it only reduces how
  many mutants are exposed per incident.
- **Implementation complexity/risk**: low (a planner parameter/heuristic
  change), but it is a mitigation of blast-radius *size*, not a
  containment *mechanism* — it does not by itself provide fail-closed
  detection or recovery from a hang, and does not address the "no
  verified-clean-state guarantee" gap at all. It is a tuning knob, useful
  in combination with Option B, not a substitute for it.

### Option D (considered, not separately scored) — Adapt isolated mode's per-test-timeout mechanism directly

Investigated whether isolated mode's existing per-mutant timeout mechanism
could be reused unmodified. Finding: it already is reused — `TimeoutController`
and `ProcessSupervisor` are shared verbatim by both modes (§1.1, §1.2); the
per-*process* timeout mechanism is not the gap. What isolated mode has that
schemata mode lacks is the per-mutant *sandbox reset* (`restoreFile`,
§1.4), which does not directly generalize to schemata mode (there is no
per-mutant source edit to restore against a runtime-selector-based build).
This option collapses into Option B's rebuild-on-forced-timeout-kill
mechanism as the schemata-mode equivalent of `restoreFile` — noted here
rather than scored separately to avoid double-counting.

## Decision

**Adopt Option B (forced sandbox/build-product rebuild after any forced
timeout-kill, §3.2, with a separate verdict-derived per-chunk hang budget
and isolated-mode overflow fallback, §3.3),
combined with Option C as a tunable chunk-sizing input rather than a
competing mechanism.**

Reasoning:

- Option A does not close the identified gap and was assessed only as the
  baseline; it is explicitly rejected per the milestone's own instruction
  that this prerequisite must be resolved by direct design work, not left
  unaddressed.
- Option B is the only option that provides an actual **containment and
  recovery mechanism** (detect a forced timeout-kill, stop trusting the
  shared state immediately and unconditionally, rebuild, and separately
  bound *repeated*-rebuild damage with a verdict-derived hang budget)
  rather than only reducing exposure. Containment cost is paid in direct
  proportion to how often processes are actually forcibly killed for
  exceeding their timeout (not how often a hang is eventually confirmed as
  mutation-caused — see §2's Option B description for why those two
  triggers must stay separate), which matches this codebase's existing
  performance philosophy (schemata mode itself exists to trade upfront
  correctness machinery for amortized build cost; Option B extends that
  same trade rather than abandoning it).
- Option C alone reduces exposure but leaves the core gap (unverified
  shared state after a kill) unaddressed, and its cost is paid unconditionally
  on every chunk regardless of whether a hang ever occurs, which is worse
  than Option B's occurrence-proportional cost. Its correct role is as an
  input to Option B — a smaller default chunk size (or an adaptive one,
  informed by future per-operator hang-rate data such as the Operator
  Readiness milestone's own corpus findings) lowers how many siblings each
  Option-B rebuild event protects, and lowers how large the hang-budget
  overflow-to-isolated-fallback tax can get for a single pathological
  chunk. Both are tuning parameters of one adopted mechanism, not
  alternative mechanisms.
- Both preserve `MutationVerdictVerifier` as sole verdict authority with no
  loophole: neither option touches verdict decision logic; both operate
  strictly in the runner's chunk-scheduling layer, upstream of observation
  collection, which the verifier consumes exactly as it does today.

## 3. Fail-Closed Timeout Evidence

This ADR deliberately defines **two separate evidentiary standards for two
separate questions**, and the rest of this section exists to state exactly
what each one is and why they must not be merged. An earlier draft of this
ADR conflated them (gating containment on the verdict question) and was
found unsafe on review — see the Critical finding recorded in this ADR's
own review history (Addendum 1) for the precise failure mode.

**3.1 Evidence required to trust a mutant's *verdict* as `.verifiedTimeout`
— unchanged from today, extended by nothing.** This is exactly
`MutationVerdictVerifier.confirmTimeout`'s existing fail-closed gate, and
this ADR introduces no new or weaker verdict standard. Stated precisely
(correcting an over-generalization in an earlier draft of this section):
`confirmTimeout` has two branches with two different checks, not one
uniform batch-attribution gate:

- If the confirming re-run **also times out**: `.verifiedTimeout` is
  returned only if the confirming run's own activation evidence is
  independently proven (`unprovenActivation(confirmation.applicationEvidence)
  == nil`) and the confirmation/build consistency check
  (`confirmationActivationBuildProblem`) passes. The original run's
  `isBatchAttributedTimeout` flag is **not consulted on this branch** —
  two independently reconfirmed, independently proven timeouts are
  sufficient on their own.
- If the confirming re-run **resolves normally** (passed/failed/crashed):
  the result is `.verifiedTimeout`-eligible only if `original.decidingRun?
  .status == .timedOut && original.decidingRun?.isBatchAttributedTimeout
  == true`; schemata mode never batches, so this flag is always `false`
  for a schemata primary timeout, and the result is unconditionally
  `.flaky` on this branch. This is the specific invariant this ADR must
  not weaken (§1.3).

Nothing in this ADR changes either branch. The one behavior change (§2,
Option B item 1) is that a timeout confirmation which previously reused
the primary run's sandbox/artifact now runs against a freshly rebuilt one
whenever it follows a forced kill — this strengthens the confirming run's
independence, it does not touch either branch's classification logic.

**3.2 Evidence required to trust the *shared sandbox/build product* as
contaminated, triggering containment — a raw supervision fact, checked
before any verdict exists.** Containment (§2, Option B item 1) fires on
`ProcessResult.timedOut == true` from `ProcessSupervisor` for any spawn
inside the chunk's shared sandbox — the primary run or a confirmation
run — with no dependency on `MutationVerdictVerifier`'s eventual
classification of that mutant. This is intentional, not a weaker
standard applied where a stricter one belongs: it answers a materially
different question than §3.1. §3.1 asks "was this mutation the *cause* of
the timeout" (an attribution question, answerable only after independent
reconfirmation); §3.2 asks "did a process get forcibly killed inside this
shared sandbox" (a fact `ProcessSupervisor` already observes directly and
unambiguously, needing no reconfirmation, because the risk it protects
against — filesystem residue or an escaped descendant left by a killed
process, §1.2 — exists regardless of what caused the timeout or how the
verifier later classifies it). Requiring §3.1-grade evidence before
containment would leave every `.flaky`-resolving timeout's sandbox
trusted with no basis, which is exactly the Critical gap the first review
round of this ADR identified and this redesign closes.

This ADR specifies the required fact explicitly rather than leaving it
implicit: `SchemataMutationRunner` today only receives the already-classified
`TestRunResult` from the adapter, not `ProcessSupervisor`'s raw
`ProcessResult` directly. Verified against
`SwiftPackageMacOSAdapter.swift:301-303`: `TestRunResult.status` is set to
`.timedOut` precisely when, and only when, `ProcessResult.timedOut ==
true` — this mapping is already lossless in the one adapter traced for
this ADR. This ADR therefore normatively requires: `TestRunResult.status
== .timedOut` is the fact §3.2's containment trigger keys off (no new
field is required if this mapping holds for every adapter used in
practice); if a future adapter's mapping is ever not 1:1 with
`ProcessResult.timedOut` (e.g. it maps some other supervisor condition
to `.timedOut` too, or drops the distinction), that adapter must be
extended to preserve the raw fact rather than this ADR's containment
logic being redefined around a lossy proxy.

**3.3 The chunk hang budget (§2, Option B item 2) uses §3.1's standard,
not §3.2's**, because it exists to bound repeated *verdict-confirmed* hang
cost specifically, not raw kill frequency — see §2 for why conflating
these two would reintroduce the same flaw in the opposite direction (an
unconfirmed, possibly-innocent timeout should not count against a budget
whose purpose is limiting confirmed-mutation-caused disruption).

## 4. Recovery/Reuse Semantics After Hang/Crash

**(a) The hung/crashed mutant's own verdict.** Unaffected by this ADR.
`MutationVerdictVerifier`'s existing classification (`.timedOut` →
`confirmTimeout` → `.verifiedTimeout` or `.flaky`, or a crash's existing
crash-classification path) applies exactly as it does today; Option B adds
no new verdict outcome and does not special-case a mutant's own result
because it happened to trigger containment. The one change is procedural,
not classificatory (§3.1): a timeout confirmation that follows a forced
kill now runs against a freshly rebuilt sandbox/artifact rather than
today's reused one, so the confirming run's own evidence is, if anything,
more independently trustworthy than today, never less. If evidence from
the confirmation run legitimately supports a different verdict (e.g. the
confirming run reveals the mutation was never actually built/selected —
`unprovenActivation` — which today already routes toward `.flaky` rather
than `.verifiedTimeout`), that existing logic is unchanged and still
applies.

**(b) Other mutants in the same chunk not yet evaluated when the hang
occurred.** Two sub-cases, distinguished by trigger (§2/§3):

- **Containment (rebuild), on any forced kill.** As soon as a forced
  timeout-kill is observed (primary or confirmation run, §3.2), the runner
  destroys the current sandbox, creates a fresh one, rebuilds the chunk's
  schemata artifact, and only then proceeds — whether that "next step" is
  the mutant's own confirmation re-run or the next chunk entry. No partial
  trust in the pre-kill shared state is preserved for anything evaluated
  after the rebuild point. Entries evaluated after a rebuild are re-run in
  a fresh process (already true today, §1.1) *against a fresh sandbox and
  fresh build* (new under this ADR), with no special verdict marking —
  their evaluation proceeds through the normal `SchemataMutationRunner` →
  `MutationVerdictVerifier` path unchanged, because correctness of their
  result was never actually dependent on earlier mutants' execution
  history once evaluated against a clean rebuild. Mutants already fully
  evaluated *before* the kill, whose transcripts and verdicts were already
  collected, are not re-run or invalidated — the STARTUP/HIT proof chain's
  exact-identity + cardinality checks (§1.3) already fail closed on any
  cross-contamination in their own evidence, independent of what happens
  later in the same chunk.
- **Overflow (isolated-mode fallback), on hang-budget exhaustion, applied
  at `MutationID` granularity — not entry granularity.** Schemata's
  existing fallback model is all-or-nothing per `MutationID`: one fallback
  placement for a `MutationID` discards every schemata record already
  collected for that `MutationID` across all of its target placements and
  reruns the whole mutation through isolated mode
  (`SchemataMutationRunner.swift:156-180`). This ADR's overflow trigger
  must respect that existing invariant rather than introduce a
  finer-grained one: when the chunk's hang budget (§3.3) is exhausted, the
  runner closes out the chunk's schemata loop for every `MutationID` in
  that chunk that has not yet been **fully finalized across all of its
  target placements** — any such `MutationID`, including one with some but
  not all placements already schemata-verified, is dropped from schemata
  scoring entirely and rerun end-to-end through isolated mode, exactly as
  today's other fallback reasons already do. `MutationID`s that were
  already fully finalized (every target placement verified) before the
  budget was exhausted keep their schemata-derived verdicts untouched.
  This is a stronger requirement than "the chunk's process loop is
  sequential" alone establishes, and this ADR states it normatively rather
  than inferring it from sequencing: `runChunk`'s loop iterates over
  `program.entries` — one target placement at a time — and a `MutationID`
  embedded into multiple targets is run once per target, potentially
  across separate `SchemataProgram`s/builds, with the existing global
  per-`MutationID` fallback filtering applied only after all of a chunk's
  programs have been processed
  (`SchemataMutationRunner.swift:151-214`). A single program's entry loop
  being sequential does not by itself guarantee no `MutationID` is ever
  partway through its set of target placements when the hang budget is
  checked. Implementing overflow correctly therefore requires the runner
  to maintain explicit, global per-`MutationID` completion state across
  every program in the chunk (which target placements are done, which
  remain), and to treat any `MutationID` whose completion state is not
  "every target placement finalized" at the moment the budget is
  exhausted as subject to overflow closure — not to rely on an implicit
  "nothing is ever in progress" assumption. The correct acceptance-test
  invariant is therefore not "not double-evaluated"
  (an earlier draft's imprecise phrasing) but **"every `MutationID`'s final
  record comes from exactly one mode (schemata or isolated), and no
  `MutationID` is silently dropped or double-ledgered"** — this is
  reflected in the corrected acceptance test in §5.

**(c) The build product itself.** Not safe to reuse after any forced kill
(§3.2) — rebuilt as part of (b)'s containment sub-case, every time,
independent of the eventual verdict. Rationale: a killed test process may
leave filesystem residue in the shared sandbox (temp files,
partially-written files, locked resources, an escaped descendant — §1.2),
and there is no existing mechanism to positively verify the sandbox is
clean short of destroying and recreating it; a fresh build against a
fresh sandbox is the only state this ADR treats as trusted. The build
product itself (the binary) is not corrupted by a hang in the sense of
its bytes changing, but it is discarded together with the sandbox for
simplicity and because rebuilding is the existing, already-tested
`buildSchemataChunk` code path — reusing the binary while only recreating
the sandbox would require a new "attach an existing build to a new
sandbox" capability that does not exist today and is not justified by the
marginal cost saved (build cost dominates; see §2 Option B performance
discussion).

**(d) If the recovery rebuild itself fails.** Not addressed by an earlier
draft of this ADR; specified here explicitly, because a "frozen"
architectural decision must not leave a failure path as an implementation
afterthought. Sandbox destruction/recreation, the rebuild, or build-receipt
re-resolution can each independently fail, and today's *initial* per-chunk
build at `SchemataMutationRunner.swift:300-339` does **not** collapse all
three into one uniform outcome — a review round of this ADR found an
earlier draft's "handled identically... every ... receives an
`infrastructureFailureResult`" phrasing was inaccurate against the actual
three-way split, and this text corrects it. The initial path's real
behavior, which the recovery-rebuild path must reuse exactly rather than
reduce to a single case:

- A sandbox-creation error (`createSandbox` throws) converts to a per-entry
  `infrastructureFailureResult` (`SchemataMutationRunner.swift:304-311`).
- An unexpected (untyped) build error also converts to a per-entry
  `infrastructureFailureResult` (`SchemataMutationRunner.swift:327-331`).
- A *typed* `BuildFailure` (a genuine compilation error) does **not**
  become an infrastructure failure — it converts to `buildFailureResult`,
  which preserves the `BuildFailureKind` in a failed `BuildObservation`
  and lets the verifier classify it as `.unviable`, a materially different
  verdict from `.infrastructureFailure` (`SchemataMutationRunner.swift:322-326`).
  **Superseded 2026-08-19 for this one shape only — see Addendum 4.**
  Real-corpus evidence shows a shared-chunk `BuildFailure` is chunk-level
  evidence (the shared lowered program did not compile), not per-mutant
  compile evidence, and must not by itself establish `.unviable` for every
  `MutationID` the failed chunk represents. It must instead route to
  isolated-mode fallback at `MutationID` granularity; only a subsequent
  isolated-mode build/test may establish `.unviable`. The other three
  shapes in this list (sandbox-creation error, untyped build error,
  receipt-resolution failure) are unaffected by this amendment.
- A build-receipt resolution failure is not a thrown error at all — it is
  swallowed with `try?` and represented as a `nil` receipt, and entries
  proceed with the same "not proven, not guessed" unresolved-image-UUID
  fallback discipline the rest of the chain already uses for an ambiguous
  mapping (`SchemataMutationRunner.swift:383`).

The recovery-rebuild path (destroy sandbox, recreate, rebuild, re-resolve
receipts, mid-chunk) must route each of these four outcomes through the
*same* four handlers the initial per-chunk build already uses. **The typed-
`BuildFailure` sub-case is superseded 2026-08-19 — see Addendum 4**: a
typed `BuildFailure` during recovery no longer yields `.unviable` directly;
it routes every not-yet-fully-finalized `MutationID` remaining in the chunk
to isolated-mode fallback (`.sharedChunkBuildFailure`, Addendum 4), joining
the existing all-or-nothing-per-`MutationID` dynamic-fallback mechanism —
never a silent skip, and never a manufactured `.infrastructureFailure`
either. The other three shapes (sandbox-creation error, untyped build
error, receipt-resolution failure) are unaffected: they remain
infrastructure/build-health signals distinct from a hang-budget overflow,
and still do not trigger isolated-mode fallback — conflating those three
with a hang-budget overflow would let a broken build environment silently
masquerade as "this chunk is just hang-prone," which this amendment does
not change.
No part of a failed recovery attempt (partial sandbox state, a partially
written artifact) is reused by any subsequent chunk or `MutationID` —
the next chunk's `createSandbox` call already establishes a new sandbox
identity (`program.chunkID`), so this requires no new isolation guarantee
beyond what chunk-level sandboxing already provides.

## 5. Acceptance Tests and Real-Corpus Promotion Gate

Following the same evidentiary discipline the Operator Readiness milestone
established (real-corpus evidence required before promotion; explicit,
falsifiable correctness gates before any generalization claim; distinguish
"legitimate mutant behavior" from an actual infrastructure defect rather
than assuming either by default) — restated precisely for this milestone
rather than borrowed by name, since the two specific documents read for
this ADR name a three-axis readiness framework (isolated-readiness /
schemata-supportability / current profile) and a "Category A = legitimate,
not a defect" convention, but do not themselves define a complete A–E
outcome taxonomy; this ADR does not fabricate one and instead defines its
own acceptance criteria directly.

**Unit/acceptance tests required before implementation is considered
done** (synthetic, no real corpus needed):

1. **Synthetic hang injection, single hang, mid-chunk.** A schemata chunk
   with N synthetic mutants where mutant k (1 < k < N) is a genuine
   infinite loop. Assert: mutant k's own verdict follows existing
   `confirmTimeout`/`verifiedTimeout`-or-`flaky` logic unchanged; mutants
   1..k-1 keep their pre-hang verdicts; mutants k+1..N are evaluated
   against a demonstrably fresh sandbox/build (e.g. assert a new build
   receipt/image UUID distinct from the pre-hang one) and produce correct
   verdicts.
2. **Synthetic hang injection, hang on the last mutant in a chunk.**
   Confirms no unnecessary rebuild is triggered when there is nothing left
   to protect (rebuild is wasted work if k == N; this is a legitimate
   optimization to verify, not a correctness requirement, but must not be
   silently assumed either way — the test asserts the actual chosen
   behavior in the implementation).
3. **Synthetic hang injection, multiple hangs in one chunk, below hang
   budget.** Assert repeated rebuilds occur (bounded, matching forced
   timeout-kill count per §3.2 — a superset of confirmed-hang count, since
   a kill whose confirmation resolves `.flaky` still triggers a rebuild),
   and every non-hanging mutant still gets a correct verdict.
4. **Synthetic hang injection, hangs exceeding the per-chunk hang budget.**
   Assert overflow correctly routes every not-yet-fully-finalized
   `MutationID` remaining in the chunk to isolated-mode fallback via the
   existing fallback outcome plumbing (§4(b)), and assert the corrected
   invariant precisely: every `MutationID`'s final record comes from
   exactly one mode, and no `MutationID` is silently dropped or
   double-ledgered (not the earlier, imprecise "not double-evaluated"
   phrasing — a `MutationID` with some target placements already
   schemata-verified before overflow is intentionally discarded and
   fully rerun in isolated mode, which is expected re-execution, not a
   defect, per §4(b)).
5. **Crash-vs-hang distinction, including a residue-leaving crash
   variant.** Two sub-tests, because the plain "prompt crash implies a
   reusable sandbox" assumption is a policy choice this ADR makes, not a
   safety property proven anywhere in the traced source (§1.2 only
   documents residue/escape risk for *timed-out* kills, not ordinary
   process exits) — flagged during review as needing evidence rather than
   assumption:
   (a) an ordinary synthetic mutant that crashes promptly (nonzero
   exit/signal, not a timeout) must not trigger containment — assert no
   rebuild occurs and the sandbox is reused for the next entry, matching
   `ProcessResult`'s existing `timedOut`/`terminatingSignal`/`exitCode`
   fields distinguishing crash from hang;
   (b) a synthetic mutant engineered to crash *after* deliberately leaving
   a stray child process and a stray temp file in the sandbox — this test
   is the actual evidence gate for the crash/no-rebuild policy choice: if
   it demonstrates that a promptly-crashing process can still leave
   containment-relevant residue, the "Not Yet Decided" item on crash
   containment (below) must be resolved in favor of triggering it before
   this mechanism is promoted, not left as an assumption.
6. **Primary timeout-kill but confirmation run resolves normally
   (`.flaky` case).** Assert the *rebuild* (§3.2, containment) still fires
   on the confirmation run's own forced kill if it also timed out, or on
   the primary run's forced kill regardless of the confirmation's outcome
   — and separately assert the *hang budget* (§3.3) does NOT increment,
   since the verifier classified this mutant `.flaky`, not
   `.verifiedTimeout`. This test exists specifically to keep containment
   and attribution from being silently re-merged during implementation.
7. **Verifier-authority regression test.** Assert, by construction (e.g. a
   mutation-tested or explicit unit assertion on the call graph / a
   deliberate test that stubs `MutationVerdictVerifier` and asserts it is
   the only caller producing a `VerifiedMutationRecord` for schemata
   entries even across a rebuild event), that no new code path introduced
   by this ADR constructs a verdict outside `MutationVerdictVerifier`.
8. **Recovery-rebuild failure, all four sub-cases from §4(d).**
   *Superseded 2026-08-19 for the typed-`BuildFailure` sub-case — see
   Addendum 4 and its item 4/5, which replace this item's typed-
   `BuildFailure` assertion below with an isolated-fallback assertion.
   The other three sub-cases are unchanged.* Inject each of the four
   failure shapes §4(d) enumerates into the mid-chunk rebuild path —
   sandbox recreation throws, an untyped build error is thrown, a *typed*
   `BuildFailure` is thrown, and build-receipt re-resolution fails — and
   assert each routes through the same handler the initial per-chunk
   build already uses for that shape (the first two to
   `infrastructureFailureResult`; ~~the typed `BuildFailure` case to
   `buildFailureResult`/`.unviable`~~ **the typed `BuildFailure` case now
   routes to isolated-mode fallback, Addendum 4**; and the
   receipt-resolution failure to a `nil` receipt with entries proceeding
   under the existing unresolved-mapping fallback), for every
   not-yet-finalized `MutationID` remaining in the chunk — not a silent
   skip, and ~~not an automatic isolated-mode fallback in any of the four
   cases, which must remain reserved for hang-budget overflow
   specifically~~ **isolated-mode fallback is now correct for the typed-
   `BuildFailure` sub-case specifically (Addendum 4); the other three
   sub-cases still must not trigger it, which remains reserved for
   hang-budget overflow and shared-chunk-build-failure fallback only.**

**Real-corpus validation required before this mechanism can be trusted for
real experimental-operator schemata work** (the promotion gate a future
implementation milestone must clear — not cleared by this ADR):

- **Fixed, reproducible corpus matrix, not "at least one" case.** Pin an
  exact corpus revision (commit SHA), toolchain version, platform, and
  build configuration, and require **at least two independent corpora**
  (e.g. `swift-algorithms` plus one other), each contributing at least
  one already-known real hang — a single corpus is too weak a
  generalization bar for a claim meant to cover a cross-operator
  architecture gap (§1's cross-operator framing). For `swift-algorithms`
  specifically, use the cases already identified by the Operator
  Readiness milestone: `Chunked.swift` nil-coalescing-fallback,
  `Split.swift` assignment-operator-replacement and arithmetic-operator
  hangs. Publish the exact corpus/toolchain/config manifest alongside the
  results so the run is independently repeatable, not merely reported.
- **Repetition requirement.** Run each known-hang case a minimum of 3
  times under the new mechanism to distinguish a genuinely flaky
  confirmation outcome from a deterministic one before treating either as
  ground truth — a single run of a `.flaky`-classified case proves
  nothing about whether that classification is stable.
- Confirm, per repetition: (i) every previously-known hang still produces
  the same final verdict (`verifiedTimeout` or `flaky`, matching prior
  isolated-mode-confirmed ground truth) under the new containment
  mechanism — containment must not change verdict outcomes, only
  shared-state hygiene; (ii) sibling mutants in the same chunk as a real
  hang produce verdicts matching their own independent isolated-mode
  ground truth, using an explicit equivalence definition — identical
  outcome enum value, and for kill-classified mutants, an identical
  failing-test set — not merely "did not error"; (iii) wall-clock overhead
  of the containment mechanism is measured and reported against the
  no-isolation baseline on both a hang-free corpus and a hang-heavy
  corpus, against a **numeric threshold fixed before the run, not
  asserted post hoc** — this ADR does not fix that number itself (see
  "Not Yet Decided"), but the promotion gate must have one on record
  before results are evaluated against it, not a qualitative "~zero"
  or "bounded" left to interpretation.
- Retain and publish, for audit, every transcript, build receipt,
  per-mutant timing, and fallback/containment decision produced during
  this validation run — not only a pass/fail summary — so a future
  reviewer can re-derive the same conclusions from raw evidence, matching
  the Operator Readiness milestone's own re-derive-from-primary-evidence
  discipline.
- Any abnormal result surfaced during this real-corpus validation must be
  triaged with the same rigor the Operator Readiness milestone modeled:
  re-derive from raw primary evidence (transcripts, build receipts) rather
  than trusting a summary; explicitly distinguish "legitimate mutant
  behavior" (e.g. a mutation that legitimately, correctly hangs and is
  correctly classified) from an actual defect in this new mechanism;
  document unresolved findings rather than rounding up to a clean result.
- Only after Critical=0/High=0 on an independent review of both the unit
  test suite (item 1–8 above) and this real-corpus validation should
  arithmetic-operator-replacement's and range-boundary-replacement's
  schemata-supportability axis be reconsidered for promotion — and even
  then, only for the hang-containment prerequisite specifically;
  range-boundary-replacement's separate type-unification feasibility
  question (unrelated to hangs) is out of scope for this ADR and must be
  resolved independently.

## Not Yet Decided / Deferred to Implementation

The following are genuinely open and intentionally left for the
implementation milestone to resolve, not decided here:

- **Whether Option C's chunk-size reduction should be a static global
  default change or an adaptive, per-operator/per-file heuristic informed
  by observed hang rates** — the Operator Readiness milestone's corpus
  findings are a plausible future data source for such a heuristic, but no
  such heuristic is specified here.
- **Whether a rebuild-in-progress should block or overlap with the next
  chunk's own build** (scheduling/concurrency interaction between the
  containment mechanism and however chunks are parallelized across each
  other, if at all — this ADR does not characterize cross-chunk
  parallelism, only within-chunk sequencing, because the current
  architecture trace in §1 found chunk evaluation to already be
  sequential-within-chunk; whether chunks themselves run concurrently
  with each other was out of scope for the source trace performed here).
- **Exact mechanics of making `runChunk`'s current up-front, single build
  call re-enterable mid-loop** — this ADR specifies the required behavior
  (rebuild after any forced timeout-kill, resume remaining entries) but not the
  concrete refactor of `SchemataMutationRunner.runChunk`'s control flow
  needed to support a build call partway through the entry loop.
- **Whether crash detection (§5 item 5) needs any change to
  `ProcessSupervisor`/`ProcessResult` to make the hang-vs-crash distinction
  more directly queryable by the containment scheduler**, or whether the
  existing `timedOut`/`terminatingSignal`/`exitCode` fields already suffice
  as-is — the trace in §1.2 confirms the fields exist; whether the runner's
  present call sites already surface them cleanly enough for a containment
  decision was not verified line-by-line against every call site.
- **Whether a prompt crash should also trigger containment (sandbox
  rebuild), not just a timeout-kill.** §4(c) currently scopes containment
  to forced timeout-kills only, on the reasoning that §1.2's documented
  residue/escaped-descendant risk is specific to processes killed after
  exceeding their timeout. This is a policy choice, not a proven safety
  property — no source evidence traced for this ADR establishes that an
  ordinarily-crashing process cannot also leave residue. §5 item 5(b)'s
  residue-leaving-crash test is the intended evidence gate for this
  question; if it finds crashes can leave containment-relevant residue,
  this ADR's scoping decision must be revisited before promotion, not
  quietly kept.
- **The exact numeric wall-clock-overhead threshold(s) required by the
  real-corpus promotion gate** (§5) — this ADR requires that a fixed
  threshold exist and be recorded before results are evaluated against it,
  but does not set the number itself; no baseline performance data exists
  yet to justify one, and setting it without data would be exactly the
  kind of ungrounded certainty this ADR otherwise avoids.
- **The exact per-chunk hang-budget composition** — §3.3 specifies the
  budget is incremented only on verifier-confirmed `.verifiedTimeout`
  events, but whether it should count confirmed-hang *count*, cumulative
  confirmed-hang *wall-clock time* (and if so, whether that includes the
  antecedent forced-kill's own timeout duration, the confirmation run's
  duration, or both), or a combination, is left open pending the
  real-corpus validation data in §5.

## Consequences

- Closes the named schemata-supportability prerequisite blocking
  arithmetic-operator-replacement and range-boundary-replacement's hang
  isolation concern specifically (not range-boundary-replacement's
  separate type-unification question), once implemented and cleared
  through the §5 gate.
- No change to `MutationVerdictVerifier`, the STARTUP/HIT proof chain, or
  any existing ADR-0003/0004/0005/0006 invariant is required — this design
  is additive at the runner's chunk-scheduling layer only.
- Adds implementation and testing burden proportional to Option B's
  moderate complexity (§2): a re-enterable chunk build path, hang-budget
  accounting, and an extended isolated-fallback reason — plus the full
  real-corpus validation gate in §5, which is nontrivial future work in its
  own right and should be scoped as its own milestone task, not assumed to
  be quick.
- Leaves chunk-size tuning (Option C) as a follow-up parameter change,
  not blocked on this ADR, but best informed by data gathered during this
  ADR's own §5 validation.

## Addendum 1: Codex adversarial review, revision 1 → 2

An independent adversarial review (`codex exec -s read-only`) of
revision 1 of this ADR, cross-checked against
`SchemataMutationRunner.swift`, `MutationVerdictVerifier.swift`,
`ProcessSupervisor.swift`, and `ProcessTree.swift`, returned
**Critical=1, High=3, Medium=2**:

- **Critical** — revision 1's Option B gated the sandbox-rebuild
  (containment) trigger on `MutationVerdictVerifier`'s confirmed-verdict
  output (`.verifiedTimeout`), which left the shared sandbox trusted after
  any forced timeout-kill whose confirmation happened to resolve normally
  (`.flaky`) — verdict-safe but not containment-safe, since
  `ProcessSupervisor` kills a process for exceeding its timeout
  independent of what the confirmation later decides. **Fixed** by
  splitting containment (§3.2, fires on any `ProcessResult.timedOut`,
  independent of verdict) from the hang budget (§3.3, fires only on
  `.verifiedTimeout`) — see §2 Option B and §3.
- **High** — §3's original text claimed the confirmed-timeout standard is
  uniformly "gated by the original run's own batch-attribution flag,"
  which is only true for the confirmation-resolves-normally branch of
  `confirmTimeout`, not the confirmation-also-times-out branch. **Fixed**
  by restating both branches precisely in §3.1. Also flagged: schemata
  confirmation today reuses the primary run's sandbox/artifact rather than
  rebuilding, contradicting the ADR's "independent rebuild" framing.
  **Fixed** by making the containment rebuild run before any confirmation
  that follows a forced kill, so confirmation now genuinely gets a fresh
  build under this ADR (§2 Option B item 1, §4(a)).
- **High** — overflow/rebuild-failure state transitions were
  underspecified (budget composition, rebuild-failure handling, and
  whether overflow could interrupt an in-progress mutant). **Fixed** by
  §4(d) (explicit fail-closed rebuild-failure handling, mirroring the
  existing initial-build-failure path) and by §4(b)'s note that chunk
  evaluation is strictly sequential, so overflow can only ever be
  evaluated between fully-finalized `MutationID`s, never mid-evaluation.
- **High** — "remaining entries" in revision 1 conflicted with the
  existing all-or-nothing-per-`MutationID` schemata-fallback model
  (`SchemataMutationRunner.swift:156-180`), which discards every already-
  verified target placement for a `MutationID` on any fallback. **Fixed**
  by respecifying overflow at `MutationID` granularity in §4(b), and by
  correcting the acceptance-test invariant from "not double-evaluated" to
  "every `MutationID`'s final record comes from exactly one mode, and no
  `MutationID` is silently dropped or double-ledgered" (§5 item 4).
- **Medium** — the crash-implies-reusable-sandbox rule rested on an
  unsupported cleanliness assumption (no traced source establishes that
  prompt crashes cannot also leave residue, only that timed-out kills
  can). **Fixed** by reframing it explicitly as a policy choice pending
  evidence (§4(c), "Not Yet Decided") and adding a residue-leaving-crash
  acceptance test (§5 item 5(b)) as the evidence gate for that policy.
- **Medium** — the real-corpus promotion gate lacked reproducibility and
  quantitative thresholds (no fixed corpus/toolchain manifest, no
  repetition requirement, no numeric overhead threshold, "at least one"
  corpus as a weak generalization bar). **Fixed** by §5's promotion-gate
  rewrite: a fixed, published corpus/toolchain manifest across at least
  two independent corpora, a minimum-3-repetitions requirement per known
  hang case, an explicit equivalence definition for cross-mode verdict
  comparison, and a requirement that a numeric overhead threshold be
  fixed and recorded before evaluation (the number itself deferred to
  "Not Yet Decided," since no baseline data exists yet to set it).

A second review round against the revised text follows in Addendum 2.

## Addendum 2: Codex adversarial review, revision 2 → 3

A second independent review returned **Critical=0, High=1, Medium=3,
Low=0**, confirming the round-1 Critical was substantively fixed and
finding the containment/attribution split correctly preserves
`MutationVerdictVerifier` as sole verdict authority (explicitly checked:
"I found no new path that constructs or decides a verdict outside it").
Remaining findings, all now fixed:

- **High** — §4(d)'s original text claimed a mid-chunk recovery-rebuild
  failure is "handled identically" to the initial per-chunk build failure
  path while normatively collapsing every failure into one
  `infrastructureFailureResult`, but the actual initial-build path
  (`SchemataMutationRunner.swift:300-339`) is a four-way split: sandbox-
  creation and untyped-build errors do become `infrastructureFailureResult`,
  but a *typed* `BuildFailure` instead becomes `buildFailureResult`/
  `.unviable` (a different verdict), and a receipt-resolution failure is
  swallowed into a `nil` receipt rather than thrown at all. **Fixed** by
  rewriting §4(d) to enumerate and require reuse of all four shapes
  exactly, and by rewriting §5 item 8's acceptance test to assert each of
  the four sub-cases routes through its correct handler rather than one
  uniform failure type.
- **Medium** — the Decision headline, the Option B performance-cost
  bullet, and Option D still used "confirmed hang" language after the
  Critical-fix redesign made the actual containment trigger "any forced
  timeout-kill" (§3.2) — an accurate mechanism description undermined by
  stale summary wording. **Fixed** by rewording the Decision headline,
  the performance-cost bullet (§2), and Option D to say "forced
  timeout-kill" throughout, and by making the performance-cost analysis
  explicit that cost is paid on every forced kill (a superset of
  confirmed-hang frequency), including on primary timeouts that resolve
  `.flaky`.
- **Medium** — §4(b)'s claim that overflow can only be evaluated between
  "fully sequential," fully-finalized `MutationID`s understated the real
  structure: the chunk loop iterates over `program.entries` (one target
  placement at a time), and a `MutationID` embedded into multiple targets
  runs once per target across potentially separate programs/builds, with
  global per-`MutationID` fallback filtering happening only after all
  programs are processed (`SchemataMutationRunner.swift:151-214`) — "the
  loop is sequential" alone does not establish "no `MutationID` is ever
  partially evaluated when overflow is checked." **Fixed** by rewording
  §4(b) to state the requirement normatively instead of inferring it from
  sequencing alone: the overflow mechanism must maintain global per-
  `MutationID` completion state across programs and treat any
  `MutationID` not yet complete across every target placement as subject
  to overflow closure, and by removing the unsupported "no in-progress
  mutation is possible" framing.
- **Medium** — §3.2 required containment to key off `ProcessResult.timedOut`
  but `SchemataMutationRunner` today only receives the adapter's
  already-classified `TestRunResult`, not `ProcessSupervisor`'s raw result,
  and the ADR did not say whether that mapping is lossless or whether a
  contract change is required. **Fixed** by adding a normative note to
  §3.2, verified against `SwiftPackageMacOSAdapter.swift:301-303`: the one
  traced adapter sets `TestRunResult.status = .timedOut` if and only if
  `ProcessResult.timedOut == true`, so `TestRunResult.status == .timedOut`
  is specified as the fact containment keys off, with an explicit
  requirement that any adapter whose mapping is not similarly lossless
  must be extended to preserve the raw fact rather than have containment
  logic redefined around a lossy proxy.

§4(b)'s corrected text is reproduced above in the current §4(b); this
addendum records only the review finding and disposition, not a duplicate
of the fix.

## Addendum 3: Codex adversarial review, revision 3 → frozen

A third independent review returned **Critical=0, High=0, Medium=1,
Low=0**, and confirmed all four round-2 findings resolved and
`MutationVerdictVerifier` still the sole verdict authority ("all outcome
construction still routes through `MutationVerdictVerifier.swift:3`").
One remaining Medium: §5 item 3's acceptance-test wording still said
repeated rebuilds should "match confirmed-hang count," when §3.2 actually
triggers one rebuild per forced timeout-kill — a superset of
confirmed-hang count, since a primary-plus-confirmation pair that both
time out produces two forced kills but at most one `.verifiedTimeout`,
and a primary timeout whose confirmation resolves normally produces one
rebuild despite zero confirmed hangs. The same review flagged §5 item 6's
title, "Hang confirmed but confirmation run resolves normally," as making
the identical stale-wording error. **Fixed** by rewording §5 item 3 to
assert rebuild count against forced-timeout-kill count specifically (with
the confirmed-hang budget tested only against §3.3 separately), and by
retitling §5 item 6 to "Primary timeout-kill but confirmation run
resolves normally."

This ADR is frozen as of this clean review (Critical=0/High=0, the bar
this milestone's own review discipline requires to stop; the one
remaining Medium at the time of the third review is fixed above and not
re-reviewed by a fourth round, consistent with Medium findings not
blocking freeze under this milestone's standard).

## Addendum 4: Post-freeze amendment — shared schemata chunk build-failure attribution (2026-08-19)

- **Status of this addendum:** FROZEN (2026-08-19), same bar Addenda 1–3
  applied pre-freeze. Two rounds of independent Codex architecture
  review: round 1 (Critical=0/High=1/Medium=1) → round 2, after fixing
  both round-1 findings (Critical=0/High=0/Medium=0/Low=1, the one
  remaining Low also fixed and not re-reviewed by a third round,
  consistent with this project's own Low/Medium-does-not-block-freeze
  convention, §"Addendum 3"). Full review transcripts:
  `Research/adr-0008-amendment-2026-08-19/codex-review-round1.log` and
  `codex-review-round2.log` (this worktree). Written per this project's
  standing revision policy (dated addenda only, never silent edits of
  frozen text) — see the two inline superseded-notes in §4(d) and §5 item
  8 for exactly what this addendum overrides.
- **Trigger:** real-corpus evidence from the Muter-comparison protocol's
  execution-diagnostic phase (not this ADR's own §5 real-corpus
  promotion gate, which this addendum does not claim to satisfy — see
  "Scope" below). Full findings, Codex review transcript, and preserved
  raw evidence (before/after `report.json`, the failing build's kept
  sandbox with its lowered source, and the build-only reproducer tool
  used):
  `Research/muter-comparison/diagnostics-2026-08-18/bool-literal-chunk-build-failure-findings.md`
  (worktree `mutantkit-private-muter-comparison-protocol`).

### What was found

Running the pinned-commit `swift-argument-parser` corpus in schemata
mode, `swift.core.bool-literal-inversion`'s 118-entry embedded chunk
failed to compile (`error: switch must be exhaustive`, at a
`switch (Bool, Bool) { case (true/false, true/false): ... }` this
operator's lowerer had rewritten a case-pattern-position literal into a
runtime-selectable expression, which Swift's exhaustiveness checker
cannot statically prove covers all combinations). Under §4(d) as
originally written, this typed `BuildFailure` became `.unviable` for
**every** `MutationID` the chunk represented — all 118, regardless of
whether that specific mutation's own lowering was what broke the build.

A build-only reproducer (`Sources/SchemataChunkBuildProbe`, additive-
only, not otherwise part of the codebase) isolated one of the 118 —
`mut_400c26b8b9f00db2`, an ordinary named-argument-value boolean literal,
not a case pattern — into its own single-entry schemata chunk and its
own isolated-mode build. **Both succeeded.** This is a direct
counterexample: a mutation the original attribution rule marked
`.unviable` in fact compiles cleanly on its own, in both backends. One
counterexample is sufficient to show the shared-chunk-failure-implies-
every-member-`.unviable` projection is unsound; it does not depend on
knowing exactly which of the 118 are the true case-pattern culprits.

### Scope — two independent, stackable defects

This addendum resolves only the second of these. The first is a
lowerer-eligibility bug, tracked and fixed separately (implementation
milestone, not this ADR):

1. **`BoolLiteralSchemataLowerer` eligibility gap** (not an ADR-0008
   concern — this ADR governs containment/attribution, not which syntax
   positions a lowerer may target). `analyze()` has no case-pattern-
   position check today and should route such candidates to planner-time
   fallback, the same way other lowerers already report
   `unsupportedOperand`. Fixing this reduces how often the failure mode
   below is triggered; it does not eliminate the need for this
   addendum, because *any* future lowerer, on *any* corpus, can produce
   a shared chunk that fails to compile for reasons individual
   `analyze()` calls cannot foresee (per `SchemataChunkPlanner`'s own
   existing doc comment on batch-level `lower()` failures that
   `analyze()` cannot see in isolation) — the attribution rule below
   must hold generally, not only for this one triggering case.
2. **Backend-specific false-`.unviable` verdict attribution** (this ADR,
   this addendum).

### New rule: shared schemata build-failure attribution

> A typed `BuildFailure` from `buildSchemataChunk(...)` is **chunk-level
> evidence**. It proves only that the shared lowered program did not
> compile. It **must not** establish `.unviable` for any individual
> `MutationID`. Instead:
>
> - **Initial chunk build failure:** every `MutationID` represented by
>   that failed chunk → dynamic isolated fallback.
> - **Recovery rebuild failure** (§4(d), the mid-chunk rebuild path):
>   every not-yet-fully-finalized `MutationID` whose remaining execution
>   still depends on that failed rebuilt chunk state → dynamic isolated
>   fallback.
> - For any affected `MutationID`, fallback is whole-`MutationID` / all-
>   target-placement, using the existing all-or-nothing dynamic-fallback
>   semantics (`SchemataMutationRunner.swift:156-180`, the same model
>   §4(b) already requires for hang-budget overflow). Any schemata
>   records already produced for that `MutationID` (including a
>   partially-completed set of target placements) are discarded, and the
>   `MutationID` is rerun end-to-end through the normal isolated path.
> - Only the normal isolated-mode evidence chain — a per-mutant build,
>   and (when applicable) test execution and `MutationVerdictVerifier`
>   classification — may subsequently establish `.unviable` for that
>   `MutationID`. (Deliberately not narrowed to "compile/test outcome"
>   only: the normal isolated path may also legally resolve a mutation to
>   `.noCoverage` before a build is even attempted, which is not a defect
>   and must not be excluded by this rule's wording.)

**This is not a change to ADR-0008's timeout/containment design.** §2's
Option B decision, §3's containment/hang-budget evidentiary split, and
§4(a)–(c) are unaffected. This amends only §4(d)/§5 item 8's build-
failure *attribution* rule for the one sub-case (typed `BuildFailure`
from a *shared schemata chunk* build) that new evidence shows was wrong.

### Revised disposition table (supersedes the relevant row of §4(d)'s four-way split)

| Failure shape | Disposition |
|---|---|
| Sandbox-creation error (`createSandbox` throws) | `infrastructureFailureResult` — **unchanged** |
| Untyped build/infrastructure error | `infrastructureFailureResult` — **unchanged** |
| Typed `BuildFailure` from a shared schemata chunk build (initial or recovery) | Dynamic isolated fallback, `MutationID` granularity — **CHANGED**, was `buildFailureResult`/`.unviable` |
| Build-receipt resolution failure | `nil` receipt + existing fail-closed unresolved-mapping path — **unchanged** |

Only the third row changes. Sandbox-creation and untyped-build errors
remain infrastructure signals distinct from a hang-budget overflow or a
shared-chunk build failure — this amendment does not turn every build
problem into an isolated-mode fallback, only the one shape (a genuine
compile error in the shared lowered program) that is demonstrably not
per-mutant evidence. A systemic infrastructure/configuration defect
(e.g. a missing build dependency affecting every chunk) must still
surface as `infrastructureFailureResult`, not be silently absorbed into
isolated-mode reruns that could mask it as ordinary per-mutant fallback
— see the "fan-out/observability" acceptance criterion below.

### `SchemataFallbackReason` — new case

Extends the reason type already established for this mechanism (dynamic
activation fallback / hang-budget overflow):

```swift
public enum SchemataFallbackReason: Sendable, Hashable {
    case activation(MutationVerdictVerifier.SchemataIsolatedFallbackReason)
    case hangBudgetExceeded
    case sharedChunkBuildFailure   // new
}
```

The compiler diagnostic itself is not stored as an associated value —
it is chunk-level, not per-`MutationID`, and belongs in a separate
chunk-level diagnostic event (report/transcript), not folded into a
per-mutant reason enum whose other cases are already per-`MutationID`
facts.

### Hang-budget semantics — unchanged, restated for clarity

This amendment introduces a third isolated-fallback trigger alongside
the two ADR-0008 already defines. All three remain semantically
distinct and must not be conflated:

```
raw timeout                    -> containment trigger (§3.2, unchanged)
final verifiedTimeout           -> hang budget accounting (§3.3, unchanged)
hang budget overflow            -> isolated fallback (.hangBudgetExceeded)
shared typed chunk BuildFailure -> isolated fallback (.sharedChunkBuildFailure)
                                    -- does NOT affect the hang budget
```

A shared-chunk build failure is not a timeout and must not increment or
be gated by the hang budget in either direction; it is an independent
fallback trigger with its own reason.

### `MutationVerdictVerifier` — unchanged, no new authority

The runner's role under this amendment is unchanged from ADR-0008's
existing containment/overflow design: it decides *that* a `MutationID`
cannot be scored from schemata evidence and routes it to isolated mode.
It does not construct, infer, or manufacture a verdict itself. The
isolated-mode `MutationRunner` → `MutationVerdictVerifier` path, exactly
as it exists today, is the only place `.unviable` (or any other outcome)
gets decided for a fallback-routed `MutationID`. No new verdict-
construction path is introduced.

### Acceptance tests — additions/revisions to §5

Items 1–7 of §5 are unaffected by this amendment. Item 8 is revised (see
the inline strikethrough in §5 above) and the following are added:

8. *(revised, see §5 item 8's inline markup above)* — recovery-rebuild
   typed-`BuildFailure` sub-case now asserts isolated-fallback routing,
   not `.unviable`.
9. **Initial shared typed `BuildFailure`.** A chunk with synthetic
   mutants A/B/C where the shared lowered program fails to compile, and
   A is independently known to compile fine in isolated mode. Assert:
   A/B/C all receive dynamic isolated fallback; zero schemata `.unviable`
   verdicts are produced for this chunk; A's final verdict comes from its
   isolated rerun.
10. **Genuine unviable, surviving fallback.** A shared chunk build fails,
    *and* one of its mutants also fails to compile on its own in
    isolated mode. Assert that mutant's final verdict is still
    `.unviable` — falling back to isolated mode must not cause a
    genuinely-unviable mutant to lose that classification, it must only
    change *which evidence* establishes it.
11. **Multi-target withdrawal.** A `MutationID` embedded in target X
    (already schemata-verified) and target Y (whose chunk's shared build
    fails). Assert the `MutationID` falls back in its entirety —
    including discarding X's already-produced schemata record — and its
    final ledger entry comes from isolated mode only, joining the same
    all-or-nothing mechanism §4(b) already requires for hang-budget
    overflow.
12. **Recovery-rebuild typed `BuildFailure`, in-flight `MutationID`s.**
    A timeout-triggered mid-chunk rebuild (§4(d)) itself fails with a
    typed `BuildFailure`. Assert every affected not-yet-fully-finalized
    `MutationID` (including one mid-confirmation when the rebuild
    failure occurs) falls back to isolated mode, and that already-fully-
    finalized, unrelated `MutationID`s in the same chunk keep their
    existing schemata-derived verdicts untouched.
13. **Untyped recovery failure, unaffected.** A sandbox-recreation or
    untyped build error during recovery rebuild still routes to
    `infrastructureFailureResult`, exactly as §4(d) already specifies —
    confirms this amendment did not widen isolated-fallback routing
    beyond the one changed shape.
14. **Receipt-resolution failure, unaffected.** Confirms the existing
    `nil`-receipt fail-closed path is untouched.
15. **Verifier-authority regression, extended.** Extends §5 item 7 to
    cover this amendment's new fallback trigger: assert no verdict is
    constructed anywhere in the shared-chunk-build-failure → isolated-
    fallback path except through the normal isolated
    `MutationRunner` → `MutationVerdictVerifier` call.
16. **Bool literal case-pattern regression** (validates fix 1 in
    "Scope" above, tracked as a separate implementation item but
    acceptance-tested alongside this amendment since both close the same
    real-corpus finding): a boolean literal in switch case-pattern
    position is not lowered for schemata embedding (routes to planner-
    time fallback); an ordinary boolean-literal expression at any other
    syntax position is embedded exactly as today.

### Real-corpus regression (in addition to §5's existing promotion-gate corpus requirements)

Pin the exact `swift-argument-parser` commit and plan already used for
this diagnosis (see the findings doc). Before this amendment (and before
the case-pattern eligibility fix): 118 false `.unviable` verdicts from
one shared chunk build failure. Required after implementing both fixes
in "Scope": **zero** false-`.unviable` attribution on this corpus — i.e.
either (a) the case-pattern candidates no longer get embedded at all
(planner-time fallback, so this specific chunk never fails to compile),
and/or (b) if any other shared-chunk build failure occurs for any
reason, every affected `MutationID` receives its final verdict from an
isolated-mode rerun, never a direct chunk-failure-projected `.unviable`.

### Fan-out / observability requirement (new, not in original §5)

A shared-chunk build failure can affect many `MutationID`s at once
(118, in the triggering case). Isolated-mode fallback at this scale must
not be invisible: implementation must report, per triggering chunk, the
`MutationID` count affected and a reference to the chunk-level compiler
diagnostic that caused it (§ "`SchemataFallbackReason` — new case") —
one aggregate event per failed chunk, not 118 individually-unremarkable
fallback log lines with no shared cause visible.

**Scope, corrected after review** (this addendum's first Codex
architecture review flagged an inconsistency here, fixed as follows):
this requirement covers only the `sharedChunkBuildFailure` trigger this
addendum introduces. It deliberately does **not** claim to cover the
other three §4(d) shapes — those already have their own existing,
unchanged dispositions today (sandbox-creation error and untyped build
error each become `infrastructureFailureResult` per-`MutationID`;
receipt-resolution failure is caught with `try?` and proceeds with a
`nil` receipt under the existing fail-closed unresolved-mapping path,
neither of which this addendum touches) — and improving *their*
aggregate observability (e.g. for a systemic, corpus-wide infrastructure
defect that happens to manifest as many individual untyped-build-error
records rather than a single shared-build compile
failure) is a legitimate but separate concern, out of scope for this
addendum — left here as a note for a future observability improvement,
not silently assumed to already be covered.

**No run-wide execution-time exclusion is required or implied.** The
production `SchemataMutationRunner.run()` executes every program in a
chunk's plan unconditionally before any fallback-ID aggregation happens
(`SchemataMutationRunner.swift:193-228`); fallback IDs are only
collected and every one of their schemata records discarded
*afterward* (`:230-256`). This addendum's rule does not require adding
a new mid-run scheduling exclusion that preemptively skips a
`MutationID` in a not-yet-executed program once some other program has
already triggered fallback for it — doing so would be new machinery
this addendum does not need. Correctness is already guaranteed by the
existing final all-or-nothing withdrawal: whatever any program produces
for a `MutationID` later marked for fallback is discarded at
aggregation regardless of execution order, exactly as today's dynamic
no-HIT/no-STARTUP fallback already relies on. This addendum makes no
claim about, and does not require any change to, whether/how a future
resumed or checkpointed invocation avoids re-attempting a `MutationID`
already known from a prior run to trigger this fallback — that is a
separate question this addendum does not address.
