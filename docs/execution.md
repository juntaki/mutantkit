# Execution

How a mutation run actually executes, beyond the bare field reference in
[Configuration](configuration.md). See [Benchmarks](benchmarks.md) for the
real measurements behind the recommendations below, and
[Evidence model](evidence-model.md) for what a verdict actually proves.

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

This is not a guess — see [Benchmarks](benchmarks.md#worker-count-and-simulator-pooling)
for the real numbers behind `workers: 2` + `simulatorPool: true`, and for
why `workers: 4` is a faster but explicitly experimental setting rather
than the default (a real disagreement investigation found it consistent
with resource contention under a full concurrent sweep, not a bug in a
single mutant's replay).

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
  itself, `optimized` is genuinely correctness-neutral — see
  [Benchmarks](benchmarks.md#executionprofile-optimized-correctness-parity)
  for the proof.
- **`experimental`** is `optimized` plus features implemented but not yet
  proven safe for general use. That bucket is honestly empty right now —
  see `ExecutionProfile`'s own doc comment for the one real candidate that
  was looked at and deliberately left out.

**Two things `optimized`/`experimental` deliberately never bundle in, and
one thing they used to that was wrong to:**

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
  `optimized`/`experimental` by default, and this one has a history worth
  knowing.** An earlier revision *did* bundle this pair in, on the
  (incomplete) theory that it degrades safely like everything else — it
  missed that coverage data, once present at all, also feeds
  `MutationRunner`'s `.noCoverage` fast path, which can reclassify a real
  surviving mutant on a genuinely-uncovered line as `.noCoverage` —
  excluded from `MutationScore.tested`'s denominator — without ever
  building or testing it. That is a real, silent verdict and score change
  from choosing a profile alone, found by an adversarial review before it
  shipped. The fix: this pair now requires its own explicit,
  separately-named opt-in, off by default —
  `execution.profileCoverageSkip: true`, set deliberately alongside
  `execution.profile: optimized` — with its own doc comment naming the
  trade-off in full. `optimized` alone never reaches that fast path.

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
                        # ceiling — see the fixed-timeout rationale in
                        # Research/corpus-validation/continuation-resume-removal-2026-09/README.md.
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
  unconditionally — the same guard that would have caught the
  hyphenated-test-target incident in
  [`required-decode-introduction-2026-09`](../Research/corpus-validation/required-decode-introduction-2026-09/README.md)
  had it been an Xcode run instead of a SwiftPM one. A UI-test target's own
  `-only-testing:` filter (a typo'd test method name, most commonly) is
  exactly as capable of silently narrowing to nothing as a regex-based
  SwiftPM filter is, so double-check the real count in a plain `xcodebuild
  test` run before trusting a mutation campaign's baseline.

See `Research/phase5a-ui-test-substrate-2026-09/README.md` for the full
RED/GREEN validation this was built and proven against, including the one
real gap this closed (a UI test target's own `xcresulttool` bundle node is
named `"UI test bundle"`, not `"Unit test bundle"` — a hardcoded check for
the latter alone silently enumerated a UI test target as having zero tests
in `selectCoveringTests`'s per-test coverage measurement and schemata
identifier resolution, even though it genuinely ran).
