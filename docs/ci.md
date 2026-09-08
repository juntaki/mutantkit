# CI reference

See the [README](../README.md#ci) for the quick-start snippets (bundled
GitHub Action, manual recipe). This page covers everything below that:
Action inputs, version pinning, diff scoping, the baseline mechanism, run
profiles, and how to read the result.

## Action inputs

Beyond `mode`/`version`/`diff`:

| Input | Default | Notes |
| --- | --- | --- |
| `project-root` | `.` | Path to the project to test, for a monorepo or a checkout where MutantKit's project is not at the workspace root. Every `mode: ci` step (doctor/plan/run/gate, report paths, baseline cache, artifact staging) resolves this to one absolute path and is consistent about it. |
| `config` | *(auto)* | Path to `mutantkit.yml`, if not at `<project-root>/mutantkit.yml`. Relative paths resolve against `project-root`. |
| `artifact-name` | `mutantkit-report` | Give each invocation a unique name if a matrix, multiple jobs, or multiple invocations of this action run in the same workflow run — `actions/upload-artifact` errors on a name collision within one run. |
| `baseline-scope` | *(empty)* | Extra text folded into the baseline cache key, on top of `project-root` and the target branch (already part of the key). Set this when one workflow run drives the action more than once for what would otherwise be an identical `project-root`/branch pair (e.g. a matrix dimension), so each invocation gets its own baseline. |
| `attestation-token` | *(this job's own token)* | Only used to call `gh attestation verify` against MutantKit's own public build-provenance attestations — raises the API rate limit; not "authorization" to install anything. |

## Version pinning

An explicit `version:` always wins. Otherwise, pinning the action itself to a
release tag also pins the binary — `uses: juntaki/mutantkit@v0.2.0` installs
`v0.2.0`, no separate `version:` needed. Only a ref that is not itself a
release tag (`uses: juntaki/mutantkit@main`, or a local `uses: ./` checkout
of this repo) falls back to the floating `latest` GitHub Release, and says
so with a visible `::warning::` in the log — that is the one case where the
installed binary can change between two runs of an otherwise-unmodified
workflow.

## Scoping to a diff

`diff: origin/main` needs that ref to actually be fetched — a plain
`actions/checkout@v4` is a shallow, current-branch-only clone. Either
`fetch-depth: 0` or a narrower fetch (`git fetch origin
main:refs/remotes/origin/main` with `fetch-depth: 1`) works; the action
verifies the ref resolves before planning and fails immediately with an
actionable message if it does not, rather than fetching one on your behalf
or letting `mutantkit plan` fail confusingly several lines later. A
diff-scoped run never applies a baseline for gate's regression checks (see
below) — the project's own `mutantkit.yml` still owns thresholds and report
formats.

## Baseline

On a non-`pull_request` run with no `diff:` set, a passing run's
`report.json` is cached (`actions/cache`) and restored on the next run
targeting the same branch/`project-root`/`baseline-scope`, so
`qualityGate.regression`/`survived.newMaximum` have something to compare
against. A diff-scoped mutation corpus is a strict subset of a whole-project
one — its score has a different denominator — so a diff-scoped run never
applies a restored baseline, cached or not; if `regression`/`survived` are
configured, `gate` fails closed on the missing baseline rather than
comparing mismatched scopes (see [Quality gate](../README.md#quality-gate-turning-a-score-into-a-merge-decision)).
A `pull_request` run never writes a new baseline, so a PR cannot mutate the
target branch's own baseline before merging. A same-commit workflow rerun
reuses its own already-saved baseline rather than erroring on a cache-key
collision.

## Reading the result

The action's own exit code is `mutantkit gate`'s — `0` (passed), `1`
(operational error: doctor/plan/run could not proceed, or `gate` itself
could not read a report), `2` (integrity failure: the run completed but its
invariants did not reconcile, so no score exists to gate), or `4` (a trusted
report missed a configured threshold). The job summary ($GITHUB_STEP_SUMMARY)
reports which case occurred without recomputing the verdict itself, and the
artifact (`report.json`, `gate-result.json`, `report.html`, `summary.md`) is
uploaded regardless of which one it was — a failing or inconclusive gate is
exactly when you want the evidence.

**Requires** the same macOS arm64 Apple Silicon runner (e.g. `macos-14`,
`macos-15`) as every other use of this binary.

## Manual CI recipe, in full

The bundled Action is a thin wrapper around this — useful directly for a CI
system other than GitHub Actions, or for a shape (sharding, a custom report
pipeline) the Action does not cover:

```bash
mutantkit plan --output plan.json
mutantkit shard plan.json --count 8       # deterministic: a mutant always lands in the same shard
mutantkit run --plan plan.3.json --output results.3.json --no-history
mutantkit merge results/*.json
```

Plans are machine-independent JSON and every mutant checkpoints on
completion, so an interrupted run resumes rather than restarting.

`--no-history` on each sharded `run` matters: a shard's score is a partial
slice of the project, not the whole thing, and `mutantkit history` is meant
to show whole-project results. `mutantkit merge` records the real, combined
score itself, so this is the one command in the recipe above that needs no
flag to do the right thing.

On GitHub Actions specifically, add `github-actions` to `reports:` (or
`--report github-actions`) and surviving mutants show up as inline
annotations on the pull request's "Files changed" tab, no extra plumbing
required — `mutantkit run` prints the `::warning::`/`::error::` workflow
commands GitHub's own runner parses directly to its stdout, the same way it
already prints Xcode-format warnings for a local build.

## Run profiles

Run profiles follow what large-scale practice has settled on — surface a
few actionable mutants in review rather than a full report nobody reads:

| Profile   | Scope                              | Operators             |
| --------- | ----------------------------------- | --------------------- |
| PR        | changed declarations, under budget | high confidence only  |
| Nightly   | affected modules                   | default               |
| Weekly    | whole project                      | including experimental |

Diff-scoped PR runs do not replace full runs: mutants relevant to a change
routinely live outside the changed lines, which is what nightly and weekly
are for.
