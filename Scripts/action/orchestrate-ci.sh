#!/usr/bin/env bash
#
# orchestrate-ci.sh — the entire effect of `mode: ci`, once `mutantkit` is
# already on PATH: doctor -> (diff-ref preflight ->) plan -> run -> gate.
#
# Pulled out of action.yml into its own script for two reasons (P13 review,
# item 3): first, action-smoke-test.yml's CI-mode job needs to exercise this
# exact orchestration against a `mutantkit` binary built from the PR HEAD
# under test — installing a *published* release cannot prove a change to
# this orchestration itself works, since the change has not shipped yet.
# Second, action.yml's own YAML is not a place to safely thread multi-line
# conditional shell logic. This script only ever calls the public `mutantkit`
# CLI; it never re-implements planning, scoring, or gate semantics itself
# (see this repo's own design principle: the Action orchestrates, it does
# not recompute a verdict).
#
# `--project-root`/`--output`/`--plan`/`--report`/`--baseline` are always
# passed as explicit, already-absolute paths (computed by action.yml,
# threaded in as env vars below) — never a bare relative path a command's
# own CWD-relative default would resolve inconsistently with the paths
# `.mutantkit/report.html`/`summary.md` are written to (those two are always
# `--project-root`-relative, never CWD-relative; see RunCommand.filename(for:)
# in Sources/CLI/Commands/RunCommand.swift). One path contract, everywhere.
#
# Inputs (environment variables, set by action.yml):
#   PROJECT_ROOT        — absolute path to the project to test.
#   CONFIG_PATH          — absolute path to mutantkit.yml, or "" to let the
#                          CLI locate it under PROJECT_ROOT itself.
#   DIFF_BASE            — a git ref to scope planning to, or "" for a
#                          whole-project plan.
#   PLAN_PATH            — absolute path to write/read plan.json.
#   REPORT_JSON_PATH     — absolute path to write report.json.
#   GATE_RESULT_PATH     — absolute path to write gate's own --json output.
#   BASELINE_REPORT_PATH — absolute path a prior report.json may have been
#                          restored to (see action.yml's cache step). Used as
#                          `gate --baseline` only if the file actually exists
#                          — a cache miss is not an error, it just means
#                          regression checks run without one, same as always.
#
# Exit code: gate's own, once gate has run at all (see the long comment
# above the final `mutantkit gate` call below for why `run` failing does not
# skip it). `doctor`/`plan` failing is fatal to this script directly, since
# there is nothing for `run`/`gate` to do without them.
set -euo pipefail

# PLAN_PATH/REPORT_JSON_PATH/GATE_RESULT_PATH (and the two `.mutantkit/`
# report files run --also-report writes) sit at fixed, project-root-derived
# paths that persist on the runner's disk across invocations of this action
# in the same job. Nothing about a fresh invocation guarantees it reaches
# far enough to overwrite all of them before this script's own failure
# modes can end it early (doctor/plan failing is fatal, above) — without
# this, an invocation that fails before `run` writes a fresh report.json
# would have `gate` read a *previous* invocation's stale one instead of
# correctly finding none at all (P13 review: multi-invocation report
# contamination). Clearing them here, before anything else runs, makes "no
# fresh report this invocation" and "no report on disk at all" the same
# state, which is the state every downstream consumer (gate, the job
# summary, artifact staging) already treats as a structured, fail-closed
# "no verdict" rather than someone else's stale one.
rm -f "$PLAN_PATH" "$REPORT_JSON_PATH" "$GATE_RESULT_PATH"
rm -f "$PROJECT_ROOT/.mutantkit/report.html" "$PROJECT_ROOT/.mutantkit/summary.md"

# This action's own `baseline-applied` output (action.yml) is documented as
# "false" whenever no baseline was applied, including a failure that never
# reaches the point below that decides it (codex review: `set -e` on a
# diff-preflight/doctor/plan failure would otherwise leave the output
# unset, not "false", breaking that contract for a consumer using
# `continue-on-error` to inspect it after a failed invocation). Initialized
# here and written via an EXIT trap, so every exit path — success, a
# deliberate `exit 1` below, or an unexpected failure under `set -e` —
# writes exactly one real value.
baseline_applied=false
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  trap 'echo "baseline-applied=$baseline_applied" >> "$GITHUB_OUTPUT"' EXIT
fi

common_args=(--project-root "$PROJECT_ROOT")
if [ -n "${CONFIG_PATH:-}" ]; then
  common_args+=(--config "$CONFIG_PATH")
fi

"$(dirname "${BASH_SOURCE[0]}")/preflight-capabilities.sh"

if [ -n "${DIFF_BASE:-}" ]; then
  echo "::group::diff-base preflight"
  # A normal `actions/checkout` is a shallow, single-branch clone — `origin/
  # main` (the diff base most consumers will reach for) is not guaranteed to
  # exist in it. Checked here, before `mutantkit plan` ever runs, so a
  # missing ref is one clear, actionable line instead of `mutantkit plan`'s
  # own uncaught `git diff` failure several lines into a less obvious error.
  if ! git -C "$PROJECT_ROOT" rev-parse --verify "${DIFF_BASE}^{commit}" >/dev/null 2>&1; then
    echo "::error::diff base '$DIFF_BASE' is unavailable in this checkout. A shallow 'actions/checkout' does not fetch other branches by default. Fetch the target history first, e.g.:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0
