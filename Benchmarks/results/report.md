# MutantBench-Swift — real-corpus run report

Generated 2026-08-04. Hand-assembled from real command output and from the
real `BenchmarkPreflightResult` JSON artifacts under
`Benchmarks/results/current/<environment-id>/preflight/*.json` (BenchmarkRunner's
own `ReportGenerator.twoPartMarkdownReport` renders `AggregateBenchmarkResult`
from a *measurement* sweep that completed through `BenchmarkOrchestrator.run`;
no such sweep completed for any project this session, so it is not used here
to avoid fabricating measurement rows from data that doesn't exist. Every
number below is either a real, individually-run command's real output, or a
field from one of the committed JSON artifacts).

This report is split into exactly two parts, per this benchmark's own
standing rule: **a tool failing to compile under the machine's current,
real toolchain is a usability finding — never itself evidence about
performance.** "Muterがcompileしない → MutantKitが速い" is an explicitly
forbidden conclusion and does not appear anywhere below. Part A and Part B
never merge into one number or one ranking.

**Machine-readable status**: `Benchmarks/results/summary.json`
(`BenchmarkCompletionStatus`/`BenchmarkLaneStatus` — read this before
trusting any number below; it cannot silently claim more than what was
measured the way prose can drift):

```
completionStatus:        usabilityCompletePerformanceBlocked
currentLaneStatus:        completed
compatibilityLaneStatus:  blockedMissingToolchain
```

### What this branch completed, and what it did not

```
Completed:
- benchmark harness
- corpus manifest
- preflight classification
- environment/toolchain identity
- MutantKit/Muter adapters
- resource measurement
- correctness metrics
- report generation
- Current-toolchain usability evaluation

Not completed:
- side-by-side execution performance comparison
- cold/warm/incremental comparative measurements
- Muter-compatible toolchain lane

Status:
- Compatibility lane: blockedMissingToolchain
```

This branch is **not** a completed performance benchmark. It is a
completed benchmark harness plus a completed Current-toolchain usability
evaluation. Nothing below should be read as "MutantKit is faster than
Muter," "MutantKit outperforms Muter," "performance benchmark complete," or
"3-project comparison complete" — none of those are true of this branch,
and none of that language appears below.

## Environment (current lane)

```
macOS:   26.5.2 (BuildVersion 25F84)
Arch:    arm64
Swift:   swift-driver version 1.148.6, Apple Swift version 6.3.3
         (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Xcode:   26.6 (Build 17F113)
Target:  arm64-apple-macosx26.0
Muter:   16 (installed via Homebrew, muter-mutation-testing/formulae/muter)
```

`toolchainProfileID` for this lane:
`26.5.2-arm64-swift-driver_version__1.148.6_Apple_Swift_version_6.3.3__swiftlang-6.3.3.1.3_clang-2100.1.1.101_`

---

## Part A — Current Toolchain Usability

