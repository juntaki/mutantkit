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
# Usage: Scripts/release-gate.sh
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

# ── Pre-flight: the documented release version must be a tag that exists ─────
#
# `DocumentedVersionPinConsistencyTests` already proves that every version
# named across README.md/action.yml/docs/skills agrees with the one README
# declares as the latest release. It deliberately stops there: a projected
# public snapshot is checked out without tags, so a tag assertion living in
# the test suite would be unrunnable in exactly the tree where it matters
# most. This is the other half of that gate, and it belongs here because
# this script only ever runs in a real clone, immediately before a publish.
#
# The failure it exists to prevent already shipped once: README pinned
# `uses: juntaki/mutantkit@v0.3.0` in three places, and action.yml gave the
# same version as its `version:` example, while the newest tag that had ever
# existed was v0.2.0 — so every user who copied the README's CI snippet got
# an unresolvable action.
#
# Runs first, ahead of the simulator boot and the ~hour of tests below: a
# stale pin should cost a second to find, not an hour. Same reasoning as the
# toolchain-floor check being the first step of ci.yml's lint job.
section "Pre-flight: documented release version exists as a git tag"

declared_version="$(grep -m 1 '(latest release)' README.md \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
    | head -n 1 || true)"

if [[ -z "$declared_version" ]]; then
    echo "error: could not read a declared latest release from README.md." >&2
    echo "Expected a line containing '(latest release)' alongside a vX.Y.Z version." >&2
    exit 1
fi

echo "README declares latest release: $declared_version"

if ! git rev-parse -q --verify "refs/tags/$declared_version" >/dev/null; then
    echo "error: README declares $declared_version as the latest release, but no such git tag exists." >&2
    echo "Tags present:" >&2
    git tag --sort=-v:refname | head -n 5 | sed 's/^/  /' >&2
    echo >&2
    echo "Either cut $declared_version before publishing, or correct README.md's status line" >&2
    echo "and every version it pins — DocumentedVersionPinConsistencyTests enforces that they" >&2
    echo "all agree with each other, and this check enforces that the agreed version is real." >&2
    exit 1
fi

echo "Tag $declared_version exists."

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
