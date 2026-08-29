#!/usr/bin/env bash
#
# preflight-capabilities.sh — refuses to start a mutation campaign against a
# `mutantkit` build that predates the CLI surface `mode: ci` depends on.
#
# Why this exists (P13 review, item 3): the latest published release at the
# time this Action was written (v0.2.0) has no `gate --json` at all — it was
# added by the same CLI work this Action's CI mode depends on. Without this
# check, `with: { mode: ci }` against `version: latest` (or any pre-P13 pin)
# would run doctor/plan/run all the way through — paying for a full mutation
# campaign — before failing confusingly on the first flag `gate`/`run` does
# not recognize. Checked via `--help` output, not by trying and parsing a
# failure: cheap (no report needed, no mutation run), and safe (never invokes
# a code path this script cannot control the input to).
#
# Usage: preflight-capabilities.sh
# Requires: `mutantkit` on PATH.
set -euo pipefail

missing=()

if ! mutantkit gate --help 2>/dev/null | grep -q -- '--json'; then
  missing+=("mutantkit gate --json (structured quality-gate output)")
fi

if ! mutantkit run --help 2>/dev/null | grep -q -- '--also-report'; then
  missing+=("mutantkit run --also-report (additive report formats)")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::This Action's CI mode (mode: ci) requires a mutantkit build that supports:" >&2
  for capability in "${missing[@]}"; do
    echo "::error::  - $capability" >&2
  done
  installed="$(mutantkit --version | head -n1)"
  echo "::error::The resolved build ('$installed') does not. Pin \`with: version:\` to a release that includes these, or use \`mode: install\` alone if you only need the binary on PATH." >&2
  exit 1
fi

echo "CLI capability preflight: gate --json and run --also-report are both supported."
