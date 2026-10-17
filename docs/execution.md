# Execution

How a mutation run actually executes, beyond the bare field reference in
[Configuration](configuration.md). See [Evidence model](evidence-model.md) for
what a verdict actually proves.

## Recommended production profile

For an Xcode project/workspace or an Apple-platform SwiftPM package —
anything that leases a real Simulator — `mutantkit init` writes this
profile by default:

```yaml
execution:
  strategy: isolated
  workers: 2
  simulatorPool: true
  incrementalBuild: true
  selectCoveringTests: true
```

This is measured, not a guess. On a real 100-mutant run of a large iOS app
(isolated mode throughout):

| profile | wall clock | vs. reference | outcome parity |
| --- | --- | --- | --- |
| `workers: 1`, `incrementalBuild` + `selectCoveringTests` only (reference) | 5624 s | 1.00x | reference |
| **`workers: 2`, `simulatorPool: true` (recommended)** | **2597 s** | **2.17x** | 100/100, identical to the reference |
| `workers: 4`, `simulatorPool: true` | 1780 s | 3.16x | 99/100, one mutant `flaky` under 4-way load |

`workers: 4` is faster but is not the default: its one disagreement did not
reproduce in isolation, and the most likely explanation is resource contention
among the concurrent workers. Treat it as an experimental setting if your
project and CI hardware can absorb that risk. `testBatchSize` is still
supported, but at the same scale it was slower than `simulatorPool`; it stays
available for CI runners that restrict simulator-clone provisioning.

## `execution.profile`: known-safe defaults, chosen for you

