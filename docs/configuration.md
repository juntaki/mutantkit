# Configuration reference

Full `mutantkit.yml` field reference. See the [README](../README.md) for a
short example and for how a config is discovered (`setup`/`init` write one
for you). See [Execution](execution.md) for `execution.profile` and the
recommended production tuning, and [Benchmarks](benchmarks.md) for the
measurements behind it.

The example below is a hand-maintained reference showing every field with
its default or a representative value; `Sources/CLI/ConfigurationLoader
.swift`'s own `template(for:)` is the actual generator `setup`/`init` run,
and can drift from this example independently (each is maintained by
hand — there is no test comparing them field-for-field). If a field looks
present in one but not the other, that is worth double-checking against
the source of truth, `Sources/MutationModel/Configuration.swift`, rather
than assuming either document is complete.

```yaml
version: 1

project:
  kind: auto                 # or swiftPackageMacOS | swiftPackageApple | xcodeProject | xcodeWorkspace
  scheme: App
  destination: platform=iOS Simulator,name=iPhone 16

sources:
  include: [Sources/**]
  exclude: ["**/Generated/**", "**/*Mock.swift"]

tests:
  targets: [AppTests]
  # Swift packages only. Off by default: SwiftPM writes the XCTest half of its
  # structured report only when tests run in parallel, so leaving this off costs
  # per-test counts (`inspect` cannot name which test caught a mutant). Outcomes
  # stay correct either way. Turning it on is a real trade: a suite that is not
  # parallel-safe flakes, and a flaky failure during a mutant's run is recorded
  # as that mutant being killed — silently inflating the score. Only enable it if
  # `swift test --parallel` already passes reliably.
  parallel: false

operators:
  profile: default           # conservative | default | experimental

execution:
  strategy: isolated
  # `auto` (half the core count) for a host-only SwiftPM package. For an
  # Xcode project/workspace or an Apple-platform SwiftPM package — anything
  # that leases a real Simulator — `init` writes `2` explicitly instead: see
  # "Recommended production profile" in docs/execution.md for why.
  workers: auto
  budget:
    maxMutants: 50
  # Off by default. When on, a mutant that looks killed is re-run once before
  # the verdict is trusted; if the second run does not fail the same way, it is
  # reported `flaky` and excluded from the score instead of silently inflating
  # it. Doubles the test invocation for every mutant that looks killed, which is
  # the common case in a well-tested project — real cost for a suite you already
  # suspect of flaking under `tests.parallel`.
  retestKilledMutants: false
  # On by default. A mutant whose test run crashes, or times out, is re-run
  # once before the verdict is trusted, the same "prove it reproduces"
  # discipline retestKilledMutants applies to an ordinary failure — a crash
  # or hang is exactly as easy to mistake for a real kill from one
  # observation as an assertion failure is. Real re-run cost on every crash/
  # timeout, same trade-off as retestKilledMutants above.
  confirmCrashKills: true
  confirmTimedOutMutants: true
  # Narrows each mutant's test run to only the tests that cover its mutated
  # line, measured once against the unmutated baseline. A mutant on a line no
  # test reaches is `noCoverage` without ever being built. The single largest
  # speedup available before touching incrementalBuild/simulatorPool below —
  # cached across runs against an unchanged source tree and test suite.
  selectCoveringTests: true
  # Reuses one persistent, incrementally-recompiled sandbox per worker across
  # its mutants instead of a fresh build for each — real Swift incremental
  # compilation savings on a project with more than a handful of mutants.
  incrementalBuild: true
  # Off by default. Routes every isolated-backend SwiftPM sandbox's Clang/
  # Swift module cache (system frameworks only, never project code) to one
  # external directory shared across sandboxes instead of each rebuilding
  # its own — real speedup on cold system-framework compilation, wiped and
  # rebuilt fresh at the start of every process. Not safe to combine with
  # concurrent `mutantkit run`s against the same project on different
  # destinations — see `ExecutionSettings.sharedModuleCache`'s doc comment.
  # sharedModuleCache: true
  # Provisions one real simulator clone per worker (`simctl clone`) so
  # `workers > 1` genuinely parallelizes test execution across distinct
  # devices, instead of every worker serializing on one shared destination.
  # Xcode project/workspace and Apple-platform SwiftPM only — no effect for a
  # host-only macOS package. See "Recommended production profile" in
  # docs/execution.md.
  simulatorPool: true
  # An older way to amortize the fixed simulator install/launch cost: merges
  # several mutants' test runs into one xcodebuild invocation instead of one
  # per mutant. Requires selectCoveringTests and an Xcode project or
  # workspace destination. A real benchmark against a large iOS app (see
  # docs/benchmarks.md) found `simulatorPool: true` with `workers: 2` faster
  # than this at the same scale — kept available since it does not require
  # provisioning extra simulator clones, which some CI runners restrict.
  # Mutually exclusive in practice: `simulatorPool` has no effect once
  # `testBatchSize` is set, since a batch already shares one lane.
  # testBatchSize: 10

timeouts:
  # How long the unmutated baseline (dry-run) may take before it's treated
  # as hung, not merely slow. 10 minutes by default.
  baseline: 10m
  mutant:
    strategy: adaptive      # baseline × multiplier + overheadAllowance
    multiplier: 3
    overheadAllowance: 60s
    minimum: 30s
    maximum: 5m

reports: [console, xcode, stryker-json, html]
```

