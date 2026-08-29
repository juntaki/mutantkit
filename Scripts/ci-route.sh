#!/usr/bin/env bash
# Decides, once per push/PR event, whether a CI run gets the full acceptance
# matrix or a narrower, path-targeted slice of it. Extracted out of the
# `route` job's own inline `run:` block in .github/workflows/ci.yml so this
# trust-critical decision (it decides which correctness tests get *skipped*,
# not just an optimization) can be unit-tested like any other classifier --
# see Tests/MutantKitTests/Unit/CIRouteClassificationTests.swift.
#
# Usage:
#   ci-route.sh <event-name> [labels-json]
# Changed file paths (one per line, relative to the repo root, exactly the
# shape `git diff --name-only` produces) are read from stdin. Only consulted
# for `pull_request`; ignored for every other event.
#
#   <event-name>   github.event_name verbatim: push | pull_request |
#                  workflow_dispatch | anything else.
#   [labels-json]  github.event.pull_request.labels.*.name run through
#                  toJSON -- a JSON array of label name strings, e.g.
#                  '["ci:full","enhancement"]'. Defaults to '[]'. Only
#                  consulted for `pull_request`.
#
# Emits one line of JSON on stdout:
#   {
#     "run_full": true|false,
#     "run_schemata_targeted": true|false,
#     "selected_fixtures": ["fixture-a", "fixture-b", ...],
#     "acceptance_matrix": {"include": [{"fixture": ..., "filter": ..., "simulator": ..., ["wave": ...]}, ...]},
#     "reason": "human-readable explanation"
#   }
#
# `acceptance_matrix` is a real, already-filtered GitHub Actions matrix
# object -- `run_full=true` means it contains every fixture from
# Scripts/ci-fixtures.json (the single source of truth for the full fixture
# list, read by this script both for that full case and to look up the
# filter/simulator/wave fields of a targeted selection); otherwise it
# contains only the entries whose `fixture` name appears in
# `selected_fixtures`. The `route` job's workflow step feeds this straight
# into the `acceptance` job's `strategy.matrix: ${{ fromJSON(...) }}` -- see
# ci.yml's own comment there -- so an unselected fixture never creates a
# runner job at all, rather than creating one whose steps are merely
# skipped.
#
# Every branch that is not a deliberate "run everything" signal (push to
# main, workflow_dispatch, an override label, the trust-critical path group)
# still checks for changed paths outside every known targeted group, and
# fails toward run_full=true if it finds any -- this project's own
# established "unknown -> run" CI-safe-skip principle (see
# Scripts/assert-tests-ran.sh's own doc comment for the same stance applied
# to a filter matching zero tests). A classifier's job here is never to make
# a false skip look like a pass.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::ci-route.sh requires jq, which was not found on PATH" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures_file="$script_dir/ci-fixtures.json"
if [ ! -f "$fixtures_file" ]; then
  echo "::error::ci-route.sh requires $fixtures_file (the fixture source of truth), which was not found" >&2
  exit 1
fi

event_name="${1:?usage: ci-route.sh <event-name> [labels-json] < changed-files}"
labels_json="${2:-[]}"

changed_files="$(cat)"

run_full="false"
schemata_targeted="false"
declare -a fixtures=()
reason=""

