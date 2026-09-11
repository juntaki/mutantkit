# Performance budget

v0.7 Production Usability's own mandate: define what "fast enough for daily
CI use" means, numerically, from real measured evidence — before optimizing
anything further. This is that definition, drawn only from measurements
that already exist (see [Benchmarks](benchmarks.md) and the internal
benchmark evidence it summarizes, not part of this public repo) plus one real, already-paid-
for CI run's own timing data. Where no measurement exists, this says so
explicitly rather than estimating.

## SwiftPM (macOS)

| Category | Budget | Basis |
| --- | --- | --- |
| Planning wall time | ≥ 0.16s floor (measured, trivial scale); undefined at realistic scale | `mutantkit plan --diff-base` against a real, minimal (2-file, 1-target) git-backed SwiftPM package, timed with `/usr/bin/time` (2026-09-11). This is a real floor for the command's own fixed overhead (config load, git diff, AST parse of the one changed file), not a claim about planning time at a realistic project size — no measurement yet exists for a project with a large source tree behind an unchanged majority. |
| Baseline wall time | ≤ ~2 min for a swift-numerics-sized project (70 tests, 3 targets) | Post-fix baseline-profiling mean 91.22s (internal `p12-coverage-profiling` benchmark); rounded up for build+test overhead not isolated in that measurement. |
| Campaign time (full) | **undefined pending measurement at real-app scale** | Existing SwiftPM numbers are all small-corpus (48–65 mutants); no equivalent to the large-scale Xcode figures below exists for SwiftPM. |
| PR-diff time | ≈ 11.5s floor (measured, trivial scale) for a 2-mutation diff (`plan` 0.16s + `run` 11.38s, isolated strategy, 4 workers); undefined at realistic PR scale | Same real, timed measurement as above (2026-09-11), a real 2-changed-file/2-planned-mutation diff against a trivial package. Real evidence for a previously entirely-unmeasured category, but at a scale far below a realistic PR (typically more changed lines, more candidate mutations, and a non-trivial baseline build/test) — treat this as proof the command path itself has low fixed overhead, not as the number a realistic PR would see. |
| Build count | Prefer a `--skip-build`-style per-test-loop skip (measured **−30%** per invocation) | Internal `p12-coverage-profiling` benchmark. |
| Test invocation count | **undefined pending measurement** | No SwiftPM-specific count exists distinct from the Xcode-specific number below. |
| CI acceptance-lane time (proxy for "fast enough daily") | 5–10 min | Real public CI run `34452854291`: `swift-package` 573s, `swift-package-coverage` 334s. |

## Xcode + iOS Simulator

| Category | Budget | Basis |
| --- | --- | --- |
| Planning wall time | **undefined pending measurement** | Same gap as SwiftPM. |
| Baseline wall time | ≤ ~150s per mutant-1 baseline (build+test only) | the internal reference iOS app (not part of this public repo): build 57.34s + test 87.23s = 144.58s (`p12-coverage-profiling`). Per-test coverage profiling (976.15s in that same run) is a separate, intermittent, cacheable cost — budgeted separately, not folded into every run's baseline. |
| Campaign time (100-mutant reference shape) | Recommended production profile (`workers:2`+`simulatorPool`) ≈ 2600s (~43 min); tuned `workers:1` reference ≈ 5624s (~94 min) is the ceiling any config change must stay under or must justify regressing past | The one real, outcome-parity-gated, production-recommendation-driving number in the whole evidence base (`docs/benchmarks.md`, 100/100 parity, 0 integrity violations) — anchor here, not on any provisional/n=1 number. |
| Campaign time (940-mutant, real full-scale) | Optimized profile: 14h07m; hard ceiling: must not regress past the 23h37m untuned baseline | Internal benchmark evidence. |
| PR-diff time | **undefined pending measurement** | The single largest real gap relative to what a daily-CI budget needs — most CI runs are diff-scoped, not full campaigns, and nothing has ever measured this. |
| Simulator cost ($ or CI-minute per mutant) | **undefined pending measurement** | No wall-clock number has ever been converted to a dollar or CI-minute figure. |
| Build count | ≤ 1 build per mutant (isolated mode) | Gate 3A (internal, not part of this public repo), 14 mutants: 13 isolated builds vs. 7 schemata. |
| Test invocation count | ≤ 1 test invocation per 3–4 mutants (batched-isolated target) | Same Gate 3A run: 4 (wave-batched) vs. 12 (schemata) invocations for 14 mutants. |
| CI acceptance-lane time (proxy) | ≤ 17 min per job; a job that fails near a 30-minute ceiling, or never completes, is a budget violation requiring investigation before a release | Real successful Xcode-backed jobs in run `34452854291` ranged 6m39s–16m20s; that same run also surfaced a genuine violation (`xcode-project` failed at 28m09s) and a job that never completed (`xcode-wave-early-kill`) — both real, motivating examples, not hypothetical. |

