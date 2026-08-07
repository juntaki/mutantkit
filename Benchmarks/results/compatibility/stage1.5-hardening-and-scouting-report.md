# Stage 1.5 — Measurement Hardening & Cost Decomposition, final report

Generated 2026-08-06. Branch `feature/mutantbench-compatibility-lane`.

## Stopping condition

**GitHub Actions billing failure blocks all further CI dispatch**, discovered
mid-Section-7:

```
The job was not started because recent account payments have failed or your
spending limit needs to be increased. Please check the 'Billing & plans'
section in your settings.
```

Confirmed real (workflow run `31069367547`: all 3 jobs `skipped`/failed with
0 steps executed — no compute was actually spent, but nothing further can
run until this is resolved in GitHub's own billing settings). This is
outside anything fixable from this branch. No further CI dispatch was
attempted after this was found. The full 3-project × 3 modes × 3
repetitions sweep was **never dispatched**, per instruction — this report
stops at a cost proposal, not a dispatch.

---

## 1–6. Stage 1 baseline + hardening (complete, CI-verified)

- **Stage 1 baseline commit**: `d04415a` (record), building on the fixed
  Stage 1 run `31023117878` (`Benchmarks/results/compatibility/
  xcode-15.2-swift-5.9-macos-14/stage1-calibration/baseline.json`).
- **Hardening commits** (Sections 1–6, all real, tested locally, and the
  disk/phase/budget/job-split changes verified end-to-end on CI):
  - `d04415a` — Stage 1 baseline record + real disk measurement
    (`DiskMeasurement`, `workingDirectoryGrowthBytes`); caught and fixed a
    4th real bug (`directorySizeBytes` returned `0`, not `nil`, for a
    missing directory).
  - `285bbda` — real phase-timing extraction (`MutantKitPhaseTimings`/
    `MuterPhaseTimings`) from each tool's own real report fields, tested
    against the real Stage 1 fixture reports.
  - `58ae1af` — Section 4 comparability addendum (operator-family/
    source-span distribution) + Section 5 `BenchmarkCostEstimate`/
    `BenchmarkBudgetGuard`/`budget-check` subcommand.
  - `b7b820d` — Section 6 `setup-tools`/`calibrate` job split with
    SHA-256-verified tool-bundle reuse.
  - Verified together end-to-end on CI: run `31028102828`
    (`setup-tools` + `calibrate`, all 19 steps green, correctness gate
    still clean after the restructuring).
  - `9c05b96`/`4b62f8b` — Section 7 prep: `--modes` flag, swift-syntax
    patch, `scout-swift-syntax` job (never executed on CI — billing block).

### Disk measurement (Section 2)

Wired for real into both adapters (`bytesBefore`/`bytesAfter` around each
`tool.run` call). Not yet re-exercised on a completed CI run since the
rename (the last CI run predates this field's real activation in the
report path) — the type and unit tests (10/10, including the real
missing-directory bug fix) are the current evidence; a fresh CI run would
populate real `workingDirectoryGrowthBytes` values, still pending.

### Phase timings (Section 3)

Real, from MutantKit's own `report.json` fields — not invented
instrumentation. Confirmed against the real Stage 1 incremental-mode
report (committed as a test fixture):

- 100% of all 14 real mutant executions across Stage 1's 3 modes ran
  `executionMode: isolated` (0 `schemata`).
- Baseline (build+test) is a small, stable fraction of each mode's total
  (~15–20%); summed per-mutant build+test dominates (~78–80%).

Muter's own report has no per-mutation phase breakdown at all (only one
total `timeElapsed` + operator counts) — this is the real, observable
external boundary; `MuterPhaseTimings` reflects exactly that, nothing
inferred.

---

## 7. Scouting

### Structural finding (the dominant result of this section)

Checked **every** corpus project's real `Package.swift` `swift-tools-version`
directly (not assumed):