# --- Targeted acceptance groups -------------------------------------------
#
# trust-critical: the core execution/verdict/toolchain-probe machinery, plus
# the four CLI commands (`run`, `gate`, `plan`, `verify`) that are the
# connection point into it -- cache, checkpoint, execution-orchestration,
# verdict, and integrity all meet here. No shortcut for this group: any touch
# runs the full acceptance matrix, same as an unrecognized path.
# RunCommand.swift/GateCommand.swift/PlanCommand.swift/VerifyCommand.swift are
# listed explicitly rather than relying on the (deliberately broader, and
# therefore too coarse for *this* purpose) cli-commands prefix below -- see
# cli_commands's own comment for why that prefix cannot be trusted to route
# these files correctly on its own. PlanCommand/VerifyCommand specifically:
# the C0 correctness fix landed real defects in exactly these two files
# (PlanCommand writing a plan from an unproven toolchain identity;
# VerifyCommand reporting a false "match" from incomplete evidence) --
# a future regression in either belongs behind the full matrix, not a
# same-file-prefix-only acceptance slice.
trust_critical='^Sources/MutationExecution/|^Sources/CLI/RunContextProbe\.swift$|^Sources/CLI/ToolchainProbe\.swift$|^Sources/CLI/Commands/RunCommand\.swift$|^Sources/CLI/Commands/GateCommand\.swift$|^Sources/CLI/Commands/PlanCommand\.swift$|^Sources/CLI/Commands/VerifyCommand\.swift$|^Sources/MutationModel/Integrity\.swift$|^Sources/MutationModel/MutationVerdictVerifier\.swift$|^Sources/MutationModel/VerdictProof\.swift$|^Sources/MutationModel/MultiTargetVerdict\.swift$|^Sources/AppleBuildAdapters/BuildClassifier\.swift$|^Sources/SchemataEligibilityClassifier/'
# schemata: anything under a Schemata-named source path -> the ROR schemata
# compile fixture plus both standalone schemata-runtime jobs (differential +
# iOS-Simulator). Path is `Scripts/`, not `scripts/` -- this repo's actual
# script directory (git is case-sensitive even though the macOS runners
# these scripts mostly run on are not; `route` itself runs on ubuntu-latest,
# where a lowercase mismatch here would silently never match).
schemata='Schemata|^Sources/MutantKitSchemataRuntimeC/|^Scripts/build-schemata-runtime\.sh$'
# xcode-adapter: the Xcode-project/-workspace build path (as opposed to the
# plain SwiftPM path below) -> every xcode-* acceptance fixture, plus
# cli-commands (its own `init`/`doctor` tests drive a real
# XcodeConfigDetector call -- see that fixture's own comment in ci.yml).
xcode_adapter='^Sources/AppleBuildAdapters/XcodeBuildAdapter\.swift$|^Sources/AppleBuildAdapters/XcodeCompilationUnitImageResolver\.swift$|^Sources/AppleBuildAdapters/XcodeLinkerInjector\.swift$|^Sources/AppleBuildAdapters/XcodeTargetResolver\.swift$|^Sources/AppleBuildAdapters/XcodeConfigDetector\.swift$'
# swift-package: the plain-SwiftPM build path itself (as opposed to the
# sharding/merging logic layered on top of it -- see `sharding` below,
# which used to live in this group and was too broad: a ShardCommand/
# MergeCommand change does not need the full swift-package-ios fixture).
swift_package='^Sources/AppleBuildAdapters/SwiftPackageMacOSAdapter\.swift$'
# sharding: the shard/merge orchestration layer -- a plan gets split,
# each shard runs independently, and the results get merged back together.
# ShardMergeAcceptanceTests is the fixture that actually proves splitting
# the work doesn't change the answer; MergeCommand.swift previously had no
# group of its own at all and fell through to plain cli-commands only,
# missing that fixture entirely.
sharding='^Sources/CLI/Commands/ShardCommand\.swift$|^Sources/CLI/Commands/MergeCommand\.swift$|^Sources/MutationPlanner/PlanSharding\.swift$'
# onboarding: the golden-path setup/init/doctor sequence
# (`mutantkit setup` -> `dry-run` -> `doctor` -> ...) and the detection/
# readiness logic it shares with `init`/`doctor` directly. This group's own
# fixture, `golden-path-onboarding` (GoldenPathOnboardingAcceptanceTests),
# lands with the still-separate golden-path-onboarding feature branch and
# may not exist in this branch's own acceptance matrix yet -- see
# Tests/MutantKitTests/Unit/CIRouteClassificationTests.swift's
# `fixtureAllowlistedAsPending` for the one, narrowly-scoped exception this
# makes to "every fixture the router can emit must exist in the real
# matrix." The rule is added now, keyed to the name it will have, so
# routing is correct the instant that other work merges -- not skipped just
# because the fixture is temporarily absent.
onboarding='^Sources/CLI/Commands/SetupCommand\.swift$|^Sources/CLI/Commands/InitCommand\.swift$|^Sources/CLI/Commands/DoctorCommand\.swift$|^Sources/CLI/ReadinessCheck\.swift$|^Sources/CLI/ProjectDetectionPlan\.swift$|^Sources/CLI/ConfigurationLoader\.swift$'
# cli-commands: the CLI command layer itself (inspect, reproduce, migrate,
# plan, verify, ...) and the handful of CLI-layer support files that don't
# have (and don't need) a more specific group. Deliberately still a broad
# directory prefix for `Sources/CLI/Commands/` -- every file in that
# directory not already claimed by a more specific group above (whose
# checks all run first) correctly falls back to this fixture alone.
cli_commands='^Sources/CLI/Commands/|^Sources/CLI/ConfigurationPreflight\.swift$|^Sources/CLI/GitDiff\.swift$|^Sources/CLI/HostResourcePreflight\.swift$|^Sources/CLI/MutantKit\.swift$|^Sources/CLI/PlanCompatibility\.swift$|^Sources/CLI/ResourceSnapshot\.swift$|^Sources/CLI/RunManifest\.swift$|^Sources/CLI/Version\.swift$'

