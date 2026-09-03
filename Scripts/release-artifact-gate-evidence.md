# `release-artifact-gate.sh` — real confirmation run evidence

A real, complete, passing run of `Scripts/release-artifact-gate.sh 0.0.0-f7-test`
against private main commit `5236b167f9d34b122e70ef7e47a9e84bda94f0d7`,
with the gate script itself at `cd091f8e10a869894682a79b9f401dbba254e6f5`.

Full pipeline: `Scripts/release-build.sh` → SHA256SUMS verification →
extraction to a temp dir outside the repo → package-layout allowlist check →
`--version`/commit-SHA identity check → `manifest.json` shape validation →
per-archive SHA-256 digest + architecture (`lipo`) verification → a real
`mutantkit plan`/`mutantkit run` against a fresh clone of `swift-numerics`
(pinned at `899af71c0256d0ad181e3b7eb3453c1065d928a5`), run from a directory
with no relationship to any `mutantkit`/`mutantkit-private`/`mutantkit-f7`
checkout and with `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` explicitly unset —
proving the extracted binary resolves its schemata runtime purely from what
it bundles, the real end-user path.

## Result

```
==================================================================
== Release artifact gate PASSED
==================================================================
Tarball:       mutantkit-macos-arm64.tar.gz (built fresh, outside the repo)
Version:       0.0.0-f7-test
Commit:        cd091f8e10a869894682a79b9f401dbba254e6f5
Schemata run:  effectiveCount=2 against swift-numerics @ 899af71c0256d0ad181e3b7eb3453c1065d928a5
```

Real mutation run report, from the extracted packaged binary, bundled
runtime only:

```json
{
  "baseline": true,
  "integrity": 0,
  "executionStrategy": {
    "effectiveCount": 2,
    "fallbackCount": 3,
    "fallbackReasonCounts": {},
    "plannerFallbackReasonCounts": {
      "unsupportedOperand": 3
    },
    "requested": "schemata"
  }
}
```

`effectiveCount: 2` — two of the five budgeted mutants actually ran through
the schemata backend, resolved entirely from the bundled runtime archives
(macOS SHA-256 `d6f3ceebae626a40b928f7c22be7ed5a9464dc1158675124113e46a6993fca7c`,
verified against the manifest in Phase 7). The other three fell back to
isolated at *planning* time (`plannerFallbackReasonCounts.unsupportedOperand:
3`) — an expected, correctly-classified planner-level exclusion (an operand
shape the schemata lowerer doesn't cover), not a runtime failure; the report
still baseline-passed with zero integrity violations either way.

Phase 9 (`git status --short` in this checkout) reported "Working tree
clean."

## Note on this confirmation run's own path to green

The first two attempts at this confirmation run were lost to real
system-load contention (a concurrent `release-gate.sh` acceptance-suite run
peaked the machine's load average over 300 on 8 cores) and, separately, one
attempt was killed after a coordination mixup produced several concurrent
invocations writing near-identical log paths. Neither issue reflects on the
script or the artifact itself — once load recovered and only one clean
invocation ran, it passed on the first real, undisturbed try, exactly as
shown above.