| project | swift-tools-version | usable under Xcode 15.2 / Swift 5.9.2? |
| --- | --- | --- |
| swift-numerics | 5.9 | yes (Stage 1's own project) |
| swift-syntax | 5.9 | yes |
| swift-argument-parser | 5.9 (baseline itself FAILED, unrelated reason) | no (excluded for baseline reasons, not tools-version) |
| alamofire | n/a (baseline itself FAILED, unrelated reason) | no (excluded for baseline reasons) |
| swift-collections | 6.2 | **no** |
| swift-async-algorithms | 6.2 | **no** |
| swift-dependencies | 6.3 | **no** |
| hummingbird | 6.1 | **no** |
| swift-composable-architecture | 6.1 | **no** |
| grdb-swift | 6.1 | **no** |

**Only 2 of the 10 corpus projects are even manifest-resolvable under the
pinned compatibility-lane compiler — independent of any per-file scoping
decision.** The originally proposed Project A (`swift-dependencies`) and
Project B (`swift-async-algorithms`) are both structurally incompatible.
Per the standing fallback rule, both were replaced by the one remaining
viable corpus entry: **`swift-syntax`**.

This means the compatibility lane's real project pool today is **2, not
3+** — a real ceiling on Plan S/M/F below, not a scouting shortfall.

### Selected file — `swift-syntax` / `Sources/SwiftSyntax/AbsolutePosition.swift`

| field | value |
| --- | --- |
| selected file | `Sources/SwiftSyntax/AbsolutePosition.swift` |
| line count | 37 (pre-patch) |
| MutantKit planned mutations | **2** (real, local `mutantkit plan`) |
| Muter estimated candidates | **2** (same 2 relational sites; ROR is the only Muter operator with any candidate in this file — 0 ternary/logical-connector/side-effect noise) |
| operator-family breakdown | 100% `swift.core.relational-operator-replacement` / `RelationalOperatorReplacement` |
| related test | `Tests/SwiftSyntaxTest/AbsolutePositionTests.swift` (real, dedicated, pre-existing) |
| incremental patch target | adds `isBefore(_:)` next to the existing `<` overload + `testIsBefore()` |
| estimated Actions minutes | **18.6 min** (real `budget-check` output: 960s shared setup + 91.9s MutantKit + 61.4s Muter estimate) |

**Real local verification performed** (no Xcode 15.2 available locally, so
these ran under this machine's own Swift 6.3.3 — a real, if not
toolchain-identical, signal):

- `swift build --target SwiftSyntax`: clean, 9.4s.
- Full real baseline on a **fresh clone**: `swift build --build-tests`
  42.2s + `swift test --skip-build` 51.0s = **93.2s total**, 3467 XCTest +
  2 Swift Testing tests, **0 failures**.
- Patch (`Benchmarks/expected/swift-syntax.patch`, SHA-256
  `3b10e15b79e839714abb58623a3b5070d9fb3ea6a900ae322a4aa18ce92d3393`)
  verified to `git apply --check` clean on a fresh checkout and pass
  `swift test --filter AbsolutePositionTests` (6/6) both before and after
  applying.
- `mutantkit plan` against the scoped file: 2 real candidates, 1 file,
  operator `swift.core.relational-operator-replacement` only.
- `BenchmarkRunner budget-check`: **passed**, real numbers as above.

**Never run on the actual CI toolchain** (Xcode 15.2/Swift 5.9.2) — the
billing block hit before the `scout-swift-syntax` job could execute. All
numbers above are real but locally-observed, not CI-confirmed identical.

---

## 8. Comparability

**swift-numerics (Stage 1, real CI data):**

```
exactly matched mutations:       0
approximately matched mutations: 0
MutantKit-only mutations:        6
Muter-only mutations:            5
```

Both tools independently found the **same real source lines** in the
incremental-mode `GCD.swift` (29, 31, 35, 49×2 for both) — a real,
high-confidence line-level overlap the current matching key (text-hash
based, deliberately not line/column) cannot confirm, because Muter's real
`report.json` never includes `mutationSnapshot` (before/after text) at
all — confirmed against Muter's own `CodingKeys`. **This is not treated as
an exact match just because the lines agree** — line agreement alone is
not proof of the same underlying mutation without the actual before/after
text, which Muter structurally never reports.

**swift-syntax**: not computed — no completed run (CI blocked).

---

## 9. RelationalOperatorReplacement schemata-ization effect estimate

**Based on Stage 1's real data only** (swift-numerics; swift-syntax has no
completed run to include). This is explicitly a 1-project estimate, not
the 3-project estimate originally scoped — the billing block prevented
completing the 2nd data point.

