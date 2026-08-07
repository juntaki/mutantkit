#!/usr/bin/env bash
#
# release-gate.sh — the full local test gate to run by hand before any public
# projection/publish (`git-projector publish` or equivalent).
#
# Why this exists: two real, serious correctness bugs (batch-attribution
# cross-contamination across mutants, and a worker-sandbox-lifetime bug that
# broke #filePath-based test fixtures) were found only by running a real
# 100-mutant benchmark against a real external project — not by any unit
# test, and not even by the acceptance-test suite, because the acceptance
# suites that would have caught them were not part of any CI/local gate at
# the time. This script is the local, by-hand equivalent of "run everything,
# including the slow real-simulator stuff, before you trust this enough to
# publish."
#
# Phases, in order, each a hard gate on the next:
#   1. swift build --build-tests   — everything must compile, tests included.
#   2. swift test                  — unit/regression suite (fast, no
#                                     simulator; acceptance tests are off by
#                                     default, see AcceptanceSupport.swift).
#   3. MUTANTKIT_ACCEPTANCE=1 swift test
#                                   — the full suite, including the
#                                     acceptance tests that build and mutate
#                                     real fixture projects through a real
#                                     simulator. This is the phase that would
#                                     have caught both bugs above.
#
# Usage: scripts/release-gate.sh
# Exits non-zero on the first failing phase (set -e below); nothing after a
# failure runs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

section() {
    echo
    echo "=================================================================="
    echo "== $1"
    echo "=================================================================="
}

# ── Phase 0: make sure the acceptance suites have a simulator to run on ──────
#
# Mirrors Acceptance.iPhoneDestination() in
# Tests/MutantKitTests/Acceptance/AcceptanceSupport.swift: pick *any*
# available iPhone runtime rather than pinning a model (a fixture pinning
# "iPhone 17 Pro" would fail on a machine with only an older runtime
# installed, and fail as an infrastructure error, not a real result), and
# choose deterministically (sorted by name, first wins) so repeat runs on
# one machine pick the same device.
section "Phase 0/3: Ensuring an iPhone simulator is available and booted"

if xcrun simctl list devices booted | grep -qi "iPhone"; then
    echo "An iPhone simulator is already booted. Using it as-is."
else
    echo "No booted iPhone simulator found. Looking for one to boot..."

    # Same ordering rule as iPhoneDestination(): sort candidate device lines
    # by name and take the first, so this is deterministic across runs.
    candidate_line="$(xcrun simctl list devices available \
        | grep -i "iPhone" \
        | sort \
        | head -n 1 || true)"

    if [[ -z "$candidate_line" ]]; then
        echo "error: no available iPhone simulator runtime found." >&2
        echo "Install one via Xcode > Settings > Components, or boot one" >&2
        echo "yourself first, then re-run this script." >&2
        exit 1
    fi

    candidate_udid="$(echo "$candidate_line" \
        | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')"

    if [[ -z "$candidate_udid" ]]; then
        echo "error: could not parse a simulator UDID from:" >&2
        echo "  $candidate_line" >&2
        exit 1
    fi

    echo "Booting: $candidate_line"
    xcrun simctl boot "$candidate_udid"
    xcrun simctl bootstatus "$candidate_udid" -b
fi

# ── Phase 1: build ────────────────────────────────────────────────────────
section "Phase 1/3: swift build --build-tests"
swift build --build-tests

# ── Phase 2: unit / regression tests (acceptance suites stay disabled) ───────
section "Phase 2/3: swift test (unit/regression only)"
swift test

# ── Phase 3: full suite, including real-simulator acceptance tests ──────────
#
# MUTANTKIT_ACCEPTANCE=1 with MUTANTKIT_ACCEPTANCE_SIMULATOR left unset
# enables every acceptance suite, including the ones gated on
# Acceptance.simulatorEnabled (see AcceptanceSupport.swift) — this is the
# phase that exercises real xcodebuild/xctestrun/simulator behavior.
section "Phase 3/3: MUTANTKIT_ACCEPTANCE=1 swift test (full suite, real simulator)"
MUTANTKIT_ACCEPTANCE=1 swift test

section "Release gate passed: build, unit tests, and full acceptance suite all green."