## What this budget does not cover, and why

One category the v0.7 mandate explicitly asks for still has **zero**
existing measurement anywhere in this project's benchmark history:

- **Simulator dollar/CI-minute cost.** Every simulator number above is
  wall-clock only. GitHub bills macOS runner-minutes at a 10x multiplier
  over Linux, so a wall-clock budget alone understates the real cost —
  nobody has yet converted the wall-clock evidence into a cost figure.

**PR-diff / changed-files-only mutation time** (2026-09-11 update): a real
floor is now measured for SwiftPM (see the table above) — a trivial,
2-mutation diff completes in ≈11.5s end to end. This closes the "zero
measurement at all" gap but not the underlying question: nothing yet times
a *realistic-scale* PR diff (more changed lines, more candidate mutations,
a non-trivial baseline), and the Xcode + iOS Simulator path — the one this
document's own table calls "the single largest real gap relative to what a
daily-CI budget needs" — remains completely unmeasured, since a
diff-scoped Xcode/simulator run needs a real, git-backed Xcode project
fixture this measurement pass did not have on hand.

Filling either remaining gap needs a dedicated measurement pass, not an
estimate folded into this document. Until then, treat both as explicitly
open next steps for v0.7, not as budgets with an assumed value of
"acceptable."

## Real, already-observed budget violations

Public CI run `34452854291` (`fd7abcb`, the v0.4 Trust Closure batch)
surfaced two real violations of the Xcode acceptance-lane budget above,
worth carrying forward as concrete v0.7 targets rather than abstract goals:

- `Acceptance (xcode-project)` failed at 28m09s on its first attempt — a
  known, pre-existing, intermittent CI flake in this exact job (confirmed
  independent of this run's own content by checking prior commits' CI
  history), but still a real instance of a job running close to its
  30-minute ceiling before failing.
- `Acceptance (xcode-wave-early-kill)` never completed within this run's
  observation window — real evidence that at least one CI lane can hang
  past normal bounds, consistent with this project's own, separately
  recorded "batch hang containment: still open" finding.

## CI cost / duplication (informational, not yet acted on)

A parallel audit found `oss-public/.github/workflows/ci.yml` runs 19
acceptance legs, each independently resolving SwiftPM dependencies and
compiling from scratch (~3.5–4.5 min per job, measured near-constant
regardless of fixture) — 26 separate from-scratch compilations of the same
commit per CI run, zero `actions/cache` usage anywhere in `ci.yml` (contrast
with `release-validation.yml`, which already has the exact SwiftPM-
dependency-cache pattern in three places). The two highest-leverage,
lowest-risk opportunities identified:

1. Cache resolved SwiftPM dependencies (`.build/checkouts`,
   `.build/repositories`, `~/Library/Caches/org.swift.swiftpm`) keyed on
   `Package.resolved`, copying the pattern already proven in
   `release-validation.yml` — safe, no correctness/isolation risk, since it
   never caches a compiled artifact or crosses build configs.
2. Build the debug test harness once per `ci.yml` run and share it via
   `actions/upload-artifact`/`download-artifact` across the acceptance
   matrix, `unit`, and the schemata jobs — the pattern this public overlay
   is documented (`release-validation.yml`'s own header comment) as having
   lost relative to the private repo's own `ci.yml`. Estimated at 60–80
   minutes of aggregate runner-minutes per CI run. Needs care for the two
   schemata jobs, which also need a separate release-config build layered
   on top — not unsafe, just not "drop in with no thought."

Neither has been implemented yet — this is discovery evidence for a future
CI-cost pass, not a completed v0.7 item. Full detail (real timestamps, job-
by-job build/test splits, and the reasoning against `analyze`'s `xcodebuild
clean build`, which should NOT be cached): the corresponding v0.7 audit
record (internal, not part of this public repo).