From the real Stage 1 baseline (`baseline.json`):

```
Relational mutations total (MutantKit, 3 modes): 4 + 4 + 6 = 14
All 14 ran executionMode=isolated (0 schemata)   — confirmed field-level
Isolated fallback total time (build+test sum):    467.6s
  build sum: 86.7 + 65.6 + 85.9 = 238.2s
  test sum:  69.5 + 67.5 + 92.4 = 229.4s
1 relational mutation's average build+test cost:  467.6 / 14 = 33.4s
Share of MutantKit's total tool wall time (580.8s): 467.6 / 580.8 = 80.5%
```

**Schemata-izing removes redundant per-mutant *build* cost** (one combined
build embeds every mutant variant; the mutant is selected at runtime) —
it does **not** automatically remove per-mutant *test execution* cost
unless test batching is also in play. No real schemata cost-per-mutant
data exists for ANY operator other than `bool-literal-inversion` in this
project, and **bool-literal-inversion's own real numbers are explicitly
not reused here** — it is a structurally different operator (a single
literal-flip vs. a relational-operator substitution with potentially
different symbol-resolution/build-invalidation cost), and reusing its
number would overstate confidence. This estimate is therefore a
build-cost-removal projection, not a transplanted measurement:

```
Removable amount = build sum (238.2s) minus one retained combined build
                    (~13.9-23.0s, the real per-mode baseline-build range
                    observed) ≈ 215-224s removable from the isolated total

lower bound:  ~30% reduction of the isolated total (conservative: only
              some of the redundant build cost is actually removable in
              practice — schemata build/link overhead is real, not zero)
expected:     ~48% reduction (removes most of the 238.2s build-sum
              redundancy, test-execution cost 229.4s stays largely as-is)
upper bound:  ~65% reduction (build-cost removal plus some realistic test
              batching, matching schemata's own documented design intent)
```

Translated to MutantKit's total wall time (isolated is 80.5% of it):

```
lower bound:  ~24% reduction of total MutantKit wall time
expected:     ~39% reduction
upper bound:  ~52% reduction
```

**Explicitly not a promise**: this is a single-project, build-cost-driven
projection. It does not model swift-syntax's or any other project's own
build/test cost ratio, which could differ meaningfully (swift-syntax's own
real local baseline, 93.2s for build+test combined on a much larger
package, suggests build/test cost ratios vary a lot by project — the
projection above should not be assumed to transfer directly).

---

## 10. 3-project readiness gate

**NOT READY.** Item by item:

```
disk metrics connected:            YES (Section 2, real, unit-tested;
                                    not yet re-exercised on a fresh CI run)
phase timings complete:            PARTIAL (MutantKit: full, real, tested;
                                    Muter: total-only, which is the real
                                    external boundary, not a gap)
tool artifact reuse verified:      YES (CI-verified, run 31028102828)
3 projects each green scouting:    NO — only 1 (swift-numerics, real CI
                                    data from Stage 1); swift-syntax has
                                    real LOCAL data only, never run on CI
                                    (billing block); a 3rd toolchain-
                                    compatible corpus project does not
                                    exist today (Section 7 finding)
candidate counts known:            PARTIAL (swift-numerics: real CI;
                                    swift-syntax: real local plan.json,
                                    not CI-confirmed)
per-project cost estimate available: YES for both (Stage 1 real;
                                    swift-syntax real local budget-check)
correctness green:                 YES for swift-numerics (CI); UNKNOWN
                                    for swift-syntax (never executed)
unclassified failure 0:            YES so far (all failures this session
                                    were classified: 4 real code bugs,
                                    fixed; 1 billing failure, external)
comparability recorded:            YES for swift-numerics; N/A for
                                    swift-syntax (no run)
```

