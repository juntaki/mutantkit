# ADR-0007: Budget Selection v2 — discovery audit and draft spec

- **Status:** Draft, revision 8 — discovery + spec only, no implementation.
  B.2's allocator algorithm (the core selector spec) reached
  **Critical=0/High=0 as of revision 5**, reconfirmed clean through
  revisions 6, 7, and 8 — untouched since. B.9's evaluation-metric
  proxy-dependence screen went through 3 further redesign rounds (revisions
  6, 7), each closing one statistical-design gap and surfacing another
  (revision 7's re-review: Critical=0/High=2/Medium=5/Low=0, two genuine
  Highs). **This revision (8) defers B.9's exact statistical procedure to
  task #25** (the milestone's own real-protocol-freeze step, where concrete
  metrics/corpora make correct design tractable) rather than attempting a
  fifth abstract redesign — freezing the *requirement* and *constraints*
  the eventual procedure must satisfy, not the procedure itself. See the
  Status section below for the full rationale. Pending re-review; not
  accepted.
- **Date:** 2026-08-14/2026-08-15 (across all eight revisions)

This document has two parts: a ground-truth audit of the existing Budget
Selection ("v1") implementation, read directly from the code (not from any
prior doc/README summary), and a draft spec for a v2 redesign built on that
audit. Per the process this ADR follows, v2 implementation does not start
until Critical=0/High=0 on independent review of this document, the
unresolved choices below are explicitly closed one way or another, and the
acceptance/evaluation criteria are frozen.

---

## Part A: v1 audit

### A.1 Entry points

`mutantkit plan` (`Sources/CLI/Commands/PlanCommand.swift`) calls
`MutationPlanner().makePlan(...)`. Inside `makePlan`
(`Sources/MutationPlanner/MutationPlanner.swift:72-132`), three gates run in
a fixed, hardcoded order:

```swift
(surviving, skipped) = applyConfidenceGate(surviving, skipped, resolution: resolution)
(surviving, skipped) = applyDiffGate(surviving, skipped, diffScope: diffScope)
(surviving, skipped) = try applyBudgetGate(surviving, skipped, budget: configuration.execution.budget)
```

Budget selection is the last gate — it only ever sees points that already
survived the confidence floor and diff scope. `applyBudgetGate` (line
273-335) is the sole caller of `BudgetSelector`; nothing else in the
codebase touches it.

`mutantkit run` never calls `MutationPlanner`/`BudgetSelector` at all — it
loads `plan.json` from disk and executes `plan.mutations` as-is. **Budget
selection happens exactly once, entirely inside `plan`, and is frozen into
the plan file.**

### A.2 Configuration surface

`BudgetSettings` (`Sources/MutationModel/Configuration.swift:258-320`):

| Field | Type | Default | Notes |
|---|---|---|---|
| `maxMutants` | `Int?` | `nil` | `nil` = no budget gate. Must be `>0` (enforced both at config-validation time and as a hard `PlannerError.invalidBudget` throw in `applyBudgetGate`). |
| `maxDurationSeconds` | `Double?` | `nil` | **Not a planning input.** Never read by `BudgetSelector`/`applyBudgetGate` — consumed only by the executor's wall-clock stop condition at run time, a fully separate mechanism. |
| `seed` | `UInt64?` | `nil` | Only source of pseudo-randomness allowed. `nil` → deterministic non-random strategies. |
| `stratifyBy` | `BudgetStratification?` | `nil` | `nil` / `.subtype` / `.operatorSubtype` — three distinct algorithms, see A.3. |
| `minimumPerOperator` | `Int?` | `nil` (→`1` at use site) | Only meaningful under `.operatorSubtype`. |

`ConfigurationValidation.swift:validateBudgetSampling` errors if
`stratifyBy: .operatorSubtype` is set without `maxMutants`, errors if
`minimumPerOperator < 1`, warns if `minimumPerOperator` is set under any
other mode. Legacy keys (`sampling`/`stratifyWithinOperatorBy`, an earlier
same-day-superseded design) decode as a hard `DecodingError`, not silently
ignored.

### A.3 Selection algorithm

`applyBudgetGate` is a no-op whenever `points.count <= maxMutants` — budget
selection only ever activates when the pool genuinely exceeds the limit.
Otherwise it dispatches on `stratifyBy`:

- **`.operatorSubtype`** → `BudgetSelector.selectByOperatorSubtype`, three
  deterministic phases: (1) round-robin minimum reservation across
  operators in `seededOrder`, one slot per operator per round (chosen
  specifically to avoid starving late-sorting operators when the budget
  can't cover every minimum); (2) largest-remainder proportional split of
  whatever's left, over each operator's remaining candidate capacity, ties
  broken by operator ID string (this phase's *sizing* is not seed-dependent
  — only which operator gets the extra slot from rounding is); (3) each
  operator's assigned slot count filled via `stratifiedBySubtype` scoped to
  that operator's own candidates.
- **`.subtype` or `nil`** → `BudgetSelector.select(stratifyBy:)`:
  - `.subtype` → round-robin over `(operatorID, originalText,
    replacementText)` strata in **alphabetical** stratum order (a
    documented, permanent limitation — known to starve late-sorting strata
    under a tight budget, kept as-is for backward compatibility; this is
    exactly why `.operatorSubtype` exists).
  - `nil` + `seed` set → pure seeded uniform sample: each point draws a key
    from `SplitMix64(seed XOR FNV1a64(point.id))`, lowest `limit` keys win,
    ties by ID. Key is a function of `(seed, own ID)` only — never of what
    else is in the population.
  - `nil` + no seed (**the true default**) → round-robin over files, then
    operators within file, sorted by ID within each group. Doc comment
    explicitly rejects "first N by ID" as arbitrary; goal stated as "every
    file contributes its first mutant before any file contributes its
    second."

### A.4 Scoring/ranking

There is no per-mutant score. The only per-mutant signal consumed is
identity (`MutationID`, used as PRNG key and tie-break/sort key) and
grouping keys (`file`, `operatorID`, `(operatorID, originalText,
replacementText)`, used only for round-robin bucket membership, never to
rank within a bucket). No historical kill/survive rate, no coverage, no
estimated cost, no complexity metric — confirmed by reading every
`BudgetSelector` function signature; none accept anything beyond
`[MutationPoint]`, `limit`, `seed`, `stratifyBy`, `minimumPerOperator`.

### A.5 Cost/budget accounting

Budget is pure mutant *count*. `maxDurationSeconds` exists in config but is
never a selection input — see A.2. There is no "spend" that decrements
during selection: selection is a one-shot filter to exactly `limit` (or
fewer, if the pool is already smaller).

### A.6 Historical-data inputs

**None whatsoever.** No `BudgetSelector` function accepts a cache, a
`RunReport`, a kill-rate map, or any reference to
`MutationResultCache`/`TestPriorityStore` — those types exist but are used
only inside `RunCommand.swift`/`MutationRunner.swift` at execution time
(result caching, test-ordering within a mutant's own run), never passed to
or read by anything in `MutationPlanner.swift`.

### A.7 Coverage inputs

**None at the selector level.** `measureCoverage`/`selectCoveringTests`
(`ExecutionSettings`) are consumed entirely inside `MutationRunner`
(baseline coverage measurement, per-mutant test narrowing at *execution*
time) — never referenced in `MutationPlanner.swift`/`BudgetSelector`.
Budget selection is coverage-blind by construction today.

### A.8 Deterministic ordering/tie-breaking

Genuinely deterministic — verified both by code reading and by executable
characterization (A.11) — **for inputs with unique `MutationID`s**. The
only RNG is `SplitMix64` seeded from `seed XOR FNV1a64(identity)` (Swift's
non-reproducible `Hasher` explicitly avoided, per a pinned regression
test). Every tie-break falls back to ID string comparison. Under a
duplicate-ID input (A.14), the comparator cannot distinguish the two
colliding points, so which one occupies a limited slot can depend on input
order — this is visible even in seeded sampling, since the two points draw
their `SplitMix64` keys from the same identity string and only differ by
whatever incidental ordering the caller happened to provide. The
determinism/order-independence claim in this section is proven only for
unique-ID inputs; A.14 already establishes that duplicate IDs are outside
what v1 defends against, and this is the same boundary. `discoverConcurrently`
explicitly re-sorts by ID before any gate runs, specifically so `TaskGroup`
completion-order nondeterminism never reaches `BudgetSelector`. Input-order
independence (forward / reversed / shuffled) was confirmed experimentally
for all three modes, always with unique-ID fixtures. No wall-clock, no
`Date()`, no environment value enters selection — `createdAt` is
explicitly excluded from `planID` for the same reason.

### A.9 Sharding interaction

Budget selection happens strictly *before* sharding.
`PlanSharding.shard` operates on the already-materialized,
post-budget-gate `MutationPlan.mutations` and partitions by
`FNV-1a(mutation.id) % shardCount`. Shard count never feeds back into
selection. **Running under N shards vs. 1 shard for the same plan always
selects the identical mutant set** — sharding only changes distribution.

### A.10 Resume/checkpoint interaction

Selection never re-runs at resume time. The checkpoint URL is keyed by
`RunContextFingerprint + plan.workUnitID`, and `workUnitID` is itself a
hash of `planID + sorted mutation IDs` — i.e. a hash of the already-selected
set. `--no-resume` deletes only the checkpoint file, never touches
`plan.json` or re-invokes the planner. A resumed run always honors the
frozen selection; there is no reselect-on-resume path anywhere in this
codebase.

### A.11 Reporting/output

`PlanCommand` prints a skip-reason tally (including `.budgetExceeded`
count) and `OperatorBudgetSummary` output, but only when at least one
operator has `budgetDropped > 0` — silent otherwise. Every
budget-dropped mutant carries a human-readable `SkippedMutation.detail`
string persisted in `plan.json`, naming the strategy, seed (if any), and —
for `.operatorSubtype` — the exact assigned/candidate counts for that
mutant's operator. This is a genuine, persisted per-mutant audit trail for
drops. **There is no equivalent trail for inclusions** — why a mutant
survived the budget gate is reconstructable only by re-deriving the
algorithm, not by reading a field on the mutant itself.

### A.12 Tests and fixtures

`Tests/MutantKitTests/Unit/BudgetSelectorTests.swift` (three `@Suite`s,
~35 tests) pins: seeded-selection stability, cross-seed variation,
per-item-keyed sampling's population-independence, round-robin correctness
across files/operators/strata, exact-limit respecting, "limit larger than
population keeps all," partition (`selected ∪ dropped == input`,
disjoint), sorted output, PRNG reproducibility/differentiation, and — for
`.operatorSubtype` specifically, citing a real production incident
(`Research/corpus-validation/yomu-2026-07-24/`: 1242 candidates, 0 drawn
for two entire operators at budget 100) — every-operator-represented,
minimum-honored, reversed-input-order-identical, remainder-proportionality,
seed-sensitivity, and scarce-budget determinism.
`OperatorBudgetSummaryTests.swift` (4 tests) pins `OperatorBudgetSummary`
correctly deriving `eligible/selected/budgetDropped` from
`plan.mutations`/`plan.skipped`.

**Not tested** (real gaps): duplicate `MutationID`s reaching the selector
(see A.13); the gate-composition interaction of
`applyConfidenceGate`/`applyDiffGate` output feeding `applyBudgetGate`
(only `BudgetSelector` in isolation is tested); the
`PlannerError.invalidBudget` path.

### A.13 Known edge cases / implicit assumptions

- `.subtype`'s alphabetical-stratum-order starvation is a **documented,
  intentional, permanent** limitation, kept for additive backward
  compatibility — not a bug, but not fair either.
- `selectByOperatorSubtype` has an explicit `preconditionFailure` guard
  against being called for the wrong mode — currently unreachable given the
  single call site, but a real defensive assertion, not dead code.
- `seededOrder`'s base key order is always alphabetical regardless of
  dictionary iteration, specifically to prevent iteration-order leakage.

### A.14 Duplicate-`MutationID` finding (new, from executable characterization)

Two distinct `MutationPoint`s sharing one `MutationID` (constructed
synthetically — different `file`, same ID string), fed to `BudgetSelector`
with `limit: 1`: **`selected.count == 1`, `dropped.count == 0`** — one of
the two points vanishes entirely, uncounted, with no violation raised, no
skip record, no console output. `dropped = points.filter { !selectedIDs
.contains($0.id) }` computes `selectedIDs` as a `Set<MutationID>` (size 1
since both points collide), so the *second* point — never actually
selected — gets filtered out of `dropped` too, because its ID is "already
accounted for." `IntegrityChecker.validatePlan` only checks
`plan.mutations` (the final, already-deduplicated-by-construction list) for
duplicates, and never checks `plan.skipped` at all, so this never fires as
an integrity violation. **This breaks the codebase's own stated promise**
(`MutationPlan.swift`: "Skips are part of the plan rather than a silent
omission") under a duplicate-ID input. Whether this is *reachable* in
practice — whether `MutationID`'s content-hash construction can produce a
genuine collision between two structurally different points, or whether a
discovery bug elsewhere could hand the budget gate two such points — was
**not** audited this pass (out of the pinned scope: `MutationDiscovery`/
`MutationID` construction). Flagged as a follow-up, not asserted as
currently exploitable.

### A.15 Responsibility-boundary verification

All four verified directly against code, not assumed:

1. **Selector decides only what to execute, never influences
   classification.** Holds — `BudgetSelector`'s only outputs are
   `selected`/`dropped` `MutationPoint` lists; nothing it returns is a
   verdict or score. Dropped points become `SkippedMutation` records that
   never reach `MutationRunner`/`MutationVerdictVerifier`.
2. **`MutationRunner` (not the selector) executes.** Holds —
   `MutationExecution` has zero dependency on `MutationPlanner`; `run`
   operates purely on the plan already loaded from disk.
3. **`MutationVerdictVerifier` is the sole verdict authority.** Holds, by
   its own doc comment: "the only place a mutation's outcome is decided."
   Never referenced by `BudgetSelector`/`MutationPlanner`.
4. **Selector cannot fabricate a `MutationID`.** Holds by construction —
   every output is a filter/sort over the exact input array, nothing
   synthesized. Caveat: A.14's duplicate-ID finding means the *partition*
   guarantee (not the no-fabrication guarantee) can silently break under a
   malformed input the selector doesn't defend against.

### A.16 Synthesis: invariants v1 currently guarantees

- Determinism: same `(points, limit, seed, stratifyBy, minimumPerOperator)`
  → byte-identical output, independent of input order.
- No system RNG — only seeded `SplitMix64`.
- Exact partition *for unique-ID inputs* (not defended for duplicates).
- Limit respected exactly when the pool exceeds it; no-op otherwise.
- Sorted output (both `selected` and `dropped`).
- Selector is a strict filter, never a generator.
- Fixed gate order: confidence → diff → budget, always.
- Selection frozen at plan time; sharding/resume never alter it.

### A.17 Synthesis: what v1 does NOT guarantee

- Unique `MutationID`s in the selector's input (assumed, not enforced or
  fully caught downstream).
- Any proportionality under plain/default mode — the "balance" it produces
  is incidental to round-robin-by-file/operator bucket geometry, not a
  designed fairness contract. Only `.operatorSubtype` makes an explicit,
  tested fairness claim.
- Any inclusion-reason trail (only drops are explained).
- Any relationship between `maxDurationSeconds` and `maxMutants` — a
  time-budgeted run has zero planning-time selection logic.
- `.subtype`'s alphabetical order is fair under a tight budget (known,
  accepted limitation).