Every setting in [Configuration](configuration.md) is off/nil by default
and opted into one at a time — deliberately, since each carries its own
real trade-off (see each one's own comment there). `execution.profile` is a
single switch for the common case of "I have not read all of that yet,
just turn on whatever is safe for my project":

```yaml
execution:
  profile: optimized   # reference (default) | optimized | experimental
```

- **`reference`** (the default) is today's real defaults, completely
  unchanged — the correctness oracle every other profile is measured
  against.
- **`optimized`** turns on only the features this codebase already ships
  and already treats as safe, and only the ones *this specific project's*
  own real characteristics actually support: schemata execution when the
  plan has at least one candidate this build's schemata backend can embed
  (everything else still gets a real isolated-mode verdict via the
  existing per-mutant fallback — schemata is never all-or-nothing). By
  itself, `optimized` is correctness-neutral: on a fixture with both a covered
  and an uncovered mutable line, it reports the same per-mutant verdicts and the
  same `MutationScore.tested` as `reference` on the same plan
  (`ExecutionProfileCoverageParityAcceptanceTests`).
- **`experimental`** is `optimized` plus features implemented but not yet
  proven safe for general use. That bucket is honestly empty right now —
  see `ExecutionProfile`'s own doc comment for the one real candidate that
  was looked at and deliberately left out.

A profile resolves into concrete settings, which means it can replace a
value you wrote yourself. `run` says so as it happens, naming each setting
it changed and both values, so a config file that was not honoured never
looks like one that was:

```
Execution profile: optimized — enabled schemata, incrementalBuild.
  overrides: execution.strategy: isolated → schemata
```

`mutantkit execution-profile` reports the same thing before anything runs.

**Three things `optimized`/`experimental` deliberately never bundle in:**

- **`incrementalBuild` is never touched by any profile.** It stays exactly
  whatever you set it to. It carries a named, unresolved persistent-sandbox
  contamination risk relative to `reference`'s fresh-sandbox-per-mutant
  behaviour that has not been proven safe the way everything `optimized`
  *does* enable by default has, so it stays a manual, explicit opt-in on
  top of any profile, not a bundled default.
- **`sharedModuleCache` is never touched by any profile either**, on the
  identical basis: its own doc comment names a real, unresolved risk for a
  CI setup that runs multiple concurrent `mutantkit run` destinations
  against one project (the second run's constructor can wipe the first's
  in-flight module cache). `mutantkit execution-profile` still reports
  whether your project's build shape could use it, purely informationally
  — the opt-in itself stays manual: `execution.sharedModuleCache: true`.
- **`measureCoverage` + `selectCoveringTests` are never bundled into
  `optimized`/`experimental` by default.** Coverage data also feeds
  `MutationRunner`'s `.noCoverage` fast path, which can reclassify a real
  surviving mutant on a genuinely uncovered line as `.noCoverage` — excluded
  from `MutationScore.tested`'s denominator — without ever building or testing
  it. Choosing a profile must not change verdicts or the score on its own, so
  this pair requires its own explicit opt-in, off by default:
  `execution.profileCoverageSkip: true`, set deliberately alongside
  `execution.profile: optimized`. `optimized` alone never reaches that fast
  path.

This also means `execution.profile: optimized` is a *different, narrower*
bundle than "Recommended production profile" above — that profile is a
hand-picked, Xcode/simulator-specific tuning (and does include
`incrementalBuild`) from a real large-app benchmark; `execution.profile` is
a general, cross-project mechanism with a stricter, more conservative
safety bar.

Before turning it on, see what it would actually do for your project:

```bash
mutantkit execution-profile --plan plan.json
```

This reads your already-written `plan.json` and prints, for `optimized`:
which of the features above are eligible here (and why, or why not), and
exactly which `execution.*` fields would change from your current config —
never a guess, always the same decision `mutantkit run` itself would make.

## Why `isolated` is the default on Xcode and the iOS Simulator

`execution.strategy: isolated` is the default for every project kind. For Xcode
projects on the iOS Simulator it is a measured choice, not a placeholder. On a
real 100-mutant iOS project `schemata` reached the same outcomes as `isolated`
(100 of 100, no integrity violations) but took 6383 s against 3928 s, which is
62.5% slower, and the gap widened as the corpus grew (27% slower at 14
mutants). Only 32 of the 100 mutants ran on genuine schemata evidence; the other
68 fell back to isolated. Mutants whose selected tests differ cannot share a
batch, so most of them pay a full Xcode and Simulator launch each.

`execution.strategy: schemata` stays a supported, explicit opt-in for advanced
or research use. This says nothing about SwiftPM on macOS, which has its own
cost model (see [schemata support matrix](schemata-support-matrix.md)).

## UI-test targets (`xcodeProject`/`xcodeWorkspace` only)

A `tests.targets` entry does not have to name a unit test target. An
existing XCUITest target/scheme already builds and runs the identical way —
`xcodebuild build-for-testing` / `test-without-building`, evidence read from
the resulting `.xcresult` — so it participates in a mutation campaign the
same way any other test target does: baseline first, then once per mutant,
classified into the same `killedByAssertion` / `killedByCrash` /
`verifiedTimeout` / `survived` / `infrastructureFailure` vocabulary
documented in [Evidence model](evidence-model.md), never a separate one.

This exists specifically as a **validation substrate for Apple-platform
mutation operators whose fault model only exists in a realized UI/
accessibility tree** — a source-level or plain-unit-test check cannot
observe, say, a missing `.accessibilityLabel` or a shrunk tappable area, but
a real, booted Simulator running the app's own XCUITest suite can. It is
not a general UI-testing feature: MutantKit does not provide a UI-automation
DSL, gesture library, or any third-party tool integration (Maestro or
otherwise) — it wires an *existing* UI-test target you already wrote and
already run in Xcode into an *existing* mutation campaign, nothing more.

```yaml
tests:
  targets:
    - MyAppUITests

timeouts:
  mutant:
    strategy: fixed   # a UI test's own baseline duration (Simulator boot +
    maximum: 5m        # app launch + AX-tree settle time) is not a
                        # representative multiplier base for an adaptive
                        # ceiling.
```

Two things worth knowing before pointing this at a real UI-test target:

- **A Simulator that fails to resolve, boot, or verify ready fails the
  whole run before the baseline, not one mutant.** This is not a new
  behavior added for UI tests — `DestinationResolver`/`SimulatorPool`
  already do this for every project kind that leases a Simulator — but it
  is the property that keeps a harness failure from ever being
  misattributed as a mutant-level `survived` or `killedByCrash`.
- **A test selector that matches zero tests is rejected, never read as a
  pass.** `XCResultAdapter.classify` already treats
  `summary.totalTestCount == 0` as `.infrastructureFailure`
  unconditionally. A UI-test target's own
  `-only-testing:` filter (a typo'd test method name, most commonly) is
  exactly as capable of silently narrowing to nothing as a regex-based
  SwiftPM filter is, so double-check the real count in a plain `xcodebuild
  test` run before trusting a mutation campaign's baseline.

A UI test target's own `xcresulttool` bundle node is named `"UI test bundle"`,
not `"Unit test bundle"`. MutantKit recognizes both when it enumerates a target's
tests for `selectCoveringTests`' per-test coverage measurement and for schemata
identifier resolution, so a UI test target is never mistaken for one with zero
tests.