**Primary blockers, in order:**
1. GitHub Actions billing failure — blocks literally all further
   dispatch, must be resolved by the account owner outside this branch.
2. The corpus itself structurally has only 2 (not 3+) toolchain-compatible
   projects today — a 3rd would require either a newer pinned toolchain
   or adding a new, genuinely 5.9-compatible project to the corpus.

---

## 11. Plan S / M / F — cost proposal (not dispatched)

All three plans are built from real per-mutant costs (Stage 1's real
33.4s/mutation average, and swift-syntax's real-but-local baseline/build
numbers) — extrapolated, never fabricated from nothing. **All three plans
below are capped at 2 projects** (swift-numerics, swift-syntax), per the
Section 7 structural finding — a 3rd project cannot be added without
either a newer pinned toolchain or a corpus addition.

### Plan S — scoped files (current scouting scope, ×3 repetitions)

```
2 projects, current scoped files (GCD.swift: 2 real MutantKit candidates
after patch across 3 modes → discovered counts 4/4/6 in Stage 1;
AbsolutePosition.swift: 2 candidates, not yet patch-tested for its own
after-patch count)

Per-project tool time (×3 reps, linear-scaling assumption — isolated mode
rebuilds every mutant every rep, limited warm-cache benefit):
  swift-numerics: 851.4s (Stage 1, 1 rep) × 3 ≈ 2554s (~42.6 min)
  swift-syntax:   estimated (93.2s baseline + 2×33.4s×2 tools ≈ 227s,
                  1 rep) × 3 ≈ 681s (~11.4 min) -- LOWER CONFIDENCE,
                  local-only baseline, no real mutation-run timing yet

Estimated Actions minutes: ~42.6 + ~11.4 + 16 (one shared setup) ≈ 70 min
Estimated job count: 3 (setup-tools + 2 project jobs, run in parallel
                     after setup — wall time ≈ max(42.6, 11.4) + 16 ≈ 59 min
                     if parallelized, ~70 min if sequential)
Estimated mutation count: ~14 (numerics) + ~4-6 (syntax, unconfirmed) ≈ 18-20
Longest job: swift-numerics calibrate, ~42.6 min (within the 45-min
             per-job timeout already used, but with little margin left
             for CI variance)
Timeout risk: MODERATE for the swift-numerics job specifically -- 3 reps
             at observed cost is close to the current 45-min job timeout;
             would need the timeout raised or reps reduced if variance is
             high
Cost confidence: swift-numerics side is HIGH (real CI data, ×3 linear
             extrapolation); swift-syntax side is LOW (never run on CI)
Comparison value: real, direct, same scope as scouting -- but small
             sample size (single-digit mutations per tool per project)
             limits statistical confidence in any per-project speed
             comparison
Main constraint: swift-syntax's own real per-mutation cost is unmeasured;
             this plan's total is a projection, not two real numbers
```

### Plan M — scoped modules (whole module the selected file belongs to, ×3 repetitions)