---

## Part B: v2 draft spec

### B.1 Frozen invariants (fixed before the objective function — these constrain any design choice below, not negotiable in this round)

1. `MutationVerdictVerifier` remains the sole mutation-verdict authority.
   Budget v2 never touches verdicts, evidence, or classification.
2. The budget selector decides only *what to execute* — never *how* it gets
   executed or scored once selected.
3. Same inputs → same selection, always (byte-identical, not
   "statistically similar"), for unique-`MutationID` inputs (A.8's proven
   boundary; see invariant 4 for the duplicate-ID case).
4. The selector never generates a `MutationID` outside the plan it was
   given — output is always a strict subset filter. A duplicate-`MutationID`
   input is an explicit precondition violation: the selector must **reject
   it** (throw, not silently drop one twin — closing A.14, not just noting
   it). This is a normative requirement on the v2 implementation, not
   optional hardening: any v2 acceptance test suite must include a
   duplicate-ID input and assert rejection, not merely assert correct
   behavior on well-formed input.
5. The selector never causes actual budget overrun by design (no mode may
   select more than `limit`, ever, regardless of rounding/remainder
   handling) — see invariant 11 for the mechanism this is built on, closing
   Codex High #1.
6. Every selection decision — inclusion and exclusion alike — is
   explainable via a machine-readable trail (closing A.11's inclusion-side
   gap), not just drops — see B.7 for the normative schema requirements
   this now carries.
