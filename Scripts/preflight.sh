#!/usr/bin/env bash
# preflight.sh -- every cheap, deterministic check that public CI would
# otherwise be the first place to discover, run once, locally, before a
# publish.
#
# Why this exists: three separate v0.5/v0.6 corrections each published a
# real fix for something a fast, deterministic, local check could already
# see (SwiftLint, SwiftFormat, the complexity gate) -- three public SHAs
# and three public CI cycles to close what one local pass would have
# caught before the first publish. This script is that one local pass.
#
# What this runs (all read-only, no network beyond `projector diff`'s own
# local file comparisons, no publish, no push):
#   1. SwiftFormat --lint          (exact CI invocation)
#   2. SwiftLint --strict --baseline (exact CI invocation)
#   3. swift-complexity            (exact CI invocation)
#   4. projector diff              (leak scan + oss-public/.github drift,
#                                    the same checks Scripts/publish.sh's
#                                    own steps (a)/(b)/(d) perform)
#   5. Version/doc-consistency regression tests (targeted swift test
#      --filter, not a full suite) -- DocumentedVersionPinConsistencyTests
#      and PublicTreeConfigRegressionTests
#
# What this does NOT run: the product's own unit/acceptance test suites.
# Product-behavior correctness is targeted swift test runs during
# development and, for broad integration, public CI itself -- this script
# is deliberately scoped to the class of failure that is cheap, fast, and
# fully deterministic (same input, same output, every time), which is
# exactly the class that should never need a public CI round-trip to find.
#
# Usage:
#   Scripts/preflight.sh              # run every check
#   Scripts/preflight.sh --repo PATH  # target a repo other than this one
#
# Exit status: 0 only if every check passed. Non-zero, with the failing
# check named on stderr, otherwise -- run it again after fixing, this
# script does not fix anything itself.

set -euo pipefail

DEFAULT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$DEFAULT_REPO_ROOT"

PROJECTOR="/Users/juntaki/work/git-projector/.venv/bin/projector"
SWIFT_COMPLEXITY_THRESHOLD=25

section() {
    echo
    echo "=================================================================="
    echo "== $1"
    echo "=================================================================="
}

fail() {
    echo "error: $1" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            [[ $# -ge 2 ]] || fail "--repo requires a path argument"
            REPO_ROOT="$(cd "$2" && pwd)"
            shift 2
            ;;
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            fail "unrecognized argument: $1 (see --help)"
            ;;
    esac
done

cd "$REPO_ROOT"

section "1/5: SwiftFormat --lint"
if ! command -v swiftformat >/dev/null 2>&1; then
    fail "swiftformat not found on PATH -- brew install swiftformat"
fi
swiftformat --lint --config .swiftformat . || fail "SwiftFormat found formatting violations -- run 'swiftformat --config .swiftformat .' to fix, then re-run this script"

section "2/5: SwiftLint --strict --baseline"
if ! command -v swiftlint >/dev/null 2>&1; then
    fail "swiftlint not found on PATH -- brew install swiftlint"
fi
swiftlint lint --strict --config .swiftlint.yml --baseline .swiftlint-baseline.json Sources Tests \
    || fail "SwiftLint found violations against the exact CI invocation -- see output above"

section "3/5: swift-complexity (threshold $SWIFT_COMPLEXITY_THRESHOLD)"
if ! command -v swift-complexity >/dev/null 2>&1; then
    fail "swift-complexity not found on PATH -- brew install fummicc1/tap/swift-complexity"
fi
complexity_output="$(swift-complexity Sources Tests --recursive --threshold "$SWIFT_COMPLEXITY_THRESHOLD" --report-suppressions 2>&1)"
echo "$complexity_output"
if echo "$complexity_output" | grep -qE '^\| Function/Method'; then
    fail "swift-complexity found function(s) over threshold $SWIFT_COMPLEXITY_THRESHOLD -- see the table above"
fi

section "4/5: projection integrity (leak scan + oss-public/.github drift)"
[[ -x "$PROJECTOR" ]] || fail "projector not found or not executable at $PROJECTOR"
# `projector diff` materializes the projection from `git HEAD`, not the
# working tree -- an uncommitted change (staged or not) that would trip the
# leak scan or the drift check reports a false "up to date, nothing to
# publish" pass instead of the real violation. Found the hard way
# (2026-09-11): a real leak and a real internal_reference_patterns
# violation both slipped past a "passing" preflight run because neither
# had been committed yet. Warn loudly rather than silently trusting a
# pass that may not have scanned anything real.
if ! git -C "$REPO_ROOT" diff --quiet HEAD -- || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "warning: uncommitted changes present -- this step compares against git HEAD, so it" \
        "will NOT see your working-tree changes. Commit first for a meaningful leak scan." >&2
fi
diff_log="$(mktemp -t mutantkit-preflight-diff.XXXXXX)"
trap 'rm -f "$diff_log"' EXIT
diff_rc=0
"$PROJECTOR" --repo "$REPO_ROOT" diff >"$diff_log" 2>&1 || diff_rc=$?
cat "$diff_log"
if [[ "$diff_rc" -ne 0 ]]; then
    fail "projector diff failed (exit $diff_rc) -- most likely the leak scan found hits, see output above"
fi

section "5/5: version/doc-consistency regression tests (targeted, not a full suite)"
swift test --filter "DocumentedVersionPinConsistencyTests|PublicTreeConfigRegressionTests" 2>&1 | tail -20
# `swift test --filter` exits non-zero on failure on its own; if execution
# reaches here the filtered run passed.

section "Preflight passed"
echo "All 5 cheap, deterministic checks passed. Safe to run Scripts/publish.sh."