```
2 projects, module-level scope:
  swift-numerics: Sources/IntegerUtilities/** (confirmed via real local
                  `mutantkit plan` earlier this session: 83 real ROR
                  mutations across 6 files -- the exact scope that
                  originally blew Stage 1's 900s timeout in isolated mode)
  swift-syntax:   Sources/SwiftSyntax/** (NOT measured -- SwiftSyntax is
                  swift-syntax's single largest module, likely hundreds
                  of relational-operator sites; no real candidate count
                  exists for this scope)

Estimated Actions minutes: swift-numerics alone, at 83 candidates ×
             ~33.4s/mutation × 2 tools (rough, Muter's own per-candidate
             cost assumed similar) × 3 reps ≈ 83 × 33.4 × 2 × 3 ≈ 16,630s
             (~277 min / ~4.6 hours) for ONE project alone, before
             swift-syntax's own (larger, unmeasured) module cost is even
             added
Estimated job count: 3 (setup + 2 project jobs), but each project job
             would need timeout-minutes far beyond the current 45-60 min
Estimated mutation count: 83 (numerics module, real count) + unknown,
             likely several hundred (syntax module, unmeasured)
Longest job: swift-numerics module alone, ~4.6 hours at 3 reps -- already
             exceeds GitHub's default job limits without an explicit,
             large timeout-minutes increase
Timeout risk: HIGH -- this is the exact scope Stage 1 already proved
             blows past a 900s per-invocation timeout in isolated mode;
             at 3 reps it is roughly 3x that already-excessive cost
Cost confidence: MODERATE for swift-numerics (real 83-candidate count,
             but per-candidate cost extrapolated from a 2-6-mutation
             sample); LOW for swift-syntax (module-level count never
             even measured)
Comparison value: would exercise a much more realistic isolated-mode
             workload, closer to the "isolated fallback dominates" Stage
             1 finding at scale -- but at a cost this session's own
             budget guard would (correctly) refuse without an explicit,
             large override
Main constraint: real, already-demonstrated timeout/cost risk (Stage 1's
             own root-caused bug); NOT recommended without schemata-izing
             RelationalOperatorReplacement first, which would remove most
             of this cost
```

### Plan F — full projects (entire production source, ×3 repetitions)

```
2 projects, full-project scope:
  swift-numerics: all Sources/** -- real local count from earlier this
                  session's investigation: 417 mutations across 6
                  operators (only bool-literal-inversion schemata-
                  eligible); the session's own prior attempt at this
                  scope ran ~95 minutes with 5 parallel workers and did
                  NOT finish even once
  swift-syntax:   all Sources/** -- never measured; swift-syntax is one
                  of the largest projects in the whole 10-project corpus
                  (600+ files); a full-project candidate count would
                  likely be in the thousands

Estimated Actions minutes: not usefully estimable with any real
             confidence -- the one real data point (swift-numerics
             full-project, single-repetition, single-tool) already took
             ~95 minutes without completing; ×3 repetitions ×2 tools
             ×2 projects is credibly many hours to low tens of hours
Estimated job count: 3, each needing multi-hour timeouts
Estimated mutation count: 417 (numerics, real) + thousands (syntax,
             estimated only)
Longest job: unknown, credibly >4 hours per project per tool
Timeout risk: VERY HIGH -- this is that exact scope's own prior
             real failure-to-complete, demonstrated this session
Cost confidence: real for the "this doesn't finish in reasonable time"
             conclusion; not estimable as a number with any real
             confidence
Comparison value: would be the most representative "how these tools
             really perform on a real project" measurement -- but is not
             achievable today without schemata-izing enough of MutantKit's
             own operator set first to make isolated-mode cost tractable
Main constraint: already-demonstrated non-completion at 1 repetition;
             not a responsible thing to dispatch as-is
```

---

## 12. Next improvement — formally selected

**`feature/schemata-relational-operator-replacement`.**

Decision rule applied: "relational isolated execution is the largest
dominating factor" — confirmed directly from real field-level data (100%
of Stage 1's 14 mutant executions ran isolated; per-mutant build+test sums
account for ~78–80% of MutantKit's total tool wall time; baseline is a
small, stable ~15–20% by comparison). This was confirmed with only 1
project's real data (swift-numerics), not the originally-planned 3 —
**Plan M's own cost table above is itself further evidence for this same
conclusion**: the 83-candidate module-scope estimate (~4.6 hours at 3 reps
for one project) is dominated by the same isolated-fallback mechanism,
and schemata-izing would directly remove most of that cost before any
cache or setup-time improvement would matter.

