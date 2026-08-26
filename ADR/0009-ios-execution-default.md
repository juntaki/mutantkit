# ADR-0009: iOS/Xcode-Simulator execution default is optimized isolated, not schemata-first

- **Status:** Accepted, implemented.
- **Date:** 2026-08-25

## Context

Gate 3 (`Research/benchmarks/gate3-ios-schemata-2026-08-23/GATE3-RESULT.md`) set out to answer whether a "schemata-first hybrid" execution strategy should become the default for Xcode/iOS-Simulator mutation testing, on the working hypothesis (carried from the schemata architecture's own original design intent) that one shared build embedding every mutation, selected at runtime, would out-perform isolated mode's one-rebuild-per-mutant baseline once the correctness and containment gaps found along the way were fixed.

Over roughly twenty phases against a real, frozen 940-mutant iOS project (`yomu-frozen-940`), that gate fixed a real succession of genuine bugs and gaps on the way to a clean comparison: baseline-sharing duplication, a missing `noCoverage` pre-check, native-XCTest-timeout containment, a batch-hang-containment blocker in isolated mode's own wave-based early-abort path, an equivalent hang-containment story for schemata's own token dispatch, and — found only once measured at real, 100-mutant scale — a shared xcresult-bundle-attribution gap affecting both backends' batch execution paths alike. Every one of those fixes was real and is retained (see below). None of them changed the outcome this ADR records.

## Decision

**Xcode/iOS-Simulator mutation execution's default primary is optimized isolated execution** (`execution.strategy: isolated`, `selectCoveringTests: true`, `incrementalBuild: true`, `testBatchSize: 10`, `earlyAbortSelectedTests: false`).

Schemata-first is **not** the default or auto-selected primary for this platform. The schemata implementation itself is **not removed** — `execution.strategy: schemata` remains a fully-supported, explicit opt-in for advanced or research use, and the fixes this gate made to it (hang-containment, batch-ambiguity recovery, fallback observability) are real, retained improvements to that opt-in path.

This decision is scoped to **Xcode/iOS-Simulator specifically**. It says nothing about, and does not change, schemata's standing for SwiftPM/macOS execution — a different cost model this gate never measured (the README's own existing SwiftPM/macOS schemata numbers, +3–8% over isolated, come from an entirely separate benchmark).

No code change was required to enact the "default" half of this decision: `ExecutionSettings.strategy`'s own decode default was already `.isolated`, uniformly, for every project kind (Gate 3 Phase H18 confirmed this directly, with regression tests added rather than a fix). What Phase H16 changed is the evidence base for keeping it that way deliberately, not the behavior itself.

The planned full 940-mutant iOS schemata benchmark is **not scheduled**. The 100-mutant throughput gate (Phase H16) already answered the question it existed to ask.

## Evidence

| | Gate 3A (14 mutants) | Phase H16 (100 mutants) |
|---|---|---|
| Correctness | 14/14 outcome parity | 100/100 outcome parity, integrity 0 both backends |
| Isolated wall | 735s | 3928s |
| Schemata wall | 911s (+24%) → 931s post-H12.3/H12.4 (+27%) | 6383s (**+62.5%**) |

The performance gap **widened**, not narrowed, with corpus scale — the opposite of what the "schemata needs more tuning before it wins" working hypothesis predicted.

- Gate 1's own planner-time eligibility classification found 752/940 mutations embeddable in principle; Phase H16's real 100-mutant run found only `effectiveCount: 32/100` actually resolved via genuine schemata evidence, `fallbackCount: 68/100`.
- Token batching's own real contribution: ~3% of total wall at 14 mutants (Phase H6, measured directly, not estimated); at 100 mutants, only 2 real batch calls against 57 individual unbatched token dispatches — Phase H12.3's own safety-motivated narrowing (only exactly-one-selected-test tokens may share a batch, itself a necessary correctness fix, not a regression) means most of a real, diverse corpus's actual selection shapes cannot batch at all, so each pays its own full per-invocation Xcode/Simulator launch cost individually.
- Hang safety was proven for both backends independently (Phase H15B): isolated via wave-based early-abort (Phase H12.2C, ~25% faster than the original unbounded batch behavior it replaced); schemata via a structurally simpler mechanism — its own unbatched token-dispatch path never enables native XCTest per-test timeout at all, so there is no recover-and-retry cycle for a hang to exploit in the first place, and `ProcessSupervisor`'s own outer per-mutant deadline catches the first hang directly. Neither backend's hang-safety story depended on or was weakened by this decision.
- Phase H16's own 100-mutant corpus produced **zero** naturally-occurring hangs — there is no frequency data yet to justify a hang-history-based automatic mode switch, so none was built.

## Rejected

- Schemata-first as the iOS default execution primary.
- The full 940-mutant iOS schemata benchmark (superseded by Phase H16's own, decisive 100-mutant result).
- `earlyAbortSelectedTests: true` as a global default — Phase H13 measured its own ~2.1× normal-throughput cost on this same real corpus; it remains a manual, explicit opt-in for known-or-suspected hang-prone runs.
- Automatic hang-history-based adaptive routing between backends or modes — insufficient evidence (zero natural hangs observed at 100-mutant scale) to justify building it.
- A PIT-style "prioritized covering tests, bail on first detection within one shared invocation" scheduler for isolated mode — a promising direction surfaced by comparing MutantKit's own containment design against Muter/PIT/Stryker/mutmut/Infection/cargo-mutants (Phase H15's own research), but explicitly deferred to its own future research theme, not built as part of this gate.

## Retained

- Schemata backend, as an explicit, fully-supported opt-in (`execution.strategy: schemata`) — not deprecated, not removed.
- Shared-baseline establishment (`SharedBaselineEstablisher`) — benefits both backends, unconditionally.
- Native-XCTest-timeout containment (isolated batch mode) and its schemata-side equivalent groundwork.
- Isolated mode's wave-based early-abort (`earlyAbortSelectedTests`) and its own hang-containment fix (Phase H12.2B/C) — real, valuable, opt-in.
- Schemata token-batching, narrowed to single-selected-test tokens only (Phase H12.3) — safe, retained, just not a major performance lever at real-corpus scale.
- Batch-ambiguity recovery for both backends (`MutationRunner.testOneBatch`'s and `SchemataMutationRunner.prepareBatchedPrimaries`'s own `.infrastructureFailure → standalone reverify`, Phase H15C) — a genuine correctness hardening, independent of this decision.
- Fallback observability (`ExecutionStrategyReport.plannerFallbackReasonCounts`, Phase H19) — closes a real reporting gap in the schemata opt-in path.

## What comes next (not part of this ADR)

Per Gate 3's own closing research direction: the next performance investment goes to **optimized isolated**, not schemata — specifically, whether XCTest/`xcodebuild` can support a PIT-style "one shared invocation, covering tests ordered by likely-killer, bail on first failure/timeout" scheme, which would combine PIT's own containment semantics with Xcode's real cost model (Phase H13 already showed the naive "one test = one `xcodebuild` invocation" version of this, `earlyAbortSelectedTests`, costs too much in fixed per-invocation overhead to be a free win). That investigation is its own future research theme, out of this ADR's scope.

See `Research/benchmarks/gate3-ios-schemata-2026-08-23/GATE3-RESULT.md` for the full, phase-by-phase research record this decision is drawn from.
