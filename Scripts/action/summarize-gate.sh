#!/usr/bin/env bash
#
# summarize-gate.sh — renders $GITHUB_STEP_SUMMARY from mutantkit gate's own
# --json output and (if present) the ci-summary reporter's markdown.
#
# Classifies the JSON's *shape*; never recomputes a verdict from it (P13
# review, item 8 — this repo's own design principle: the Action presents,
# it does not re-judge). `mutantkit gate --json` has two genuinely different
# shapes on disk, and conflating them was a real bug in the P13 prototype,
# which assumed `gate-result.json` was always a QualityGateResult and read
# `.violations[]` unconditionally — which is simply absent on the other
# shape, turning an operational failure into a jq crash that hid the real
# reason `gate` failed:
#   1. QualityGateResult  — {schemaVersion, passed, violations: [...]}
#   2. JSONErrorEnvelope  — {schemaVersion, ok: false, error: {code, message, remedy}}
#      (report missing/malformed — gate never got to a verdict at all)
# This script tells the two apart before reading either one's fields, and
# has an explicit branch for "neither" (malformed JSON, or gate never ran)
# rather than letting an unrecognized shape crash it.
#
# This step's own exit code is always 0: writing an accurate summary must
# never additionally fail the job on top of whatever orchestrate-ci.sh's own
# `mutantkit gate` exit code (still the job's authoritative verdict) already
# decided.
#
# Usage: summarize-gate.sh <gate-result.json> [summary.md]
# Requires: jq (preinstalled on GitHub-hosted runners), $GITHUB_STEP_SUMMARY set.
set -euo pipefail

gate_result="${1:?usage: summarize-gate.sh <gate-result.json> [summary.md]}"
summary_md="${2:-}"
step_summary="${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is not set}"

if [ ! -s "$gate_result" ]; then
  {
    echo "## :warning: Mutation quality gate did not produce a result"
    echo
    echo "No \`gate-result.json\` was found or it was empty. An earlier step (doctor/plan/run) likely failed before \`mutantkit gate\` could run — see that step's own log above."
  } >> "$step_summary"
elif ! jq -e . "$gate_result" >/dev/null 2>&1; then
  {
    echo "## :warning: Mutation quality gate produced unreadable output"
    echo
    echo '```'
    cat "$gate_result"
    echo '```'
  } >> "$step_summary"
elif jq -e '(.schemaVersion? != null) and (.ok? == false) and (.error? != null)' "$gate_result" >/dev/null 2>&1; then
  code="$(jq -r '.error.code' "$gate_result")"
  message="$(jq -r '.error.message' "$gate_result")"
  remedy="$(jq -r '.error.remedy // empty' "$gate_result")"
  {
    echo "## :warning: Mutation quality gate could not run (operational failure)"
    echo
    echo "- **code**: \`$code\`"
    echo "- **message**: $message"
    if [ -n "$remedy" ]; then
      echo "- **remedy**: $remedy"
    fi
  } >> "$step_summary"
elif jq -e '(.schemaVersion? != null) and (.passed? == true) and (.violations? != null)' "$gate_result" >/dev/null 2>&1; then
  echo "## :white_check_mark: Mutation quality gate passed" >> "$step_summary"
elif jq -e '(.schemaVersion? != null) and (.passed? == false) and (.violations? != null)' "$gate_result" >/dev/null 2>&1; then
  {
    echo "## :x: Mutation quality gate failed"
    echo
    jq -r '.violations[] | "- **\(.kind)**: \(.detail)"' "$gate_result"
  } >> "$step_summary"
else
  {
    echo "## :warning: Mutation quality gate produced an unrecognized result shape"
    echo
    echo '```json'
    cat "$gate_result"
    echo '```'
  } >> "$step_summary"
fi

echo >> "$step_summary"
if [ -n "$summary_md" ] && [ -s "$summary_md" ]; then
  cat "$summary_md" >> "$step_summary"
fi