No other candidate in the decision list is supported by real evidence
this session: tool-build/setup cost is real (~16 min) but fixed and
already amortized across jobs (Section 6); baseline-build cost is a small,
stable fraction, not the dominant factor; test-repetition cost has not
been isolated as dominant (test and build sums are comparable, ~229s vs.
~238s); cross-tool matching is a real, honestly-reported limitation but
does not block correctness or the performance question; CI variance has
not been characterized as a real problem (all 3 completed Stage 1 CI runs
were stable and predictable in wall time).

### Next branch

```
feature/schemata-relational-operator-replacement
```

### Acceptance criteria (proposed, implementation not started)

```
- isolated/schemata differential disagreement = 0
- SwiftPM acceptance suite green
- Xcode acceptance suite green
- confirmation parity green
- phantom = 0
- falseScored = 0
- backendDisagreements = 0
- exercised against >=100 real relational-operator mutations across the
  2-project compatibility corpus, or the full count obtainable if fewer
  than 100 real candidates exist across swift-numerics + swift-syntax at
  full-project scope (explicitly: NOT the full 3-project corpus this
  directive originally asked for -- only 2 projects are toolchain-viable
  today, per Section 7's own finding)
- measured reduction in isolated-fallback wall time vs. the Stage 1
  scouting baseline recorded in this report (Section 9's own estimate:
  expect roughly 24-52% reduction in MutantKit's total tool wall time for
  RelationalOperatorReplacement-dominated workloads; this run's own real
  before/after numbers are the actual acceptance bar, not the estimate)
```

---

## 13. Final status

```
Stage 1 baseline commit:                d04415a
Section 1-6 hardening commits:          d04415a, 285bbda, 58ae1af, b7b820d
Section 7 prep commits:                 9c05b96, 4b62f8b
CI verification run (Section 5+6):      31028102828 (setup-tools + calibrate,
                                         19/19 steps green)
2-project scouting workflow run:        31069367547 -- FAILED before any
                                         job started (GitHub Actions billing
                                         failure, external, unfixable from
                                         this branch)
Selected source files:
  swift-numerics: Sources/IntegerUtilities/GCD.swift (Stage 1, real CI data)
  swift-syntax:   Sources/SwiftSyntax/AbsolutePosition.swift (real LOCAL
                  data only -- 2 MutantKit candidates, 93.2s baseline,
                  patch verified; never run on the real CI toolchain)
Candidate counts:
  swift-numerics: 4 (cold/warm) / 6 (incremental) -- real, CI-confirmed
  swift-syntax:   2 -- real, LOCAL only
Per-mode/tool times:                    see Section 1.5 baseline.json (real,
                                         swift-numerics only)
Disk measurement:                       wired, unit-tested; not yet
                                         re-exercised on a fresh CI run
Phase-level times:                      real, MutantKit full / Muter
                                         total-only (the real external
                                         boundary)
Operator/backend-family counts:         real, swift-numerics only (Section 8)
Exact/approximate/tool-only counts:     0 / 0 / 6 MutantKit-only / 5
                                         Muter-only (swift-numerics, real)
Setup-artifact reuse effect:            verified structurally on CI (run
                                         31028102828); a fixed-cost
                                         reduction across N project jobs
                                         within one workflow run, not yet
                                         measured against a true N>1
                                         project run (billing block)
3-project readiness:                    NOT READY (Section 10 -- billing
                                         block + corpus has only 2
                                         toolchain-compatible projects)
Plan S/M/F costs:                       Section 11 (Plan S ~70 min/2
                                         projects, Plan M ~4.6h+ for one
                                         project's module scope alone,
                                         Plan F not completable at current
                                         operator mix)
Next improvement (formally chosen):     feature/schemata-relational-operator-replacement
Next branch:                            feature/schemata-relational-operator-replacement
Acceptance criteria:                    Section 12 (above)
```

**Full 3-project × 3 modes × 3 repetitions was never dispatched.** This
report stops at the cost proposal, as instructed. The blocking condition
(GitHub Actions billing) requires action outside this branch before any
further real CI data — including the swift-syntax scouting run itself —
can be obtained.