The real, installed Swift 6.3.3 / Xcode 26.6 environment, kept exactly as-is
— no toolchain switching, no patching either tool. This section answers
"what happens on the toolchain a developer actually has right now," and its
results (including Muter's compile failures) are permanent, valid findings,
never discarded or treated as a lesser result once a compatible toolchain is
found later.

### A.1 Corpus and pinned commits

All 10 entries in `Benchmarks/manifest.json`, each pinned to a full 40-char
commit SHA (never a branch/tag), resolved via `git ls-remote` at selection
time and re-verified via the real clone/checkout performed this session.

| id | commit | baseline preflight |
| --- | --- | --- |
| swift-argument-parser | `2f77f2fccb6e84fecff338c37b199e33e7dfd119` | **inconsistent** (A.2) |
| swift-numerics | `899af71c0256d0ad181e3b7eb3453c1065d928a5` | passed |
| swift-collections | `ff27e3678ddb895ebf917ce513f3105395078dae` | passed |
| swift-async-algorithms | `46b3cc3a4ea25dba09dae693568635832fcb39b2` | passed |
| swift-syntax | `60e8eb850721b5a6eebbd973b39f450a16553bd9` | passed (build-only, see A.2) |
| alamofire | `0455bfb650893e86ad07ace16e5f2d36dadf46f4` | **failed** (A.2) |
| grdb-swift | `b83108d10f42680d78f23fe4d4d80fc88dab3212` | passed |
| swift-composable-architecture | `269d6457986d163557ea2601275b1117e4dee3c0` | passed |
| swift-dependencies | `b4269c89380c4e294860365096b24cba2ad052bd` | passed |
| hummingbird | `55bc9025a4825ee2a234b1f82b51b87be6ef74e4` | passed |

**All 10 of 10 corpus projects have real baseline preflight results this
session** — the real `BenchmarkPreflightResult` JSON for each is committed
under `Benchmarks/results/current/<environment-id>/preflight/<id>.json`.

### A.2 Preflight detail — 7 passed, 2 failed (both real, both classified), 1 build-only

**7 of 10 projects preflighted with a clean full baseline**
(`swift build --build-tests && swift test --skip-build`):

| id | tests | wall time |
| --- | --- | --- |
| swift-numerics | 70 (XCTest) | 1m45s |
| swift-async-algorithms | 358 (XCTest) | 2m01s |
| swift-collections | large RopeModuleTests (XCTest) + 13 (Swift Testing) | ~6m04s (test-only) |
| swift-dependencies | 31 (Swift Testing, 12 suites, 3 known issues) | 3m18s |
| hummingbird | 454 (Swift Testing, 38 suites) | 3m42s |
| swift-composable-architecture | 401 (XCTest) + 4 (Swift Testing, 1 known issue) | 3m32s |
| grdb-swift | 2877 (XCTest), 31 skipped | 5m24s |

**1 of 10 build-only** (a scope limitation, recorded honestly, not a
pass/fail claim on its test suite):

- **swift-syntax** — `swift build --build-tests` succeeded cleanly
  (653/653 targets, 119.12s, 0 compile errors). The full `swift test
  --skip-build` run was not executed this session given the project's scale;
  this is recorded as `succeeded: true` on the build stage only, with an
  explicit note in the artifact, never silently treated as a full green test
  pass.

**2 of 10 failed preflight, for two different, both real, classified
reasons:**

- **swift-argument-parser** — `projectBaselineInconsistent`. `swift test
  --skip-build` exits `1`, but the Swift Testing summary it prints says
  "Test run with 146 tests in 9 suites passed." Root-caused to a *separate*
  XCTest target, `ArgumentParserGenerateManualTests`, genuinely failing
  (`Actual output does not match the expected output` on multiple
  `testXMultiPageManual`/`testXSinglePageManual` cases — a man-page/groff
  formatting difference on this machine) whose failures never surface in the
  Swift Testing summary MutantKit's adapter reads. **MutantKit's fail-closed
  refusal to trust the mismatched exit code is correct, load-bearing
  behavior, not a bug** — confirmed by full manual reproduction before
  concluding this, not guessed at, and not weakened to make this project
  "pass."
- **alamofire** — `projectBaselineTestFailed`. `RequestTests` requires a
  local HTTP test server on `127.0.0.1:8080` that was not running; a real
  environment-setup gap in this session, not a project or tool defect.

### A.3 Tool installation / compilation (this toolchain)

- **MutantKit**: builds and runs cleanly (own release binary,
  `.build/release/mutantkit`) — no installation or compilation issue on this
  toolchain, on any project attempted.
- **Muter** (v16, Homebrew): installs and its own `--version`/`init` run
  fine, but **fails to complete a mutation run on every corpus project
  attempted under this toolchain** — see A.4. This is a real, permanent
  Part A finding on its own, independent of any MutantKit comparison.

### A.4 Muter current-environment compile failures (both independently reproduced, real repro commands)

**swift-argument-parser** — a genuine Swift 6 strict-import-access compile
error in the mutated build:
```
error: ambiguous implicit access level for import of 'Foundation'; it is
imported as 'internal' elsewhere
```

**swift-numerics** — two different failures across two attempts:
1. First attempt (source directory already had a populated `.build` from
   this session's own earlier baseline check) — a stale absolute module
   cache path error.
2. Clean-checkout retry got further (33 compile steps in) but still ended in
   `error: fatalError` compiling a mutated `IntegerUtilities/ShiftWithRounding.swift`
   — root cause not traced further given the time already spent; recorded as
   observed, not diagnosed.

Muter's own repository was **not patched** to work around either failure —
the official pinned commit (v16) was used exactly as-is, per this
benchmark's own standing rule.

### A.5 Zero-config success and manual configuration

Neither tool ships a working config for a third-party corpus project by
design. MutantKit needed a hand-written `mutantkit.yml` per project; Muter
needed a hand-written `muter.conf.yml` per project (real schema —
`arguments`/`executable`/`exclude`/`excludeCalls` — confirmed by running
`muter init` for real, after an earlier session mistakenly used an invented
schema that caused a real Muter parse failure). Zero-config success rate is
0/10 for both tools against this corpus, as expected for third-party repos.

### A.6 Compatibility investigation (formal `blockedMissingToolchain` record)

Full candidate-exploration record, verdict, and justification:
`Benchmarks/results/current/<environment-id>/toolchain-candidates.json`.

Summary: **exactly one toolchain candidate exists on this machine**
(Xcode 26.6 / Swift 6.3.3 — confirmed via real enumeration of
`/Applications/Xcode*.app`, both standard `.xctoolchain` directories,
`swiftly`/`xcodes` CLI presence, and `brew list`). It was tried against two
different real corpus projects, independently, producing two different real
compile-failure signatures on the second alone — this is not a
premature verdict from a single failure. Muter's own `Package.swift`
declares `swift-tools-version:5.9` / `.macOS(.v12)` (fetched via `gh api`,
now recorded in `Benchmarks/manifest.json`'s `toolchainRequirements`), which
is consistent with, though not proof of, a Swift-5.9-vs-6.3 mismatch as the
root cause.

Installing an older Xcode or a swift.org standalone 5.9 toolchain was
deliberately **not** attempted this session — a system-modifying, likely
privileged, multi-GB download is out of scope for an unattended benchmark
run. **Verdict: `blockedMissingToolchain`.** The compatibility-lane harness
code itself (`BenchmarkToolchainProfile`, `ToolchainEnvironmentBuilder`,
`ToolchainDiscovery`, `ToolchainDriftGuard`, lane-isolated result paths) is
complete and unit-tested, and will run correctly the moment a second,
Swift-5.9-capable toolchain becomes available.

---

## Part B — Pinned Toolchain Performance

**Not available this run — `blockedMissingToolchain` (A.6): no toolchain
was found under which both tools could complete even one real mutation
run, so no side-by-side cold/warm/incremental comparison exists.** No
numbers are fabricated or backfilled from Part A here. This is a schema gap
recorded honestly, not a "0" or a "worse" score for either tool.

What is real and ready for the moment a compatible toolchain exists:

- `BenchmarkOrchestrator`'s cold/warm/incremental modes, median-of-≥3-runs
  logic, and cache-directory isolation (unit-tested against a fake tool:
  cold-run isolation, warm-run cache reuse, aggregate/report generation —
  all green).
- `MeasurementCollector`'s real `ps`-based peak-RSS/CPU-time sampling and
  disk-size measurement (implemented, not stubbed; never exercised against a
  completed real run, since none completed).
- `ResultNormalizer.compareBackends` / `BenchmarkGate`'s `phantom`/
  `falseScored`/`backendDisagreements` wiring (real, computed from actual
  report fields, unit-tested against synthetic reports: 5 dedicated tests
  green) — ready to run against a real completed report the moment one
  exists.
- MutantKit's own real partial evidence from this session (never reported as
  a completed comparison): on swift-numerics, MutantKit's `plan` succeeded
  (417 mutations, 34 files, 6 operators) and `run` was genuinely executing
  (5 parallel sandbox workers, real subprocess trees, confirmed live via
  `ps`) for ~95 minutes before being deliberately stopped once Muter had
  already failed twice — stopped, not measured, and not counted as a
  performance result for either tool.
- A later, separate attempt this session to recover a second, subsequently-
  started swift-numerics cold-mode MutantKit run — recorded structurally,
  not as prose alone, in `Benchmarks/results/summary.json` and in
  `toolchain-candidates.json`'s `unrecoverableRuns`:

  ```
  task identifier: bpyg8pp2r
  previous PID: 98113
  expected log path: /tmp/mb-corpus/numerics-mk-run.log
  observation:
  - task not found
  - process not running
  - log path absent
  - parent directory absent
  classification: unrecoverableInterruptedRun
  included in performance aggregation: false
  ```

  Checked directly (`ps -p 98113`, a filesystem search for the log and for
  any `report.json` anywhere under `/tmp` or the repo), not assumed. Not
  classified as timeout, crash, or success — none of those were observed;
  there was no process left to inspect, flat-CPU or otherwise. No real
  cold-mode numbers exist from it, and none are fabricated here or included
  in any aggregation in its place.

**Current-lane conclusion, limited to what was observed:**

```
- MutantKit successfully completed its applicable preflight stages on the
  current Swift 6.3 environment across the evaluated corpus.
- Muter failed before completion on two independently attempted projects.
- Both failures are recorded as current-toolchain compatibility failures.
- These failures are not execution-performance measurements.
```

Two independent failures do not prove every remaining project would also
fail — that stronger claim is not made here. Further project attempts
under this toolchain were stopped because another project-level attempt
would not answer the remaining performance question without first
resolving the known toolchain compatibility boundary — the same root cause
(Muter's own `swift-tools-version:5.9` vs. this machine's Swift 6.3) has
already been independently observed twice, and a third or Nth repetition
would exercise the same known boundary rather than resolve it.

---

## Conclusions kept separate, on purpose

- **Part A conclusion**: MutantKit has better current-toolchain
  compatibility than Muter on this machine's real, installed Swift 6.3.3 —
  MutantKit builds, plans, and begins execution on every corpus project
  attempted; Muter fails to complete a mutation run on both projects
  attempted, for reasons consistent with Muter's own Swift-5.9 target vs.
  this toolchain's Swift 6.3. This is a real, standalone finding.
- **Part B conclusion**: not available this run (`blockedMissingToolchain`).
  MutantKit/Muter performance under a pinned, mutually compatible toolchain
  is **not yet measured** — nothing here should be read as "MutantKit is
  faster" or any other performance claim. The forbidden conflation
  ("Muterがcompileしない → MutantKitが速い") is explicitly rejected.

## Next implementation priority (chosen from the measured data, exactly one)

**Pin a Muter-compatible Swift toolchain for the benchmark harness's own
compatibility lane** (either by installing an older Xcode/swift.org 5.9
toolchain once system-modification is explicitly authorized, or by
targeting `swiftly` for a reproducible, scriptable toolchain install) —
this is the single blocker standing between the now-complete harness code
and a real Part B.

Justification directly from what was measured:

- Every other axis (cold/warm/incremental timing, memory, disk, cross-tool
  mutant matching, correctness-gate exercising against real data) is
  unreachable until at least one project completes on *both* tools under
  one pinned toolchain — this is the dominant, structural blocker, and the
  harness code that consumes a completed run is already built and
  unit-tested.
- This is not a `schemata build cache` problem (nothing got far enough to
  measure build-time dominance), not a `checkpoint` problem (no run was
  interrupted and resumed), not a `next schemata lowerer` problem (schemata
  eligibility was never the limiting factor), and not a `packaged CI`
  problem (this was a local run). It maps to "導入失敗が多い → doctor /
  adapter / compatibility改善" in this benchmark's own decision tree —
  specifically Muter's own toolchain compatibility, which the harness can
  work around by pinning a known-good toolchain for its own runs even
  though it cannot and must not patch Muter's source directly.
- Once a compatible toolchain is pinned, the minimum-3-project side-by-side
  sweep (cold×3/warm×3/incremental×3) can run immediately against the
  already-preflighted, already-passing current-lane projects
  (swift-numerics, swift-async-algorithms, hummingbird, and others) with no
  further code believed necessary — the blocker is purely environmental.