`overheadAllowance` is additive for a reason. The baseline measures a suite
that *passes*; a mutant that gets killed makes it *fail*, and failing costs
extra fixed time — xcodebuild collects diagnostics and finishes writing the
result bundle. That cost does not shrink with the suite, so on a small suite
a pure multiplier under-budgets exactly the mutants that were about to be
killed, reporting them as `timedOut` and dropping them from the score
entirely. Budget generously: a `timedOut` should mean "this mutant hangs",
not "the limit was tight", because the result cannot tell you which.

Precedence: CLI > project config > environment > defaults, with no
exception for any field, `operators.profile` included: an environment
override is only consulted for a value the project config file left
unset, no matter how it compares to that field's own built-in default.

**An environment override this tool recognizes fails closed if its value
cannot be interpreted.** `MUTANTKIT_WORKERS=abc` or an unrecognized
`MUTANTKIT_OPERATOR_PROFILE` value refuses to run rather than silently
falling back to the config file's or the built-in default — the same
"fail loud, not quiet" contract a malformed `mutantkit.yml` itself
already gets.

## Configuration versioning

`version` (top of the file) identifies the shape of `mutantkit.yml` itself,
separately from the tool's own release version. It defaults to `1` when
omitted, so every config written before this field existed is still valid.

**A version mismatch fails closed.** If a config ever declares a `version`
this build does not recognize, loading it is refused with an error naming
the file, the version found, and the version expected — the run does not
proceed with a guess at what the file meant.

**There is currently no automatic migration between config versions**,
because there has only ever been one: version 1 has not changed shape since
it was introduced, so there is nothing to migrate *to* yet. This is a
deliberate decision, not an oversight — building a migrator ahead of an
actual format change would mean writing conversion logic against a target
that does not exist and cannot be tested against a real old file. If an
incompatible version 2 ever ships, a real migrator (and a documented upgrade
path) will be built at that point, against the actual difference between
the two versions.

`mutantkit migrate --from-muter` (see [Coming from Muter](#coming-from-muter)
below) is unrelated to this: it imports a *Muter* config, which has no
version concept of its own, into a fresh MutantKit config. The file it
writes is stamped with `version: 1` explicitly, and its report says so —
distinguishing a tool-authored file with a known, deliberate version from a
hand-written one that reaches the same default implicitly.

**An unrecognized *key*, at any level, is a different case from an
unrecognized *version* — and is currently ignored, not rejected.** A typo
(`workerz` instead of `workers`, say) or a leftover key from a hand-edited
file decodes silently: the real field falls back to its default, with no
error and no warning from `mutantkit` itself. The JSON Schema this project
publishes (`mutantkit config --schema`) does mark every object
`additionalProperties: false`, so an editor that honors the generated
`# yaml-language-server: $schema=...` hint will flag the same typo — but
that is editor-side linting, not enforcement by the CLI. Renaming or
removing a key *within* `version: 1` (the only precedent so far:
`execution.budget`'s old `sampling`/`stratifyWithinOperatorBy` keys) is
handled case by case with an explicit, named error pointing at the
replacement — not a silent version bump and not silent reinterpretation.

## Coming from Muter

```bash
mutantkit migrate --from-muter muter.conf.yml
```

The importer reports every field it translated, every field it dropped, and
why. It does not silently discard settings it cannot carry.

**MutantKit does not aim for behavioural compatibility with Muter, and will
not reproduce its mutation scores.** MutantKit requires explicit
application/execution evidence before scoring, while Muter uses a different
scoring and evidence model. The resulting scores are therefore not directly
comparable — expect different numbers. That difference is deliberate: see
[What makes this one different](../README.md#what-makes-this-one-different).