case "$event_name" in
  push)
    # This workflow's `push` trigger only fires for `branches: [main]` -- a
    # direct push (or merge) to main always gets the full matrix,
    # unconditionally. Main itself is never narrowed.
    run_full="true"
    reason="push to main always runs the full matrix"
    ;;
  workflow_dispatch)
    run_full="true"
    reason="manually dispatched merge-candidate full CI run"
    ;;
  pull_request)
    override_label="$(printf '%s' "$labels_json" | jq -r '.[]' 2>/dev/null | grep -x -e 'ci:full' -e 'ci:merge-ready' | head -1 || true)"
    if [ -n "$override_label" ]; then
      run_full="true"
      reason="override label present on this PR: $override_label"
    elif [ -z "$changed_files" ]; then
      run_full="true"
      reason="no changed-file list was provided -- fail toward the full matrix, never a silent skip"
    else
      matched_any="false"

      if echo "$changed_files" | grep -qE "$trust_critical"; then
        run_full="true"
        reason="changed path(s) matched the trust-critical group (ProcessSupervisor/MutationExecution internals, RunContextProbe, ToolchainProbe, run/gate/plan/verify commands, integrity/cache/classifier/verdict code) -- runs the full matrix, no shortcut"
      else
        if echo "$changed_files" | grep -qE "$schemata"; then
          matched_any="true"; schemata_targeted="true"
          fixtures+=("ror-schemata-compile")
        fi
        if echo "$changed_files" | grep -qE "$xcode_adapter"; then
          matched_any="true"
          fixtures+=("xcode-project" "xcode-workspace" "xcode-app-debug-dylib" "xcode-unlinked-source" "xcode-config-detector" "xcode-batch-testing" "xcode-batch-testing-ui-target" "xcode-coverage-selection" "xcode-incremental-batch-testing" "xcode-wave-early-kill" "cli-commands")
        fi
        if echo "$changed_files" | grep -qE "$swift_package"; then
          matched_any="true"
          fixtures+=("swift-package" "swift-package-coverage" "swift-package-ios" "shard-merge")
        fi
        if echo "$changed_files" | grep -qE "$sharding"; then
          matched_any="true"
          fixtures+=("shard-merge" "cli-commands")
        fi
        if echo "$changed_files" | grep -qE "$onboarding"; then
          matched_any="true"
          fixtures+=("golden-path-onboarding" "cli-commands" "xcode-config-detector")
        fi
        if echo "$changed_files" | grep -qE "$cli_commands"; then
          matched_any="true"
          fixtures+=("cli-commands")
        fi

        # A changed path outside every known group above is exactly the
        # "cannot classify" case -- fail toward the full matrix rather than
        # silently running only whatever the other, unrelated matched
        # groups cover.
        uncovered="$(echo "$changed_files" | grep -vE "$trust_critical|$schemata|$xcode_adapter|$swift_package|$sharding|$onboarding|$cli_commands" || true)"
        if [ -n "$uncovered" ] || [ "$matched_any" = "false" ]; then
          run_full="true"
          reason="at least one changed path did not clearly map to a known targeted group -- unknown must run, never silently skip. Uncovered: $(echo "$uncovered" | paste -sd, - )"
        else
          reason="changed paths matched only: $(printf '%s\n' "${fixtures[@]}" | sort -u | paste -sd, - )"
        fi
      fi
    fi
    ;;
  *)
    run_full="true"
    reason="unrecognized event '$event_name' -- fail toward the full matrix"
    ;;
esac

if [ "${#fixtures[@]}" -gt 0 ]; then
  fixtures_json="$(printf '%s\n' "${fixtures[@]}" | sort -u | jq -R . | jq -s -c .)"
else
  fixtures_json="[]"
fi

# `acceptance_matrix`: the real, already-filtered GitHub Actions matrix
# object -- see this script's own header comment. Built from
# Scripts/ci-fixtures.json (the one source of truth for fixture
# definitions) in both branches, so the full-matrix case and the targeted
# case can never drift into two independently-maintained fixture lists.
if [ "$run_full" = "true" ]; then
  acceptance_matrix="$(jq -c '{include: .fixtures}' "$fixtures_file")"
else
  acceptance_matrix="$(
    jq -c --argjson names "$fixtures_json" \
      '{include: [.fixtures[] | select(.fixture as $f | ($names | index($f)) != null)]}' \
      "$fixtures_file"
  )"
fi

jq -n -c \
  --argjson run_full "$run_full" \
  --argjson run_schemata_targeted "$schemata_targeted" \
  --argjson selected_fixtures "$fixtures_json" \
  --argjson acceptance_matrix "$acceptance_matrix" \
  --arg reason "$reason" \
  '{run_full: $run_full, run_schemata_targeted: $run_schemata_targeted, selected_fixtures: $selected_fixtures, acceptance_matrix: $acceptance_matrix, reason: $reason}'
