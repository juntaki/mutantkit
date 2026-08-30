#!/usr/bin/env bash
#
# stage-artifacts.sh — copies exactly the known, named report files into a
# flat, non-hidden staging directory for actions/upload-artifact.
#
# Why this exists (P13 review, item 9): two of the four files this Action
# produces (.mutantkit/report.html, .mutantkit/summary.md) live under a
# dotdir. `actions/upload-artifact@v4` does not upload hidden files/
# directories unless told to, and the fix is deliberately *not* "tell it
# to" (`.mutantkit/**` or `.` would upload whatever else a project has
# accumulated under `.mutantkit/` — run-locks, checkpoints, sandboxes,
# coverage caches — none of which belong in a build artifact). Copying only
# these four known files into a plain directory is the narrow alternative:
# upload-artifact needs no hidden-file flag because nothing here is hidden,
# and nothing beyond these four files can ever end up in the artifact.
#
# Usage: stage-artifacts.sh <project-root> <report.json> <gate-result.json> <staging-dir>
set -euo pipefail

project_root="${1:?usage: stage-artifacts.sh <project-root> <report.json> <gate-result.json> <staging-dir>}"
report_json="${2:?usage: stage-artifacts.sh <project-root> <report.json> <gate-result.json> <staging-dir>}"
gate_result="${3:?usage: stage-artifacts.sh <project-root> <report.json> <gate-result.json> <staging-dir>}"
staging="${4:?usage: stage-artifacts.sh <project-root> <report.json> <gate-result.json> <staging-dir>}"

# This directory is a fixed path under `runner.temp`, reused by every
# invocation of the action in the same job — `mkdir -p` alone leaves an
# earlier invocation's own staged files sitting here. Left uncleared, a
# later invocation that legitimately has fewer of the four files this run
# (e.g. it failed before producing report.json) would silently upload the
# earlier invocation's stale copy instead of correctly having none (P13
# review: multi-invocation artifact contamination).
rm -rf "$staging"
mkdir -p "$staging"

copy_if_present() {
  local src="$1" dest_name="$2"
  if [ -f "$src" ]; then
    cp "$src" "$staging/$dest_name"
    echo "Staged $dest_name"
  else
    echo "Not staging $dest_name — $src does not exist (an earlier step likely did not reach it)."
  fi
}

copy_if_present "$report_json" "report.json"
copy_if_present "$gate_result" "gate-result.json"
copy_if_present "$project_root/.mutantkit/report.html" "report.html"
copy_if_present "$project_root/.mutantkit/summary.md" "summary.md"
