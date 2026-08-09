# ROR schemata vs isolated: formal performance benchmark

Baseline commit: `f2d5006` (ROR schemata scoring enabled in `SchemataLowererRegistry.builtIn`,
no other changes mixed in). Workflow: `oss-public/.github/workflows/relational-schemata-benchmark.yml`.

- Scout run: [31298316910](https://github.com/juntaki/mutantkit/actions/runs/31298316910)
- Formal run: [31308597844](https://github.com/juntaki/mutantkit/actions/runs/31308597844)

## Corpus

| project | source | mutation count |
| --- | --- | --- |
| swift-numerics-integer-utilities | `apple/swift-numerics@899af71` | 83 |
| swift-syntax-small-files | `apple/swift-syntax@60e8eb8` | 33 |

Same MutationPlan reused across isolated/schemata and across all repetitions per project.

## Scout phase (workers 2/3/4, 1 repetition each)

Both modes, both projects: wall-proxy time (build+test seconds) rose monotonically with worker
count -- contention on the shared GitHub-hosted macOS runner, not a parallelism gain. At
workers=4, swift-syntax additionally produced 4 isolated/schemata outcome disagreements out of
33 MutationIDs (`verifiedTimeout`/`flaky` on isolated vs `survived`/`killedByAssertion` on
schemata for the same IDs) -- consistent with runner-side contention causing spurious isolated
timeouts specifically (isolated w4 build time was 2.7x isolated w2's), not a schemata-chain
defect: workers=2 and workers=3 were disagreement-free for the same project. **workers=2**
chosen for the formal run: fastest and disagreement-free for both projects.

## Formal phase (workers=2, 5 repetitions)

### Gate

| gate | result |
| --- | --- |
| disagreement count | **0** (checked matched-repetition pairs and all cross-repetition pairings) |
| missing MutationIDs | 0 |
| duplicate MutationIDs | 0 |
| repetitions complete | 20/20 (2 projects x 2 modes x 5 reps) |
| integrity violations | 0 (verified against raw `report.integrity.violations`, all 20 reports) |
| within-mode flakiness (isolated-vs-isolated, schemata-vs-schemata) | 0 |
| performance improvement > 0 | yes, both projects (not gating -- reported regardless of size per standing instruction) |

All gate conditions pass. This is the first commit at which "ROR schemata is faster than
isolated, with proven zero disagreement" may be claimed.

### Results

| project | mode | wall mean (s) | median | min | max | stdev | mutations/s | effective | fallback |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| swift-numerics-integer-utilities | isolated | 2197.4 | 2232 | 1946 | 2412 | 223.1 | 0.03809 | - | - |
| swift-numerics-integer-utilities | schemata | 2125.0 | 2144 | 1891 | 2435 | 228.3 | 0.03942 | 34 | 49 |
| swift-syntax-small-files | isolated | 3754.0 | 3474 | 2925 | 5284 | 917.2 | 0.00916 | - | - |
| swift-syntax-small-files | schemata | 3449.0 | 3372 | 2976 | 3953 | 376.8 | 0.00966 | 21 | 12 |

Speedup ratio (mean isolated wall / mean schemata wall):

- swift-numerics-integer-utilities: **1.034x** (+3.3%)
- swift-syntax-small-files: **1.088x** (+8.1%)

## Interpretation

Real but modest wall-clock improvement in both corpora, with variance overlapping between modes
at n=5 (schemata stdev ~229s / ~377s). The gain is driven mostly by lower total build time
(schemata's single shared build per chunk vs one build per mutation in isolated mode), partially
offset by comparable test time, and blunted by a large share of mutations still falling back to
isolated execution within the schemata run in both corpora (`fallbackCount > effectiveCount` for
both projects) -- ROR is currently the only non-bool-literal operator with a schemata lowerer, so
every other operator's candidates fall back regardless of mode.

## Reproduction

```bash
gh workflow run relational-schemata-benchmark.yml --ref main \
  -f workersList='[2]' -f repetitions='5'
```

Raw per-job `plan.json`/`report.json`/`benchmark-summary.json` artifacts are retained 30 days on
the workflow run pages linked above.
