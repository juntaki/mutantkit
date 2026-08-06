# MutantBench-Swift

Reproducible comparison of MutantKit and [Muter](https://github.com/muter-mutation-testing/muter)
against the same real-world Swift projects, pinned to the same commit, run under the same
test conditions. The goal is not a single "winner" score — it is a set of independently
reported axes: correctness, coverage of what each tool can even measure, wall time, memory,
disk, and how much manual configuration each tool needs to run at all.

## Status

See `results/summary.json` (`BenchmarkCompletionStatus`) and `results/report.md`
for the current, real status. As of the last committed run: the harness, corpus,
preflight, and Current-toolchain usability evaluation are complete; a
side-by-side performance comparison is not — the Compatibility lane is
`blockedMissingToolchain` (no toolchain on the run's machine could complete a
real mutation run with both tools). This is not a claim that either tool is
faster; it is a recorded compatibility finding.

## Layout

```
Benchmarks/
├── README.md          this file
├── manifest.json       the project corpus — see "Corpus" below
├── expected/           hand-verified expectations for specific mutants (spot checks)
├── scripts/            convenience wrappers around `swift run BenchmarkRunner`
└── results/            raw + aggregate output — results/raw is real run data, not fixtures
```

The Swift source lives at `Sources/BenchmarkRunner/` and its tests at
`Tests/BenchmarkRunnerTests/`. `BenchmarkRunner` never links against MutantKit's own execution
engine (`MutationExecution`, `MutationModel`, etc.) — both MutantKit and Muter are invoked as
plain external processes, on purpose, so the harness measures what a real user experiences from
the command line, not an in-process shortcut unavailable to Muter.

## Corpus

**Every entry is pinned to a real, resolved commit SHA** (via `git ls-remote <repo> HEAD` at
selection time, recorded in `manifest.json` — never a branch or tag alone). Ten projects
selected for this initial pass, all public, permissively licensed (MIT or Apache-2.0), and
maintained with GitHub Actions CI (so `swift build`/`swift test` is known to work in a clean
checkout):

| id | tags this project covers |
| --- | --- |
| `swift-argument-parser` | small SwiftPM + XCTest |
| `swift-numerics` | small SwiftPM + XCTest, heavy generics |
| `swift-collections` | medium SwiftPM + XCTest |
| `swift-async-algorithms` | medium SwiftPM + XCTest, async/await |
| `swift-syntax` | large SwiftPM, 2000+ Swift files, macros |
| `alamofire` | medium SwiftPM + XCTest, async/await |
| `grdb-swift` | large SwiftPM + XCTest, actors, multi-target |
| `swift-composable-architecture` | large SwiftPM, macros, async/await, Swift Testing, SwiftUI result-builder usage, multi-target |
| `swift-dependencies` | small SwiftPM, macros, Swift Testing |
| `hummingbird` | medium SwiftPM, async/await, actors, Swift Testing |

### Known gaps in this first pass

Per the driving directive, project selection does not need to be complete before landing —
these ten were chosen to maximize real-world category coverage without needing a second pass,
and the gaps are recorded here rather than silently left unstated:

- **No `.xcodeproj`/`.xcworkspace` entry yet.** Every project above is SwiftPM. The realistic
  open-source candidates for a clean, buildable, permissively-licensed Xcode-project example
  (app-with-hosted-test-bundle, framework-with-test-bundle, multi-workspace) tend to be either
  much larger apps with CocoaPods/Carthage dependencies (slow, fragile to clone-and-build
  reproducibly) or too small to be representative. Follow-up work should evaluate candidates
  like a small open-source SwiftUI app with a plain `.xcodeproj` (no external dependency
  manager) specifically so `MUTANTKIT_ACCEPTANCE`-style real `xcodebuild` runs stay tractable.
- **`mixed XCTest / Swift Testing` in one target** is not cleanly represented — several
  projects here (`swift-composable-architecture`, `swift-dependencies`, `hummingbird`) use
  Swift Testing, but not deliberately alongside XCTest in the same target. Worth a dedicated
  fixture-style search once the runner itself is proven against the ten above.

Target for a later pass: 20+ projects, filling the gaps above.

## Running

Unit tests (`ProjectMaterializer`/`ResultNormalizer`/`BenchmarkGate`/report generation, all
against fakes — no network, no external tool):

```bash
swift test --filter BenchmarkRunnerTests
```

The real benchmark (clones the corpus, requires both `mutantkit` and `muter` on `PATH`, takes
a long time — large projects in this corpus can each take tens of minutes to build twice per
tool per mode):

```bash
MUTANTKIT_BENCHMARK=1 swift run BenchmarkRunner run --manifest Benchmarks/manifest.json --output Benchmarks/results
```

See `scripts/` for narrower entry points (a single project, a single mode).

## Modes

Every project is measured three ways, at least 3 runs per mode, median (not mean) reported:

- **cold** — no MutantKit cache, no Muter cache, no build artifacts, no derived data.
- **warm** — the tool's own allowed cache populated, build artifacts present, no source changes.
- **incremental** — one production `Source` declaration changed plus its one related test,
  via a fixed, checked-in patch file per project (`Benchmarks/expected/<id>.patch`, added as
  each project's incremental fixture is authored).

## What "not observable by tool" means

Muter has no concept of verifier-proven activation or execution evidence — it does not attempt
to prove a mutant was compiled into the tested binary or that the mutated statement actually
ran. Where MutantKit reports `provenActive`/`provenExecuted`, Muter's corresponding measurement
is recorded as `nil`, never coerced to `0` or to MutantKit's own value. A `nil` in a report
means "this tool does not expose this," not "this tool measured zero."