See this repo's README (\"In CI\" -> \"Scoping to a diff\") for a narrower fetch-depth alternative." >&2
    exit 1
  fi
  echo "diff base '$DIFF_BASE' resolves to $(git -C "$PROJECT_ROOT" rev-parse "$DIFF_BASE")."
  echo "::endgroup::"
fi

echo "::group::mutantkit doctor"
mutantkit doctor "${common_args[@]}"
echo "::endgroup::"

echo "::group::mutantkit plan"
plan_args=("${common_args[@]}" --output "$PLAN_PATH")
if [ -n "${DIFF_BASE:-}" ]; then
  plan_args+=(--diff-base "$DIFF_BASE")
fi
mutantkit plan "${plan_args[@]}"
echo "::endgroup::"

echo "::group::mutantkit run"
# `--also-report`, never `--report`: report formats belong to the project's
# own mutantkit.yml (P13 review, item 4) — this Action only guarantees these
# four are *also* produced, on top of whatever the project already
# configured, never in place of it. `json` so `gate`/this script's own
# artifact staging have report.json; `github-actions` for inline
# `::warning::`/`::error::` annotations (printed to this step's own log, per
# GitHubActionsReporter, never written to a file); `html`/`ci-summary` for
# the browsable report and the job-summary step below.
#
# Not fatal on its own: `run` exits non-zero only on an integrity failure
# (MutantKitExit.integrityFailure) or `--fail-on-survivors` (not passed here
# — survivor counts are `gate`'s decision, not `run`'s). Critically,
# RunCommand still *writes* report.json before checking integrity (see
# `emit(...)` ahead of the integrity guard in RunCommand.run()), so a
# trustworthy `gate --json` verdict — "score unavailable, integrity did not
# pass" — is still possible even here, and more informative than stopping
# cold on `run`'s own exit code. `gate` below is what actually decides
# whether that verdict fails the job.
run_exit=0
mutantkit run "${common_args[@]}" --plan "$PLAN_PATH" --output "$REPORT_JSON_PATH" \
  --also-report json --also-report github-actions --also-report html --also-report ci-summary \
  || run_exit=$?
if [ "$run_exit" -ne 0 ]; then
  echo "::warning::mutantkit run exited $run_exit — continuing to \`mutantkit gate\` below, which will report a structured, fail-closed verdict against whatever report.json (if any) was actually produced."
fi
echo "::endgroup::"

echo "::group::mutantkit gate"
gate_args=("${common_args[@]}" --report "$REPORT_JSON_PATH" --json)
# A diff-scoped plan's mutation corpus is a strict subset of the project
# (only mutants touching lines changed against $DIFF_BASE) — its
# tested/effective score has a different denominator than a whole-project
# baseline's, so comparing the two is not apples to apples. Nothing in
# report.json today records enough to *prove* two reports share a comparable
# scope (see P13 review, item 12 — `RunReport.planID` is a content hash of
# the exact source tree + mutation set, so it is equal only for a literal
# re-run, never useful across two different commits); the only scope
# distinction this Action can make honestly is "was --diff-base used at
# all," so a diff-scoped run never applies a baseline, full stop, regardless
# of whether one was restored from cache. If the project's own
# `qualityGate.regression`/`survived.newMaximum` are configured, `gate`
# itself already fails closed on a missing `--baseline` rather than silently
# skipping the check (see this repo's README, "Quality gate" section) — that
# existing contract is what protects a diff-scoped PR run here, not a
# heuristic this script invents.
#
# `baseline_applied` (declared, initialized "false", near the top of this
# script) is flipped to "true" below only when a baseline is actually
# handed to `gate` — the EXIT trap installed there writes whichever value
# this variable holds when the script exits, on every path. Exposed as
# this action's own `baseline-applied` output, distinct from the cache
# action's own `cache-hit`, which only reflects the cache KEY matching, not
# what file `gate` actually received (see action.yml's own comment on this
# output for why that distinction matters).
if [ -n "${DIFF_BASE:-}" ]; then
  if [ -f "${BASELINE_REPORT_PATH:-/nonexistent}" ]; then
    echo "Diff-scoped run (--diff-base $DIFF_BASE): ignoring the restored baseline at $BASELINE_REPORT_PATH — its whole-project scope is not comparable to this run's diff-scoped mutation corpus. If qualityGate.regression is configured, gate will fail closed rather than compare mismatched scopes."
  fi
elif [ -f "${BASELINE_REPORT_PATH:-/nonexistent}" ]; then
  echo "Baseline found at $BASELINE_REPORT_PATH (whole-project run) — regression checks enabled."
  gate_args+=(--baseline "$BASELINE_REPORT_PATH")
  baseline_applied=true
fi
# `tee`, not plain redirection: the verdict stays visible in this step's own
# live log, while also landing on disk at a fixed path the summary/artifact
# steps read without invoking `gate` a second time. `pipefail` (set above)
# means this pipeline's own exit status is `gate`'s, never `tee`'s.
set +e
mutantkit gate "${gate_args[@]}" | tee "$GATE_RESULT_PATH"
gate_exit="${PIPESTATUS[0]}"
set -e
echo "::endgroup::"

exit "$gate_exit"