7. The selector works fully deterministically with **zero** history
   available (no history is not an error state, and its absence never
   introduces nondeterminism or a crash). As of this revision (closing
   Codex High #2), this is trivially satisfied: v2 in this cut consumes
   **no** historical or outcome-derived data at all — see invariant 12 and
   B.5.
8. v1's existing behavior is not broken: v1's default/`.subtype`/
   `.operatorSubtype` modes remain available and byte-identical to today's
   output for existing configs (additive, not a replacement) — a v1-shaped
   config keeps producing v1's plan.
9. Sharding never changes selection semantics — selection stays
   plan-time-only, exactly as in v1 (A.9). This also binds the new
   inclusion-reason trail (invariant 6): it must be computed once at
   planning time and be immutable/identical across shards and resumes — see
   B.7's normative shard/resume-stability requirement, closing Codex Medium
   #5.
10. v2 must not let optimizing its own objective degrade mutation-testing
    quality by preferring easy-to-kill mutants merely to look good on a
    score. Combined with invariant 12 (no outcome-derived data at all in
    this cut), this failure mode has no data channel to act through in the
    current spec — see B.5's closure and B.9's evaluation-design fix
    (closing Codex High #3) for how this is verified rather than merely
    asserted.
11. **(new, revised again closing Codex re-review's remaining High)** Any
    v2 stratification/allocation algorithm is bounded to exactly two
    allocation levels (an outer stratification dimension, and — only if the
    outer stratum's assigned slot count is itself further subdivided — one
    inner dimension scoped to that stratum's own candidates). Arbitrary/
    unbounded-depth hierarchical stratification is out of scope for this
    spec. Budget conservation across those two levels is a **compositional**
    property, not a single shared mutable counter threaded across levels
    (the re-review found "one shared counter" an inaccurate description of
    what a correct recursive implementation actually does — see B.2):
    - Every child (inner-stratum) budget is drawn from, and sums to no more
      than, its parent (outer-stratum) assigned slot count.
    - Every child's own selection never exceeds its own child budget.
    - The root (outer) selection never exceeds `limit`.
    - In count-based mode (the only mode this spec covers, B.3), the total
      selected count is exactly `min(limit, total eligible candidate
      count)` — never less when the pool is smaller than the budget, never
      more when it's larger.

    See B.2 for the normative, mechanically-checkable algorithm and the
    proof sketch establishing all four properties.
12. **(new, closing Codex High #2)** v2, as specified in this ADR, consumes
    **zero** historical or outcome-derived data of any kind: no kill/survive
    verdicts, no `MutationResultCache` reads, no execution-frequency or
    build-timing signals, no proxy correlated with any of those. Any future
    mechanism that uses such data requires a separate ADR with its own
    dedicated gaming-resistance review — it is explicitly not part of this
    v2 cut. See B.5.
13. **(new, closing Codex High #3)** No evaluation metric used to declare
    v2 accepted may be structurally identical to, or a direct restatement
    of, v2's own selection objective (e.g. "breadth across dimension X"
    cannot be both what the allocator optimizes for AND the metric that
    proves it worked). At least one primary acceptance metric must be
    computed from real post-execution results (actual kill/survive/build
    outcomes from running the selected set), not from the selection itself.
    Any corpus-informed tuning of allocator parameters (which dimensions,
    minimums, hierarchy order) requires the same holdout discipline as
    history-informed tuning (B.10), without exception. See B.9.

### B.2 Objective function

**Revised a second time in response to Codex re-review of revision 2.**
Revision 2's fix for High #1 still had real gaps, found on re-review: phase
1's prose claimed "round-robin, one slot per round" but its pseudocode
actually granted a stratum's *entire* minimum in one visit — different
from, and less fair than, v1's real one-slot-per-round behavior under a
tight budget with `minimumPerStratum > 1`. Phase 2 invoked
`distributeLargestRemainder` without ever defining it, so the "never
exceeds `limit`" postcondition was still asserted, not derivable. And
invariant 11's "one shared counter threaded through both levels" turned out
to be an inaccurate description of what a correct recursive
implementation actually does (each recursive call necessarily has its own
bounded child counter, not literally the same mutable counter as its
parent) — this revision replaces that framing with the compositional
invariants now stated in B.1, item 11.

**Failure modes this revision closes:** (a) phase 1 not actually behaving
as one-slot-per-round, changing fairness outcomes under tight budgets from
what the spec claimed; (b) an undefined helper function making the
overrun-safety postcondition unverifiable against the document; (c) a
literally-false "one shared counter" claim, now replaced with a proof
structure that matches what recursive composition actually does.

**Normative spec — mechanically complete, no undefined helpers:**

1. **Fixed two-level hierarchy**, unchanged from the prior revision: one
   *outer* stratification dimension, and, only if configured, exactly one
   *inner* stratification dimension scoped to each outer stratum's own
   candidates. Recursion depth is fixed at 2 (invariant 11).

2. **`allocateCounts`** — decides *how many* slots each stratum gets, split
   by which phase granted them (`PhaseSplit`), never *which* mutants.
   **Revised a third time, closing Codex re-review's remaining High finding
   (floating-point Phase 2 arithmetic) and Medium finding #1 (incomplete
   exact-fill proof)**, using an exact-integer capacitated
   largest-remainder algorithm — no `Float`/`Double` anywhere in Phase 2:

   ```
   struct PhaseSplit { phase1: Int; phase2: Int }
   # total(split) = split.phase1 + split.phase2

   function allocateCounts(strata, limit, seed, minimumPerStratum, candidateCount, weight):
       # Degenerate cases, defined explicitly:
       if limit <= 0 or strata.isEmpty:
           return {s: PhaseSplit(0, 0) for s in strata}

       split = {s: PhaseSplit(0, 0) for s in strata}
       remaining = limit

       # ---- Phase 1: one-slot-per-stratum-per-round minimum reservation ----
       # (unchanged from the prior revision — already confirmed correct by
       # re-review, including a worked example: 3 strata, minimumPerStratum=3,
       # limit=5, order=[A,B,C] -> grants A1,B1,C1,A2,B2 -> {A:2,B:2,C:1},
       # never more than one slot per stratum before every other eligible
       # stratum has had a turn in the same round.)
       order = seededOrder(strata, seed)
       loop:
           grantedThisRound = false
           for stratum in order:
               if remaining == 0: goto phase2
               if split[stratum].phase1 >= minimumPerStratum: continue
               if split[stratum].phase1 >= candidateCount[stratum]: continue
               split[stratum].phase1 += 1
               remaining -= 1
               grantedThisRound = true
           if not grantedThisRound: goto phase2

       phase2:
       # ---- Phase 2: iterative capacitated largest-remainder, EXACT INTEGERS ONLY ----
       # `weight` is an optional per-stratum config (B.3), REVISED (closing
       # Codex re-review High #2): weight is EITHER fully unconfigured
       # (equal-share for everyone) OR every configured value is a positive
       # integer >= 1 -- there is no "explicit zero opts a stratum out"
       # mode. That mode was removed: it made the exact-fill target
       # ambiguous (does "eligible" include a permanently-excluded
       # stratum's candidates or not?) without adding anything no other
       # mechanism already covers -- a caller who genuinely never wants a
       # stratum represented in Phase 2 can simply omit it from `strata`
       # entirely, upstream of this call. Determined ONCE, before any
       # iteration, never recomputed mid-loop:
       useEqualWeight = (weight.isEmpty)   # nothing configured at all -> every
                                             # stratum gets effectiveWeight 1.
                                             # If ANYTHING is configured, every
                                             # stratum in `strata` MUST have a
                                             # configured weight >= 1
                                             # (validated at config-load time,
                                             # see the overflow-safety note
                                             # below) -- a config with any
                                             # stratum's weight unset while
                                             # others are set, or any weight
                                             # of 0, is a config-load error,
                                             # not a runtime fallback.

       # E = strata still eligible for a Phase-2 grant: positive residual
       # capacity only. Weight can never remove a stratum from E (unlike
       # the removed zero-weight design) -- "eligible" always means the
       # full candidate pool, keeping the exact-fill proof below simple and
       # matching revision 3's original guarantee.
       E = {s in strata : candidateCount[s] - split[s].phase1 > 0}
       R = remaining
       remainderVal = {}   # last-computed remainder per stratum still in E

       while R > 0 and E.isNotEmpty:
           effectiveWeight = {s: (1 if useEqualWeight else weight[s]) for s in E}
           W = sum(effectiveWeight.values())
           # W > 0 always: E is non-empty (loop guard), and every s in E has
           # effectiveWeight >= 1 (equal-weight mode, or a validated >=1
           # configured value) -- structurally unreachable to divide by
           # zero, not a runtime check.

           grantThisRound = {}
           for s in E:
               residualCapacity = candidateCount[s] - split[s].phase1 - split[s].phase2
               numerator = R * effectiveWeight[s]     # Int64+ arithmetic -- see
                                                        # overflow-safety note below
               floorShare = numerator / W              # integer division, truncating
               remainderVal[s] = numerator % W          # exact integer remainder
               grantThisRound[s] = min(floorShare, residualCapacity)

           for s in E: split[s].phase2 += grantThisRound[s]
           R -= sum(grantThisRound.values())

           newlySaturated = {s in E : candidateCount[s] - split[s].phase1 - split[s].phase2 == 0}
           E = E - newlySaturated

           if newlySaturated.isEmpty:
               break   # REVISED (closing Codex re-review High #1): the
                        # break condition is now "no stratum became newly
                        # saturated this round" -- NOT "no stratum was
                        # clipped." The prior revision broke on
                        # `not anyClipped` (grant < floorShare), which
                        # missed the case where a floor grant EXACTLY
                        # matches a stratum's remaining capacity (not
                        # "clipped" by that narrower definition, yet still
                        # saturating the stratum) -- that case still needs
                        # another round's redistribution over the shrunken
                        # `E`, exactly like a clipped stratum does, or the
                        # leftover pass below can be handed a `leftover`
                        # count larger than the (now smaller) `E` has room
                        # for. Breaking only when `newlySaturated` is
                        # genuinely empty guarantees every `s` still in `E`
                        # at break time has strictly positive spare
                        # capacity post-grant (see the proof below) and
                        # that `E` was not reduced this round, so the
                        # leftover pass's Hamilton bound applies to the
                        # exact same `E` the remainders were computed
                        # against -- not a stale, larger `E` from before
                        # this round's removals.
           # Whenever `newlySaturated` is non-empty (whether from clipping
           # OR from an exact floor/capacity match), |E| strictly
           # decreases -- bounded by |strata|, so this loop always
           # terminates within at most |strata| iterations either way.

       # ---- Leftover single-slot distribution: EXACT INTEGER comparison only,
       # descending remainderVal, ties broken by ascending deterministic
       # stratum key. Never Float/Double, per explicit requirement. Only
       # reached when the round that produced `remainderVal` left `E`
       # UNCHANGED (the break above), so the Hamilton bound (proof below)
       # applies validly. ----
       if R > 0 and E.isNotEmpty:
           order2 = sorted(E, key: (-remainderVal[s], s.deterministicStratumKey))
           i = 0
           while R > 0 and i < len(order2):
               s = order2[i]
               residualCapacity = candidateCount[s] - split[s].phase1 - split[s].phase2
               if residualCapacity > 0:
                   split[s].phase2 += 1
                   R -= 1
               i += 1

       return split
       # postcondition (proved below): sum(total(split[s]) for s in strata)
       #                                == min(limit, sum(candidateCount.values()))
   ```

   **Overflow-safety (normative, closing the "validated numeric bounds"
   requirement, Codex re-review Medium #1 — `W`/aggregate sums also need a
   bound, not just the per-stratum numerator — and a Low finding on the
   next re-review correcting the bound's own derivation):** `remaining`/
   `limit`/`R` are always `<= 2^31`, and — newly stated normatively —
   `sum(candidateCount.values())` is likewise always `<= 2^31`, under any
   realistic corpus this project's own config validation already assumes
   (mirroring existing `Int`-based mutation counts throughout
   `MutationModel`). **Correction**: the bound on `W` must be derived via
   `|E|`, not `|strata|` — a stratum may legitimately have
   `candidateCount == 0` (an explicit degenerate test case, B.2's
   acceptance-test implication), so `|strata| <= sum(candidateCount.values())`
   is not itself guaranteed. `E`, however, is defined as strata with
   strictly positive residual capacity (B.2 step 2), so `|E| <= total
   residual capacity <= sum(candidateCount.values()) <= 2^31` always
   holds, and `W` only ever sums `effectiveWeight` over `E` (never over
   all of `strata`) — so this is the correct chain, not a gap. Every
   configured `weight` value must be validated at configuration-load time
   to lie in `1...1_000_000` (mirroring `ConfigurationValidation.swift`'s
   existing style of bounded numeric range checks — an explicit config
   error, not a runtime crash, for a value outside this range, **including
   `0`**, which is no longer a valid configured value at all per the
   redesign above). Under these bounds: `numerator = R * effectiveWeight[s]
   <= 2^31 * 10^6 ≈ 2.1×10^15`; `W = sum(effectiveWeight.values() for s in
   E) <= |E| * 10^6 <= 2^31 * 10^6 ≈ 2.1×10^15` (the same bound, since `|E|
   <= 2^31`) — both safely within `Int64` (`~9.2×10^18`) with wide margin.
   All Phase 2 arithmetic
   (`numerator`, `W`, `floorShare`, `remainderVal`) must use a 64-bit or
   wider signed integer type. No cross-multiplication is needed to compare
   `remainderVal` values across strata (unlike a naive per-stratum-
   denominator design): every stratum's `remainderVal` in a given round is
   computed against the **same shared `W`**, so `remainderVal[s]` values
   are directly, exactly comparable as integers without any denominator-
   normalization step — this is the structural fix that eliminates the
   floating-point
   comparison problem at its root, not just a "use integers instead of
   floats" surface patch.

3. **`allocate`** — the outer driver, turning `PhaseSplit` counts into
   actual selected `(MutationPoint, InclusionReason)` pairs, and the one and
   only place recursion happens. `reasonCode` is defined here **normatively**
   (closing Codex re-review Medium #2): it reflects the phase of the
   **terminal** (deepest / actually mutant-selecting) `allocateCounts` call
   — the inner call's own `PhaseSplit` when an inner dimension is
   configured, otherwise the outer call's:

   ```
   function allocate(strata, limit, seed, minimumPerStratum, candidateCount, weight,
                      innerDimension?, innerMinimumPerStratum?, innerWeight?):
       counts = allocateCounts(strata, limit, seed, minimumPerStratum, candidateCount, weight)
       selected = []   # [(MutationPoint, InclusionReason)]
       for stratum in strata.sorted(by: id):      # deterministic output order, always
           split = counts[stratum]
           n = split.phase1 + split.phase2
           if n == 0: continue      # normative: a zero-count stratum makes NO
                                      # inner call at all (closes the
                                      # "zero-slot/empty-inner" gap directly)
           if innerDimension is set:
               innerStrata = subStrata(stratum, innerDimension)
               innerCandidateCount = {s: candidateCount(s) for s in innerStrata}
               # The one and only permitted recursive call. Its `limit`
               # parameter is `n` -- the OUTER call's own already-bounded
               # output for this stratum, never a fresh independent budget.
               # It never itself receives an `innerDimension` argument, so a
               # third level can never occur (invariant 11).
               innerCounts = allocateCounts(innerStrata, n, seed, innerMinimumPerStratum,
                                             innerCandidateCount, innerWeight)
               for innerStratum in innerStrata.sorted(by: id):
                   innerSplit = innerCounts[innerStratum]
                   candidates = fill(innerStratum, innerSplit.phase1 + innerSplit.phase2, seed)
                   for (ordinal, point) in candidates.enumerated():   # ordinal: 0-based
                       reasonCode = minimumReservation if ordinal < innerSplit.phase1 else proportionalRemainder
                       selected.append((point, InclusionReason(
                           mutationID: point.id, reasonCode: reasonCode,
                           stratumPath: [stratum.id, innerStratum.id], selectionOrdinal: ordinal)))
           else:
               candidates = fill(stratum, n, seed)
               for (ordinal, point) in candidates.enumerated():
                   reasonCode = minimumReservation if ordinal < split.phase1 else proportionalRemainder
                   selected.append((point, InclusionReason(
                       mutationID: point.id, reasonCode: reasonCode,
                       stratumPath: [stratum.id], selectionOrdinal: ordinal)))
       return selected
   ```

4. **`seededOrder(strata, seed)`** (normative, deterministic ordering):
   the base order is always `strata.sorted(by: id)` (alphabetical/
   lexicographic by stratum identity). If `seed` is set, this base order is
   itself re-permuted by sorting on `(SplitMix64(seed XOR
   FNV1a64(stratum.id)).key, stratum.id)` — the same construction B.4
   already specifies for per-mutant tie-breaks, applied one level up to
   strata themselves. No other source of ordering is permitted anywhere in
   `allocateCounts`/`allocate`.

5. **`fill(stratum, count, seed)`** (unchanged from B.4 / v1's existing
   tie-break, restated here for completeness): `stratum.candidates.sorted(by: id).prefix(count)`
   when `seed` is nil; otherwise `stratum.candidates.sorted(by: (SplitMix64(seed XOR FNV1a64(id)).key, id)).prefix(count)`.
   Its output order is exactly what `selectionOrdinal` (step 3) indexes into.

**Proof — the four compositional invariants (B.1 item 11), fully
established from the algorithm above, addressing Codex re-review's Medium
#1 finding that the prior proof had a false claim and a missing branch:**

*Key lemma — Phase 2's conserved quantity.* Define, at any point during
Phase 2, `D = totalCapacity(E) - R` where `totalCapacity(E) = sum(candidateCount[s]
- split[s].phase1 - split[s].phase2 for s in E)`. **`D` is invariant
(constant) across every round of the while-loop and every grant in the
leftover pass**: each grant of size `g` to any `s` decrements `R` by `g`
(direct accounting) and simultaneously decrements `candidateCount[s] -
split[s].phase1 - split[s].phase2` — and hence `totalCapacity(E)` — by
exactly `g` too, so `totalCapacity(E) - R` is unchanged by any single
grant, in either the main loop or the leftover pass. `D` is therefore fixed
at whatever value it has the instant Phase 2 begins:
`D_0 = totalCapacity(E)_{start} - remaining_{after phase 1}`.

- *Root selection never exceeds `limit`, in both phases, without a case
  split*: every unit added to `split[s].phase1` or `split[s].phase2`, in
  either phase, is matched 1:1 by a decrement of `remaining`/`R` at the
  same step (phase 1: checked `remaining > 0` before each single-unit
  grant; phase 2: `R -= sum(grantThisRound.values())` and `R -= 1` per
  leftover grant, both exact). So `sum(total(split[s]) for s in strata) ==
  limit - R_final <= limit`, unconditionally.

- *Exact fill to `min(limit, sum(candidateCount.values()))`, both branches*:
  Let `eligible = sum(candidateCount.values())`, `phase1Grants =
  sum(split[s].phase1 for s in strata)` after phase 1 completes, `R_start
  = limit - phase1Grants` (remaining entering Phase 2),
  `totalCapacity_start = eligible - phase1Grants`.
  - **If `eligible <= limit`** (`D_0 = totalCapacity_start - R_start <=
    0`, since `totalCapacity_start <= eligible <= limit` and `R_start =
    limit - phase1Grants >= eligible - phase1Grants = totalCapacity_start`
    follows directly): since `totalCapacity(E) = R + D` always (the
    invariant) and `D = D_0 <= 0` throughout, `totalCapacity(E) <= R` at
    every point — so `totalCapacity(E)` reaches 0 (every stratum
    saturated, loop exits via `E.isEmpty`) no later than `R` does. At that
    exit, `R_final = totalCapacity(E)_{final} - D_0 = 0 - D_0 = R_start -
    totalCapacity_start >= 0`, and total granted `= limit - R_final =
    limit - (R_start - totalCapacity_start) = phase1Grants +
    totalCapacity_start = phase1Grants + (eligible - phase1Grants) =
    eligible`. Matches `min(limit, eligible) = eligible` exactly.
  - **If `eligible > limit`** (`D_0 > 0` by the same derivation, reversed):
    `totalCapacity(E) = R + D_0 >= D_0 > 0` for as long as any capacity
    remains, so `totalCapacity(E)` can never reach 0 while `R > 0` — the
    loop must instead exit via `R == 0` (budget exhausted, `E` possibly
    still non-empty, correctly so — those strata simply don't receive
    more because the budget ran out, not because they're saturated). Total
    granted `= limit - 0 = limit`. Matches `min(limit, eligible) = limit`
    exactly.

- *Leftover-pass always succeeds (a Hamilton-apportionment property,
  applied ONLY to the round that satisfies `newlySaturated.isEmpty` — the
  round the corrected break condition selects, closing Codex re-review
  High #1's counterexample)*: the prior revision's version of this
  argument used `|E|` **before** that round's saturation removal to bound
  `leftover`, then implicitly assumed the leftover pass (which iterates
  the **post-removal** `E`) had that same bound available — false whenever
  a floor grant exactly exhausted a stratum's capacity without being
  "clipped" by the old (too-narrow) definition. This revision's break
  condition fixes this by construction: the algorithm only proceeds to the
  leftover pass when `newlySaturated` is **empty** for that round — i.e.
  `E` is **unchanged** by that round (nothing was removed), so the `|E|`
  the Hamilton bound is proved against and the `|E|` the leftover pass
  actually iterates are the same set, not a stale, larger one.

  Within that (unchanged) round: `leftover = R - sum(floorShare[s] for s in
  E)`. Since `sum(R * effectiveWeight[s] / W) == R` exactly (real-valued)
  and each `floorShare[s]` is that quantity's integer floor, the sum of the
  `|E|` fractional parts lost to flooring is itself an integer (because `R`
  and `sum(floorShare)` both are), and — the standard Hamilton-method bound
  — strictly less than `|E|`: `0 <= leftover < |E|`. Because
  `newlySaturated` is empty for this round, **every** `s` in `E` has
  `grantThisRound[s] = floorShare[s] < candidateCount[s] -
  split[s].phase1 - split[s].phase2` (its pre-grant residual capacity) —
  if it were `==` instead of `<`, that `s` would be in `newlySaturated` by
  definition and this round would not have broken the loop — so every `s`
  in `E` has **strictly positive** spare capacity remaining after its
  floor grant, i.e. at least 1 unit available for a leftover `+1`. With
  `leftover < |E|` extra grants needed and `|E|` (the *same* `E`, not a
  reduced one) candidates each offering `>= 1` spare unit, the leftover
  pass's `while` loop always finds enough eligible strata before
  exhausting `order2`, and `R` reaches exactly `0`.

  *Consistency with the exact-fill branches above*: a "no saturation this
  round" break (the only way the leftover pass is reached with `R > 0` and
  `E` non-empty) is only reachable when `D_0 > 0` (the `eligible > limit`
  branch) — in the `eligible <= limit` branch (`D_0 <= 0`), a round with
  `newlySaturated` empty would require every `s` in `E` to satisfy
  `floorShare[s] <= candidateCount[s] - split[s].phase1 -
  split[s].phase2 - 1` (strict, since equality would itself trigger
  saturation), which forces `leftover >= |E| - D_0`, contradicting the
  Hamilton bound `leftover < |E|` whenever `D_0 <= 0` — so that branch
  never takes this path; it always proceeds via clipping/saturation every
  round until `E` becomes empty, exactly as the exact-fill argument above
  already claims. The two branches of this proof are therefore mutually
  exclusive in which exit path they use, not independently asserted facts
  that happen to agree.

- *Every child (inner) budget sums to no more than its parent, and every
  child's own selection never exceeds its own child budget*: unchanged in
  structure from the prior revision — the inner call's `limit` argument is
  `n`, the outer call's own already-bounded total for that stratum (proved
  above), so by induction `sum(total(innerCounts[s]) for s in innerStrata)
  <= n`; and `fill(innerStratum, innerSplit.phase1+innerSplit.phase2,
  seed).prefix(...)` returns at most that many elements by construction.

**Selection semantics for plain (no configured stratification)**: the
degenerate case of the same function with the outer dimension set to
`file` and no inner dimension — one function, different dimension
configuration, not a structurally separate implementation (this remains
what "generalize the three v1 modes into one" means concretely).

**Relationship to v1's `.operatorSubtype` — precise, not "identical
mechanism" (closing Codex re-review Medium #2, and per explicit
instruction not to overclaim equivalence):** this revision's `allocateCounts`
is a **newly specified algorithm**, not asserted to be byte-for-byte
identical to v1's actual `reserveMinimums`/`distributeRemainder`
implementation (`MutationPlanner.swift:461-586`) — that real code is a
separate, unchanged, already-tested implementation that invariant 8
requires to keep working exactly as it does today for existing configs, on
its own code path. What this revision's algorithm is designed to
**preserve**, when configured with outer dimension = operator and inner
dimension = subtype (i.e. the configuration that plays the same structural
role `.operatorSubtype` plays in v1), is specifically these fairness
properties v1's own test suite already pins (A.12):
- Every operator with remaining candidate capacity receives its configured
  minimum before any operator receives proportional "extra" slots, subject
  to the overall budget (mirrors `everyOperatorGetsItsMinimum`/
  `higherMinimumIsHonored`).
- Remainder distribution after minimums uses the largest-remainder method,
  guaranteeing exact-fill and no overrun (mirrors the *mechanism* behind
  `remainderIsProportional`, not necessarily its exact numeric outcome —
  see the correction below).
- Output selection is independent of input order (mirrors
  `reversedInputOrderSelectsIdentically`).
- No operator's assigned count ever exceeds its own candidate count
  (mirrors `neverExceedsCandidateCount`).
- The same `(points, limit, seed, minimumPerStratum, weight)` always
  produces byte-identical output (mirrors `sameSeedReproduces`).

**Correction (closing Codex re-review Medium #2 — "proportional to
capacity" is not what this revision's default actually does):** the
bullet list above originally claimed remainder distribution was
"proportional to each operator's own remaining candidate capacity," mirror
v1's actual design — this is **not accurate for B.2's default policy**.
v1's `distributeRemainder` genuinely weights by residual capacity; this
revision's default (`weight` unconfigured) uses **equal share** across
strata (`effectiveWeight = 1` for everyone, B.3) — a deliberate, different
policy choice, not v1's capacity-proportional one. A caller who wants
v1-like capacity-proportional behavior must explicitly configure `weight[s]`
to track each stratum's own `candidateCount[s]` — and even then the match
would only be approximate, since v1's proportionality is computed against
each round's *dynamically shrinking* residual capacity while a configured
`weight` is a *static* value fixed before Phase 2 begins (B.3 requires
this — weights are never recomputed mid-run). This ADR does not claim v2's
default reproduces v1's capacity-weighting behavior; it claims only the
four other properties above, plus exact-fill and no-overrun, which hold
regardless of `weight` configuration.

Whether this revision's algorithm reproduces v1's `.operatorSubtype`
**byte-for-byte** on every input is an empirical question for the
acceptance test suite (above) to establish, not a claim this ADR makes in
advance — the two are structurally similar (both use minimum-reservation +
largest-remainder + deterministic tie-break) but are not asserted identical
just because they share that shape.

**Acceptance test implication (normative, extended again this revision):**
- A property-based/fuzz test asserting `sum(total(split[s])) <= limit` AND
  `sum(total(split[s])) == min(limit, sum(candidateCount.values()))` across
  randomized `(candidate pool size, dimension cardinality,
  minimumPerStratum, weight configuration, seed)` inputs.
- A direct test that phase 1 grants strictly one slot per stratum per
  round under a tight budget with `minimumPerStratum > 1` and multiple
  strata — i.e. no single stratum can consume more than one slot before
  every other eligible stratum has had a turn in the same round.
- A regression test mirroring v1's real production incident that motivated
  `.operatorSubtype` (operator starvation under a tight budget), re-run
  against this two-level structure.
- An explicit test for every degenerate case named in the pseudocode:
  `limit <= 0`, empty `strata`, a stratum with `candidateCount == 0`, an
  outer stratum assigned `n == 0` (asserting no inner call is made for it
  at all), unconfigured `weight` (asserting equal-share, `effectiveWeight
  = 1` for every stratum), and a config-validation test asserting `weight
  = 0` and "some strata configured, others not" are BOTH rejected at
  config-load time (per B.3's revised, opt-out-free semantics), not
  silently accepted. A dedicated test confirming Phase 2's `W` computation
  can never divide by zero — structurally unreachable now that every
  `effectiveWeight` is provably `>= 1` (equal-share fallback or a
  validated positive configured value), with no exclusion path left to
  create an empty-but-nonzero-`W` scenario.
- **A regression test for the exact leftover-pass bug Codex re-review
  found in the prior revision**: residual capacities `{1, 1, 100}`, equal
  weights, `R = 5` — asserting the algorithm grants the full `5` (not `4`,
  the bug's actual wrong output), directly exercising the corrected
  `newlySaturated.isEmpty` break condition against the exact counterexample
  that proved the old `anyClipped`-based condition wrong.
- A test asserting **exact integer arithmetic only**: run the same inputs
  through the allocator with weights and budgets chosen so that naive
  floating-point division would produce a different tie-break outcome than
  exact integer division/remainder — confirming the implementation's
  output matches the exact-integer result, not a floating-point
  approximation, and is identical across at least two different build
  configurations (e.g. debug vs. release optimization levels) to catch any
  accidental floating-point or platform-dependent comparison creeping in.
- A test confirming `reasonCode`/`selectionOrdinal`/`stratumPath` exactly
  match the normative mapping in B.7 for both single-level and two-level
  (inner-dimension-configured) allocations, including a case where the
  same mutant would get a *different* `reasonCode` depending on whether it
  came from the outer or inner call's terminal phase — directly testing
  that only the terminal call's `PhaseSplit` determines `reasonCode`, not
  the parent's.

**Why this closes the remaining findings:** every step in
`allocateCounts`/`allocate` is fully defined using exact integer
arithmetic only (no undefined helper function, no `Float`/`Double`
anywhere), phase 1 is genuinely one-slot-per-round, the proof above
establishes both branches of exact-fill via the conserved quantity `D`
(not the incomplete/incorrect argument from the prior revision), and the
`reasonCode`/`selectionOrdinal` mapping is fully mechanical — two
conforming implementations must agree. The "one shared counter" framing
that re-review found inaccurate for the recursive case remains removed;
B.1 item 11 states the compositional invariants directly instead.

**Residual limitation, unchanged:** v2 in this cut cannot stratify by three
or more independent dimensions simultaneously — only a two-level hierarchy
(outer, optionally one inner). Deferred to a future, separately reviewed
extension, not assumed to "just work" by adding a level to this recursion.

**Explicitly excluded from the objective, unchanged:** any notion of
"maximize expected kills" or "maximize expected score" as the primary
signal (invariant 10) — per B.5's closure, this is moot in a stronger
sense: v2 in this cut has no historical/outcome-derived data channel to
optimize toward at all.

### B.3 Budget semantics — DECIDED (closing Codex re-review Low: was worded "Proposed" while Choice 3 already declared this closed)

Budget remains **count-based** (`maxMutants`) as the primary unit, matching
v1 and avoiding a redesign of `maxDurationSeconds`'s separate,
executor-side role in the same release. A cost/time-aware selection mode
(planning-time budget in wall-clock terms) is identified in the v1 audit
(A.16) as a genuinely new capability v1 never had — **out of scope for
v2's first cut** (Choice 3), to avoid conflating "make selection fairer/
more auditable" with "add a wholly new cost model," which is its own
design problem (would need a cost *estimate* input that doesn't exist
anywhere in this codebase today). Flagged as a natural v3 candidate, not
silently dropped.

**Weight configuration (introduced by B.2's Phase 2 algorithm, revised
this round — closing Codex re-review High #2):** Phase 2's proportional
distribution is governed by an optional per-stratum `weight: [StratumID:
Int]` config (default: empty/unconfigured). The prior revision's design
let an explicit `weight = 0` permanently exclude a stratum from Phase 2 —
re-review found this incoherent with the exact-fill proof (which stratum's
candidates count toward "eligible" then becomes ambiguous) and internally
contradictory with this document's own acceptance-test text. **That
opt-out mode is removed.** Revised, coherent semantics:

- **Empty/unconfigured** (no entries at all): every stratum uses
  `effectiveWeight = 1` for the duration of Phase 2 — an equal-share
  policy, decided once when Phase 2 begins, not recomputed per iteration.
  This is v2's *default* behavior when `weight` is never mentioned in
  config.
- **At least one entry configured**: **every** stratum in the allocation
  must have a configured weight — a config that sets some strata's weights
  and leaves others unset is a **config-load error** (there is no implicit
  per-stratum fallback once any weight is configured; this removes the
  "absent from dict vs. explicit zero" distinction the prior revision
  needed and the incoherence it caused).
- **Validation (config-load time, not a runtime crash):** every configured
  weight value must be a **positive** integer in `1...1_000_000` (`0` is
  not a valid value at all, closing the B.2/B.3 range mismatch the prior
  revision had), checked the same way `ConfigurationValidation.swift`
  already validates other numeric config ranges (e.g.
  `validateBudgetSampling`'s `minimumPerStratum < 1` check) — a value
  outside this range, or a stratum with no configured weight while others
  have one, is a configuration error, surfaced before planning begins,
  never a Phase 2 runtime failure.
- A caller who genuinely never wants a stratum represented in Phase 2 at
  all achieves that by omitting it from the `strata` set passed to
  `allocateCounts` in the first place (upstream of this call) — not
  through `weight`. This keeps "eligible" (the exact-fill target) always
  equal to the full candidate pool `allocateCounts` was actually given,
  with no ambiguity about which candidates count.
- Since every stratum's `effectiveWeight` is now always `>= 1` (equal-share
  fallback, or a validated positive configured value), Phase 2's `W =
  sum(effectiveWeight over E)` is always `>= 1` whenever `E` is non-empty
  — division by zero is structurally unreachable, with no exclusion logic
  needed to establish it.
- **Weight provenance (closing Codex re-review Medium #K):** any
  configured `weight` value must **not** be derived, directly or
  indirectly, from prior kill/survive outcomes, execution frequency,
  timing, or any `MutationResultCache`-adjacent data — this would
  reintroduce the exact easy-kill-proxy channel B.5/invariant 12 close by
  removing history entirely, through a back door B.5 didn't anticipate
  when it was written (weight didn't exist yet). A configured `weight`'s
  provenance/rationale must be recorded alongside the pre-registration
  artifact (B.9) for any evaluation run that uses non-default weights —
  auditable final integer values alone don't reveal whether they were
  history-derived, so the requirement is on *documented justification*,
  not just on the values being visible in `InclusionReason`.

### B.4 Deterministic tie-breaking

Unchanged in spirit from v1 (A.8): seeded `SplitMix64` keyed by
`seed XOR FNV1a64(identity)` when a seed is set, ID-string comparison
otherwise, no system RNG, no wall-clock, no environment input. v2 must pass
the same input-order-independence property v1 already has (A.8,
A.11-equivalent tests) for any new stratification combination it adds.

### B.5 History semantics — CLOSED for this v2 cut: no historical/outcome-derived input at all

**Revised in response to Codex High #2** ("The history proposal does not
make the easy-kill prohibition enforceable" — the prior draft's
within-stratum-only constraint limited *cross-stratum* representation bias
but did nothing to prevent *within*-stratum bias: history could still let
every slot in a large stratum go to mutants correlated with easy kills,
and if the history source were ever `MutationResultCache` — which stores
actual verified kill/survive outcomes — using those outcomes to
deprioritize likely survivors is verdict-adjacent pre-judgment even though
the selector never emits a formal verdict itself. Codex's stated
recommendation: "the safest resolution is no outcome-derived history
input.")

**Failure mode this closes:** any mechanism that lets historical kill
propensity, execution frequency, build timing, or cache presence influence
*which specific mutant* fills a slot — even scoped to "within an
already-fair stratum" — reopens a channel for the exact easy-kill bias
invariant 10 exists to prevent, because ease-of-kill correlates with
mutant simplicity, which correlates with cheaper/faster builds and more
"historical certainty," so even an indirect proxy signal can still skew
selection toward easy mutants without ever directly ranking by kill
probability.

**Normative spec (replaces the prior "open question, candidate shape"
framing):** v2, as specified in this ADR, is **closed** on this question —
it consumes **zero** historical or outcome-derived data of any kind. This
is invariant 12 (B.1). Concretely:

- No `BudgetSelectorV2` function accepts a cache, a result store, a
  kill/survive map, an execution-frequency counter, a build-timing signal,
  or any parameter derived from a previous run's outcomes.
- Tie-breaking within a stratum remains exactly what B.4 already specifies:
  seeded `SplitMix64` keyed by identity, or ID-string order — nothing else.
- A future mechanism that *does* want to use historical data must be
  proposed as a **separate ADR**, not an amendment folded into this one,
  and that ADR must independently satisfy invariant 10 with its own
  concrete, reviewed answer to "how does this not become an easy-kill
  proxy" — this ADR does not pre-approve any shape for that future
  mechanism, including the "within-stratum only" shape originally proposed
  here, since Codex's review already found that shape insufficient on its
  own.

**Acceptance test implication:** a "no history dependency" hygiene test —
either a compile-time signature check or an explicit unit test — confirming
`BudgetSelectorV2`'s public functions accept no cache/history/verdict
parameter, mirroring the same audit approach used to establish v1 has none
(A.6). Determinism-with-zero-history (invariant 7) is trivially satisfied
as a corollary: there is no history to be absent.

**Why this closes Codex High #2:** the loophole existed because a
partially-scoped history mechanism was being specified without a
sufficiently strong containment proof. Removing the data channel entirely
removes the loophole by construction — there is nothing left for a
sufficiently long run of historical data to skew, because no historical
data reaches the selector.

**Residual limitation:** v2 in this cut cannot use historical data to
inform selection even in ways that might, with sufficiently careful design,
have been safe (e.g. prioritizing under-tested files, or files with more
recent churn, using signals *unrelated* to kill outcomes). That
possibility is deferred to a future, separately-reviewed ADR — not ruled
out forever, just out of scope here, per Codex's explicit recommendation.

### B.6 Stale/missing-history fallback — moot, closed alongside B.5

Directly follows from B.5's closure: since v2 in this cut has no history
input of any kind, there is no "stale" or "missing" state to define
fallback behavior for — invariant 7's "works fully deterministically with
zero history" is unconditionally true rather than a fallback that needs
specifying. This section is retained only so a future history-adding ADR
(see B.5) has an explicit placeholder to fill in, with its own freshness/
provenance/schema/partial-availability semantics fully specified at that
time — not inherited from this ADR, since this ADR never defines a history
schema to be stale relative to.

### B.7 Selection explanation/audit format

Proposed: extend the existing `SkippedMutation.detail` pattern (A.11) to
also emit a symmetric, machine-readable inclusion record — not just
prose, but a structured reason (stratification dimensions consulted, which
stratum/round a mutant was assigned in, whether a tie-break fired and via
what mechanism) attached per selected mutant, persisted in `plan.json`
alongside the existing skip detail. This directly closes A.11/A.17's
asymmetry and satisfies invariant 6.

**Amended (Codex Medium #7 — schema is architecture-level, not merely
implementation detail):** at minimum, the following are part of the frozen
spec, not deferred to implementation:
- The record is structured data (a `Codable` value with named fields), not
  a free-text string — this was already required, restated for clarity.
- It exists for **every** selected mutant individually, not as an aggregate
  summary.
- It is computed **once, at planning time**, and never recomputed or
  altered afterward.

**Amended (Codex Medium #5 — shard/resume stability of explanations was
unspecified):** the inclusion record must be:
- Copied unchanged into each shard's own plan view by `PlanSharding.shard`
  — a shard-local record must be byte-identical to the corresponding
  record in the unsharded plan, never recomputed from shard-local position
  or shard-local candidate count.
- Independent of shard count and shard index entirely — the same mutant's
  inclusion record must be identical whether the plan is later shard-1-of-1
  or shard-3-of-8.
- Preserved unchanged through `--no-resume`/resume, decode/re-encode, and
  any report-merging step — resume already never re-selects (A.10); this
  extends that same guarantee explicitly to the new audit metadata, so
  selection semantics (invariant 9) and explanation semantics don't
  silently diverge from each other.
- Excluded from `planID`/`workUnitID`'s hash inputs on the same terms the
  existing `createdAt` field already is (A.8) — the inclusion record is
  derived data describing an already-fixed selection, not itself part of
  what makes two plans "the same plan" for checkpoint/resume purposes,
  unless a future decision explicitly changes that (not assumed here).

**Schema — DECIDED, closing Choice 4** (previously proposed-not-decided;
now frozen by explicit instruction, not left open):

```
InclusionReason:
    mutationID:        MutationID   # the selected mutant this record describes
    reasonCode:         one of { minimumReservation, proportionalRemainder }
    stratumPath:        [String]
    selectionOrdinal:   Int
```

**`reasonCode` — normatively defined (closing Codex re-review Medium #2),
not left to a "natural interpretation" an implementer might guess
differently:** it reflects the phase of the **terminal** `allocateCounts`
call — the deepest one that actually produced this mutant's stratum
assignment. Concretely, per B.2 step 3's `allocate()` pseudocode: when an
inner dimension is configured, `reasonCode` is drawn from the **inner**
call's own `PhaseSplit` for the mutant's innermost stratum (`ordinal <
innerSplit.phase1` → `minimumReservation`, else `proportionalRemainder`);
when no inner dimension is configured, it is drawn from the outer
(only) call's `PhaseSplit` the same way. A parent stratum's own phase split
(when an inner dimension exists) never determines `reasonCode` directly —
only whichever call's `fill()` actually produced the final selected point
does. There is no third value because every `allocateCounts` call has
exactly two granting phases (B.2), and every mutant is produced by exactly
one terminal call.

**`selectionOrdinal` — normatively defined**: the mutant's 0-based index in
`fill()`'s own deterministic output order (B.2 step 5) for its terminal
stratum — i.e., `candidates.enumerated()`'s index in the `allocate()`
pseudocode, computed once, at the same terminal call that determines
`reasonCode`. This is the same traversal `allocate()` already performs to
build `selected`, not a separate bookkeeping pass.

**`stratumPath`**: the stratum identity chain — one element for a
single-level (outer-only) allocation, two elements
`[outerStratumID, innerStratumID]` when an inner dimension is configured.
Always reflects the actual dimension configuration used for that plan.

This is the minimal set that (a) satisfies invariant 6 (every inclusion
explainable), (b) requires no field the algorithm in B.2 doesn't actually
compute (no raw scores, no timestamps — both already excluded by the
shard/resume-stability requirements above), and (c) is now derivable
**mechanically and unambiguously** from `allocateCounts`/`allocate`'s own
execution — two independent conforming implementations of B.2's pseudocode
must produce identical `InclusionReason` records for identical inputs,
closing the "two implementations, different audit reasons" gap Codex
re-review identified.

### B.8 Compatibility/default behavior

**DECIDED** (closing Codex re-review's Low finding that this section's
"Proposed" wording was inconsistent with Choice 1's own closure below),
mirroring the `Budget v1 vs v2` pattern already used elsewhere in this
project for similar cutovers (e.g. schemata lowerer promotion, one operator
at a time, gated by real-corpus evidence): v2 ships **opt-in**
(`budget: { selection: v2 }` or equivalent) for this milestone, v1 remains
the unqualified default, and existing configs produce byte-identical plans
to today (invariant 8). Only after a real equal-budget comparison (B.10)
shows v2 is not worse — and ideally clearly better on a predefined metric
— does switching the *default* become a separate, later decision (Choice
5, explicitly deferred), not bundled into this spec.

### B.9 Evaluation metrics

**Revised in response to Codex High #3** ("The evaluation design can make
v2 win by construction" — the prior draft made "operator/file/subtype
coverage breadth" the leading metric while v2's own stated objective is
literally to maximize exactly that. A selector can mechanically improve
that number by adding finer subtype labels, picking a favorable
stratification dimension, or spreading across many trivial strata, without
improving actual fault-detection value — the metric was a restatement of
the thing being measured, not independent evidence it worked.)

**Failure mode this closes:** any acceptance metric that shares a free
parameter with the algorithm under test (here: which dimension(s) to
stratify by) can be satisfied by tuning that same parameter, producing an
evaluation that looks like a win regardless of whether real mutation-testing
value improved.

**Normative spec (replaces the prior metric list, per invariant 13):**

1. **Disqualification rule.** Any metric whose formula is a direct
   restatement of, or shares a free/tunable parameter with, v2's own
   selection objective (B.2's stratification dimension choice) may be used
   only as a *secondary/diagnostic* signal — never as the metric that GATES
   a "v2 accepted" decision. This specifically disqualifies "operator/file/
   subtype coverage breadth" as a primary metric, exactly as originally
   proposed.
2. **At least one primary metric must be post-execution**, i.e. computed
   from real results of actually running the selected, budget-limited plan
   against a real corpus — not from the selection step itself. Candidates
   (to be finalized in the pre-registered evaluation protocol required by
   point 4, not decided here): number of *distinct tests* that end up as
   the sole killer across the selected set; number of distinct source
   declarations/functions touched by a kill; real kill/survive counts,
   reported as *context*, never as the sole or primary metric (unchanged
   from the prior draft, still explicitly subordinate to invariant 10).
   **Amended twice — closing Codex re-review Medium #3 ("post-execution"
   alone doesn't make a metric proxy-independent) and the follow-up re-review
   finding that a prose "proxy-dependence analysis" is unfalsifiable
   paperwork, not a real test:** "computed post-execution" is necessary but
   not sufficient. Tests commonly partition along the same source
   boundaries (file, declaration, operator) available as allocator
   stratification dimensions, so a post-execution metric like "distinct
   sole-killer tests" can still be indirectly improved by an allocator
   configuration chosen to correlate with it, even though the metric's own
   formula never references a `file`/`operator` parameter directly. A
   written argument that a metric "isn't a predictable proxy" is not
   evidence — an implementer could satisfy it with a superficial assertion.

   **Scope decision on the proxy-dependence screen's exact statistical
   procedure — closing four consecutive rounds of Codex re-review that
   each found genuine, deepening statistical-design gaps (individual-
   mutant permutation ignoring file/declaration dependence; cluster
   permutation undefined for label-heterogeneous clusters and an
   unspecified block-pooling algorithm; a per-file redesign that still
   left the observed-statistic aggregation across corpora undefined,
   file-rate exchangeability under unequal per-file mutant counts
   unaddressed, near-tie plurality misclassification unacknowledged, and
   PRNG/canonicalization details unspecified).** Continuing to design a
   fully rigorous, general-purpose multi-corpus permutation test in the
   abstract — before the actual candidate metrics, dimensions, and real
   per-file mutant-count distributions of the real corpora being evaluated
   are even known — has not converged after four attempts and is
   disproportionate abstract statistical-methodology work relative to
   what's needed to unblock this ADR's actual purpose (specifying the
   selector algorithm, B.2, which reached Critical=0/High=0 as of
   revision 5 and has been independently reconfirmed clean through two
   further rounds since). This is explicitly **not** a silent drop: the
   requirement that a rigorous, falsifiable screen exist is frozen now
   (below); the exact procedure is deferred to task #25 of this
   milestone's own roadmap ("Freeze v1-vs-v2 evaluation protocol
   document") — the step where the real candidate metrics and real corpus
   file-count distributions are concretely known, making correct,
   convergent design actually tractable instead of a moving abstract
   target.

   **Frozen now — binding on the task #25 protocol document, not
   reopenable there:**
   1. A **falsifiable statistical procedure** (not a prose "analysis")
      must be specified, pre-registered, and independently reviewed
      (Codex or equivalent) before it screens any real metric — the same
      standard of rigor already demanded and applied across this ADR's own
      six-round B.2 review history, not a lower bar for B.9 just because
      it comes later.
   2. The procedure must account for **exchangeability at whatever
      granularity it actually operates on** — it may not shuffle
      individual mutant labels while ignoring known file/declaration/
      corpus dependence structure (the specific failure mode four rounds
      of re-review already found, repeatedly, in different concrete
      designs — the task #25 author must read this ADR's revision history
      as a record of failed approaches, not start from zero).
   3. The procedure must produce **one well-defined decision rule** per
      metric/dimension pair — not merely "a null distribution," but an
      explicit, unambiguous answer to how per-corpus or per-file results
      combine into a single pass/fail outcome (this is precisely the gap
      the per-file redesign left open: computing a statistic per
      corpus/run is not the same as knowing how to compare it against a
      pooled threshold).
   4. **Freeze before holdout execution**: the final procedure's every
      parameter (statistic choice, PRNG/seed derivation, permutation
      count, weighting/exchangeability handling, canonicalization rules,
      decision-combination rule) must be decided and recorded **before**
      any holdout-corpus execution happens (B.10) — screening runs against
      development-corpus data only, never against the holdout.
   5. A metric must pass this screen against **every** stratification
      dimension the evaluated configuration uses (both outer and inner, if
      applicable) to qualify as primary. Failing against even one
      disqualifies it as primary (it remains usable as a diagnostic-only
      signal, point 3 above in the outer list).

   **Residual limitation, explicit:** until task #25 produces and closes
   its own reviewed procedure, no primary-metric proxy screening has
   actually been run against any real data — this ADR freezes the
   *requirement* and the *constraints* the eventual procedure must satisfy
   (above), not the procedure itself. v2's core algorithm (B.2) does not
   depend on this in any way; this deferral affects only Phase 5/6 of the
   milestone (evaluation), not implementation readiness.
   6. A separate, predefined **non-inferiority threshold** (a minimum
      acceptable mutation-quality bar the metric must clear on its own
      terms, independent of the proxy screen) is still required — its
      value and rationale must be recorded in the outer pre-registration
      artifact (B.9's own "Pre-registration" point, below), not chosen
      after observing results.

   A metric that has not been screened by a procedure satisfying points
   1–6 above, with that procedure's parameters recorded before any holdout
   use, may not be used as primary — no exceptions, and no substituting a
   prose argument for a real statistical test. This is a floor the task
   #25 protocol document must clear, not a ceiling it may relax.
3. **Diagnostic-only metrics** (informative for fast iteration during
   development, never gating): the disqualified breadth metric from point
   1; selection determinism/reproducibility (a correctness requirement, not
   a comparative quality metric — must simply hold, not be "better" than
   v1's); selection-overlap between v1 and v2 outputs at equal budget (a
   sanity check, not evidence of quality either direction);
   wall-clock/build-invocation cost of running the selected set (a real,
   measurable property worth tracking, but cost alone doesn't establish
   value — a v2 that's cheaper but detects less is not thereby better).
4. **Pre-registration.** Before dispatching the real, expensive v1-vs-v2
   comparison run against actual corpora, the exact metric formulas AND the
   exact stratification-dimension configuration v2 will use for that run
   must be frozen and recorded (in this ADR's revision history or a linked
   follow-up document) — not adjusted after seeing results. This mirrors
   the discipline already established in this project's schemata benchmark
   flake/invalid-run policy (git-tracked, reviewed, fixed before dispatch).

**Why this closes Codex High #3:** the gating decision can no longer be won
by an algorithm that simply does more of what it was already told to
optimize for; it requires independent, harder-to-game evidence computed
downstream of the selection itself, and the parameters under test are
frozen before the expensive comparison run rather than tunable after seeing
results.

**Residual limitation:** post-execution metrics (point 2) require actually
running mutation testing against a real corpus, which is expensive — early,
cheap iteration during v2 development may still use the diagnostic breadth
metric (point 3) to sanity-check the algorithm quickly, but that metric can
never be cited as the reason v2 was accepted; only a post-execution primary
metric can gate that decision.

### B.10 Holdout strategy

**Revised in response to Codex High #3's related finding**: the prior
draft required a holdout only "if any history-informed weighting is
ultimately adopted," but B.5 is now closed (no history at all, ever, in
this cut) — under the prior wording this would make B.10 vacuous. Codex's
review specifically flagged that this is wrong: even with zero history, the
allocator's own dimension choice, minimums, and hierarchy configuration
(B.2) are themselves free parameters that could be tuned by looking at
results on the evaluation corpora, which carries the identical
tuning-on-the-test-set risk history would have.

**Normative spec (replaces the prior conditional framing):** a holdout is
**mandatory**, unconditionally, for this v2 cut — not conditioned on
whether history is used (it never is, per B.5).

**Amended twice — closing Codex re-review Medium #4 ("consulted while
tuning" was an intention-based, unauditable trigger) and the follow-up
re-review finding that "observed" was itself still operationally
ambiguous (execution alone? a CI summary nobody opened? access by someone
outside the configuration-selection group?):** the prior wording let an
implementer inspect results and later claim a configuration was "chosen
independently," reclassifying corpus use as evaluation rather than tuning
after the fact, and even the "observed" fix still depended on defining
who/what counts as observing. This revision replaces both with a single,
purely **execution-based** trigger — no concept of "observation" at all:

- **Any execution of any candidate v2 configuration against a corpus,
  before the algorithm/config/metric are frozen for this milestone's final
  evaluation, permanently makes that corpus development-used** — full
  stop. Execution alone is sufficient; it does not matter whether the
  result was ever opened, read, summarized, or acted on, and it does not
  matter who ran it or why. There is no "observation" event to define,
  because the trigger is the execution itself, which is unambiguously
  loggable (a CI run timestamp, a local test invocation) — not a claim
  about anyone's state of knowledge.
- A corpus that has become development-used by the above rule can never
  subsequently serve as this cut's holdout, regardless of how much time
  passes, how the configuration is later described, or whether anyone
  actually looked at that particular run's output.
- "Freeze" means: the point at which the algorithm (B.2), its configured
  parameters (dimensions, minimums, weights), and the evaluation metrics
  (B.9) are all simultaneously fixed and recorded in the pre-registration
  artifact (B.9 point 4) — any execution before that point, on any corpus,
  taints that corpus for holdout purposes; any execution after that point
  is the real evaluation run itself, not tuning.
- The holdout corpus must be a **named, third, real project that has never
  been executed against any candidate v2 configuration before the freeze
  point** — not merely "unseen by the people selecting the configuration,"
  since that population-based framing is exactly the ambiguity this
  revision removes. Evaluated using the same pre-registered metrics (B.9
  point 4) frozen in advance.
- The pre-registration artifact (B.9 point 4) must additionally record:
  every execution of a candidate v2 configuration against any corpus
  (timestamp, corpus identity, configuration used), and the exact freeze
  point (timestamp, plus the frozen algorithm/config/metric values
  themselves) — a log of *events*, not a log of who noticed what.

**Broadened once more (closing Codex re-review Medium #J — the
execution-only trigger left non-execution contamination channels open):**
the execution-based rule above is the **primary, mechanically auditable**
enforcement mechanism, but it is not the *complete* rule. The actual,
overarching prohibition (already implied by invariant 13's "any
corpus-informed tuning requires the same holdout discipline," stated here
explicitly for B.10 specifically): **no information about the intended
holdout corpus — whether obtained by executing a candidate v2
configuration against it, running v1 or any other baseline against it,
inspecting its source, its mutation inventory, or its dimension
distributions, or any other means — may influence the choice of algorithm,
configuration, weights, metric, or threshold before the freeze point.**
Execution is called out separately because it is the one channel that
produces an unambiguous, timestamped, mechanically-loggable event —
inspection-based contamination (reading a corpus's source to hand-pick
dimensions, or running only v1 against it to "get a feel" for its shape)
is real, prohibited by this rule, but not mechanically auditable from logs
the same way — it relies on the same disclosure norm this project already
applies elsewhere (declared, not silently assumed away). A holdout
selection process should therefore prefer, where practical, choosing the
holdout corpus from projects nobody on the team has had *any* reason to
examine before the freeze point — not merely ones v2 was never executed
against — to keep the mechanically-auditable rule and the actual
informational-independence goal as close together as possible.

This mirrors the discipline this project already applies to schemata
backend correctness (never trusting a single corpus's result as proof, per
Task #18's own methodology), made mechanically checkable from execution
logs for the primary channel, with the broader informational-independence
requirement stated explicitly rather than left implicit.

**Why this closes the gap:** removes four loopholes — "no history means no
tuning risk" (the allocator itself has tunable parameters even without any
history mechanism), "I only *evaluated*, I didn't *tune*" (now an
objective, recorded event sequence, not a self-reported distinction),
"nobody actually observed that result" (there is no observation concept
left to argue about for the execution-based trigger), and "I only ran v1 /
only looked at the source" (the broadened rule above makes explicit that
non-execution contamination is prohibited too, not merely unaddressed).

---

## Product/architecture choices — decision table

None of these are silently decided without explanation. As of this
revision, **Choices 1, 3, 4, and 5 are CLOSED** (explicit decisions, given
directly rather than left to inference — see each row) and **Choice 2 is
closed** by B.5's normative closure elsewhere in this document. **Choice 6**
remains a recommended, non-blocking disposition rather than a fully closed
decision, since it depends on a follow-up code audit outside this ADR's
scope. No choice in this table blocks v2 implementation as of this
revision.

### Choice 1 — CLOSED: Budget Selection v2 ships opt-in only this milestone

| | |
|---|---|
| **Question** | Once B.2's unified two-level allocator exists, does an unqualified config (no explicit `budget.selection`) get v1's exact current behavior, or the new algorithm? |
| **Decision** | **v2 ships opt-in only** (`budget: { selection: v2 }` or equivalent) for this milestone. An unqualified config gets v1's exact current behavior, byte-identical to today, per invariant 8. The question of whether/when v2 ever becomes the unqualified default is a **separate, explicitly deferred decision** (folded into Choice 5's "deferred" closure — the two choices converge to the same answer and are effectively one decision restated twice across the original discovery pass). |
| **Rationale** | Matches invariant 8 (v1 behavior not broken for existing configs) directly, requires no weakening of any frozen invariant, and mirrors this project's own established pattern for schemata lowerer promotions: land as opt-in, prove out on real corpora with the frozen evaluation protocol (B.9/B.10), *then* consider a default-flip as its own later, separately gated decision — never bundled into the same ADR that introduces the capability. This closure also directly resolves Codex re-review's Low finding that Choice 1's "proposed, not decided, blocking" framing was inconsistent with B.8 already committing to opt-in-by-default: B.8 and this closure now say the same thing, explicitly, not merely implicitly. |
| **Consequence** | v2's implementation in this cut needs only an explicit opt-in code path — no default-selection branch, no config-migration logic for existing users. A future default-flip, if it ever happens, is its own ADR with its own evidence requirement (the real-corpus evaluation this ADR specifies but does not itself run). |
| **Blocks implementation?** | **No — closed.** This was the last item explicitly flagged as blocking; it no longer is. |

### Choice 2 — Should v2 introduce historical-data input at all?

| | |
|---|---|
| **Question** | Does v2 (this cut) consume any historical/outcome-derived data to influence selection? |
| **Options** | (a) No — zero historical/outcome-derived input, as now specified in B.5. (b) Yes, within-stratum-only as originally drafted. (c) Yes, some other, more tightly scoped mechanism not yet designed. |
| **Recommended** | (a). **This one is effectively closed by this revision**, not merely proposed — Codex High #2 found (b) insufficient, and this ADR does not attempt to design (c) inline (see B.5's residual limitation: a future mechanism needs its own separate ADR and its own review). |
| **Rationale** | Codex's own recommendation was explicit: "the safest resolution is no outcome-derived history input." Designing a sufficiently gaming-resistant alternative mechanism (option c) is real design work this ADR has not attempted and should not attempt under the pressure of also closing three unrelated High findings in the same revision. |
| **Consequence of (a)** | v2 cannot use historical data to inform selection at all in this cut — a real, accepted capability gap, not a defect, deferred explicitly rather than silently dropped. |
| **Consequence of (b)** | Reopens the exact loophole Codex found; not viable without new, independently-reviewed containment beyond what this ADR currently offers. |
| **Consequence of (c)** | Unscoped — cannot be evaluated without first doing the design work this decision explicitly defers. |
| **Blocks implementation?** | **No** — (a) is the frozen default for this cut (B.5, invariant 12); nothing further to decide before starting v2 implementation on this point. |

### Choice 3 — CLOSED: cost/time-aware planning-time budget mode is deferred, out of scope for this cut

| | |
|---|---|
| **Question** | Should v2 add a new capability v1 never had — using `maxDurationSeconds` (or an estimated per-mutant cost) as a *planning-time* selection input, rather than its current purely executor-side role? |
| **Decision** | **Out of scope for this cut, deferred**, per B.3. (Codex re-review flagged this row's prior wording as self-contradictory — "proposed, not decided" while its own consequence text called option (a) "the frozen default." This closure removes that contradiction: (a) is now stated plainly as decided, not merely proposed, matching what B.3 already normatively specifies.) |
| **Rationale** | No cost-estimation mechanism exists anywhere in this codebase today (A.5/A.16), so building a cost-aware mode would require inventing an entirely new subsystem as a prerequisite — a materially larger scope than "redesign the existing count-based selector," and would need its own gaming-resistance review (an inaccurate cost estimate could itself become a bias vector), effectively becoming a second ADR in disguise. Conflating that scope with this ADR's actual scope risks neither getting done well. |
| **Consequence** | `maxDurationSeconds` remains executor-only, unchanged from v1 — a real, known limitation (A.17), explicitly not fixed by v2 in this cut. A future cost-aware mode is a legitimate later ADR, not ruled out forever. |
| **Blocks implementation?** | **No — closed.** v2 implementation proceeds on the count-based model already fully specified in B.3. |

### Choice 4 — CLOSED: exact schema for the inclusion-reason audit trail

| | |
|---|---|
| **Question** | What concrete fields does the per-mutant inclusion record (B.7) actually contain? |
| **Decision** | `{ mutationID, reasonCode ∈ { minimumReservation, proportionalRemainder }, stratumPath: [String], selectionOrdinal: Int }`, per the exact schema now normative in B.7 — decided, not merely proposed. |
| **Rationale** | Minimal, mechanically derivable from `allocateCounts`/`allocate`'s own execution (B.2) — no field the algorithm doesn't already compute, no timestamp or raw score (both would violate B.7's shard/resume-stability requirement or document data the algorithm has no score to give), and `reasonCode`'s two values map directly onto B.2's exactly-two granting phases. |
| **Consequence** | Directly implementable now, no further schema decision needed before writing the persistence code. An additive field can still be proposed later via a normal amendment if a real debugging need surfaces — removing or renaming a shipped field would be the higher-cost direction, and this schema is deliberately minimal to reduce that risk. |
| **Blocks implementation?** | **No — closed.** The schema is now part of the frozen spec (B.7). |

### Choice 5 — CLOSED: default-flip explicitly deferred (converges with Choice 1)

| | |
|---|---|
| **Question** | Separate from Choice 1's "what does an unqualified config do *today*," when (if ever) does v2 formally become MutantKit's own recommended/default budget selection strategy? |
| **Options** | (a) Explicitly deferred past this ADR — revisited only as its own, later, separately-gated decision after B.9/B.10's real-corpus evaluation produces evidence. (b) Pre-committed to a specific future date/version now. |
| **Recommended** | (a). |
| **Rationale** | Per Codex's own note on this point: "deferred until after evaluation" should itself count as this ADR's explicit resolution for this choice, rather than being treated as still-open in a way that conflicts with "all six choices must be closed before implementation." Codex's phrasing is adopted directly. |
| **Consequence of (a)** | This choice is **closed** by adopting "explicitly deferred" as the answer — no implementation-blocking ambiguity remains, precisely because deferral is a real, complete answer to "when," not a non-answer. |
| **Consequence of (b)** | Would require evidence this ADR doesn't have yet (the evaluation hasn't run) — premature. |
| **Blocks implementation?** | **No** — "deferred" is the closed answer; v2 implementation proceeds as opt-in (Choice 1) without needing a default-flip timeline decided first. |

### Choice 6 — RECOMMENDED, non-blocking: defend regardless of A.14's reachability in practice

| | |
|---|---|
| **Question** | Does v2 need to wait on a deeper audit of `MutationDiscovery`/`MutationID` construction (to establish whether genuine ID collisions are reachable) before it can ship its own defense against duplicate-ID input? |
| **Options** | (a) No — v2 adds the defensive rejection (invariant 4: reject duplicate-ID input outright) regardless of reachability, since the check is cheap and closes the risk unconditionally; the deeper discovery-layer audit proceeds separately, non-blocking. (b) Yes — treat the reachability question as a prerequisite before writing any v2 selector code. |
| **Recommended** | (a). |
| **Rationale** | Invariant 4 already makes this concrete and normative (this revision): the selector rejects a duplicate-ID input, full stop, independent of whether such an input is currently reachable through any real discovery path. A defensive check that's cheap to write and test doesn't need its necessity proven first — it needs to exist regardless, the same way the codebase already defends against other inputs it doesn't expect to see in practice (`PlannerError.invalidBudget` for `maxMutants <= 0`, A.2, is exactly this pattern already). |
| **Consequence of (a)** | v2 ships with a real, tested defense against A.14's failure mode from day one; the separate discovery-layer audit (whether collisions are reachable) can proceed on its own timeline without blocking this ADR. |
| **Consequence of (b)** | Adds an open-ended, out-of-scope research task (auditing `MutationID` hash-collision reachability across all of `MutationDiscovery`) as a hard gate on an otherwise-ready spec, disproportionate to the actual risk given (a) already closes the exploitable path regardless of the answer. |
| **Blocks implementation?** | **No**, given (a) is adopted — invariant 4 already specifies the required defense; the follow-up audit is real but independently trackable, not a gate on this ADR. |

---

## Status of this document

**Revision 8.** Discovery (Part A) and draft spec (Part B) only — still no
implementation.

**B.2 (the selector algorithm) — settled since revision 5, reconfirmed
clean through revisions 6, 7, 8.** Revisions 1–4 iteratively found and
closed real gaps (an unproven budget-overrun assertion, phase 1 not
genuinely one-slot-per-round, an undefined helper function, floating-point
tie-breaking, a leftover-pass undercount bug reproducible with residual
capacities `{1,1,100}` granting `4` instead of `5`, an incoherent
zero-weight opt-out). **Revision 5's re-review confirmed Critical=0,
High=0 on the algorithm itself** — traced the exact counterexample through
the fix and confirmed correctness, independently re-derived the core
exact-fill proof's algebra. Nothing in revisions 6–8 touched B.2 again;
every finding since has been confined to B.9 (below).

**B.9 (the evaluation-metric proxy-dependence screen) — four
non-converging design rounds, resolved by scope reduction, not further
patching.** Revision 5 flagged the permutation scheme (then: individual-
mutant shuffling) as not safely dispositionable. Revision 6 redesigned it
around whole `(corpus/run, file, declaration)` clusters — re-review found
this incoherent (a cluster can span multiple dimension labels, undefined
what "the cluster's label" means; the block-permutation/pooling algorithm
was never chosen). Revision 7 redesigned it again around per-file summary
statistics (`dominantLabel`/`metricRate` per file, permuted among files
within a corpus/run) — re-review found the redesign still left the
cross-corpus observed-statistic aggregation undefined, file-rate
exchangeability under unequal per-file mutant counts unaddressed, and
several reproducibility/canonicalization details unspecified
(Critical=0/High=2/Medium=5/Low=0 — two Highs, both genuine).

**This revision (8)** does not attempt a fifth from-scratch statistical
redesign. Four consecutive rounds surfacing new, real, deepening
statistical-design gaps — each fix closing one problem and revealing
another — is diagnostic: designing a fully general, rigorous multi-corpus
permutation test in the abstract, before the real candidate metrics and
real corpus file-count distributions are known, is not converging and is
disproportionate to what blocks this ADR's actual purpose. B.9's exact
statistical procedure is explicitly **deferred to task #25** of this
milestone's own roadmap (freezing the real evaluation protocol, when
concrete metrics/dimensions/corpora make correct design tractable) —
**not silently dropped**: the requirement that a rigorous, falsifiable,
independently-reviewed procedure must exist, plus the specific
constraints it must satisfy (drawn directly from what four rounds of
re-review found missing: exchangeability-awareness, a single well-defined
decision rule, frozen-before-holdout parameters), are frozen now and
binding on that later work.

Per the process this ADR follows: this revision needs its own independent
Codex re-review, specifically evaluating whether this scope-reduction is a
legitimate, well-justified deferral (not a hidden weakening of the actual
gating requirement) and whether B.2 — reconfirmed clean three times running
— together with B.9's now-frozen constraints, is sufficient for v2
implementation to begin. v2 implementation does not start until that
re-review finds Critical=0/High=0 with any remaining Medium findings
credibly dispositioned as non-blocking.
