# Benchmarks

Real measurements behind the execution recommendations in
[Execution](execution.md) and [Configuration](configuration.md). Not
synthetic — every number here is from a real, large iOS app, run through
`mutantkit` itself. See [Performance budget](performance-budget.md) for
what these numbers say (and don't yet say) about what "fast enough for
daily CI use" means.

## Worker count and simulator pooling

A real comparison against a real, large iOS app (100 real mutants, isolated
mode throughout, `workers: 1` + `incrementalBuild` + `selectCoveringTests`
as the tuned reference point) measured:

| profile | wall clock | vs. N=1 tuned reference | outcome parity | integrity violations |
| --- | --- | --- | --- | --- |
| `workers: 1`, `incrementalBuild` + `selectCoveringTests` only (reference) | 5624s | 1.00x (reference) | reference | 0 |
| **`workers: 2`, `simulatorPool: true` (recommended production profile)** | **2597s** | **2.17x** | **100/100 — identical to the reference, mutant-for-mutant** | **0** |
| `workers: 4`, `simulatorPool: true` | 1780s | 3.16x | 99/100 — one mutant `.flaky` under 4-way load | 0 |

`workers: 4` is *not* recommended, deliberately, despite the larger raw
speedup: a targeted replay investigation of that one disagreement (5
independent replays, both at `workers: 1` and at `workers: 4`-shaped
conditions) reproduced it consistently under neither configuration in
isolation — the most consistent remaining explanation is genuine resource
contention from the other ~85 mutants running concurrently in the real
sweep, a real, structural property of *more* concurrent workers that a
single-mutant replay cannot rule out. `workers: 4` remains a real, usable,
faster *experimental* setting if your project and CI hardware can absorb
that risk — it is not the shipped default.

`testBatchSize` predates this profile and is still supported, but a real
benchmark at the same scale found it slower than `simulatorPool` for
comparable settings; it remains available for CI runners that restrict
simulator-clone provisioning.

## Untuned defaults, for comparison

Separately, a smaller real cross-check (32 mutants, same real app) compared
the recommended production profile against `init`'s own *untuned* defaults
(no `incrementalBuild`/`selectCoveringTests`/`simulatorPool` at all — what a
config predating this profile, or a hand-written one, would run with). The
untuned defaults took 2579s for those 32 mutants (~81s/mutant) — slower even
than the tuned N=1 reference above (~56s/mutant), before any of the
production profile's own gains. This is a different measurement (different
mutant count, different purpose — showing the untuned defaults are the
worst starting point, not a speedup baseline comparable to the N=1/N=2/N=4
table above) and is not combined with it.

## `execution.profile: optimized` correctness parity

`optimized` is proven, on a real fixture with both a covered and a
genuinely-uncovered mutable line, to report identical per-mutant verdicts
and identical `MutationScore.tested` against `reference` on the same plan
(`ExecutionProfileCoverageParityAcceptanceTests`) — see
[Execution](execution.md#executionprofile-known-safe-defaults-chosen-for-you)
for what it actually turns on and why `incrementalBuild`/`sharedModuleCache`
are deliberately excluded from it.
