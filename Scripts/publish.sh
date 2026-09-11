#!/usr/bin/env bash
# publish.sh -- single entrypoint for a git-projector publish, wrapping the
# checklist that was, until now, a human (or agent) had to remember and run
# correctly by hand every time:
#
#   (a) confirm the private repo's git status is clean, and that HEAD is
#       the commit you mean to publish
#   (b) run `projector diff` and confirm its leak scan found nothing
#   (c) confirm the predicted file list matches the intended changes
#   (d) confirm oss-public/.github matches the public repo's current
#       .github (or that every place it doesn't is already accounted for
#       in (b)'s file list) -- so a publish can't silently rewrite/revert
#       the public repo's CI
#   (d2) run Scripts/assert-projection-workflow-invariants.sh, a stronger,
#       structural check than (d): (d) only catches BYTE differences, so it
#       flags an intended edit exactly like a silent regression and cannot
#       tell a narrowed trigger, a dropped `needs:` edge, or a
#       fixture-matrix drift from a harmless rewrite. This is the check
#       that actually would have caught the 2026-09-01 incident (a stale
#       oss-public/ silently reverting action-smoke-test.yml's
#       pull_request trigger and losing four ci.yml jobs). It is additive
#       to (d), not a replacement -- see the script's own header comment.
#   (e) run `projector publish --message '...'`
#   (f) review the resulting public commit before pushing
#
# What this script DOES:
#   - Automates (a), (b), (d), (d2) as hard pre-publish gates: any of them
#     failing exits non-zero with a clear message and calls `projector
#     publish` not at all.
#   - Prints the projector-diff file list prominently before publishing,
#     for the human/agent running this script to eyeball against the
#     intended changes -- (c) is a judgement call about intent that only
#     the operator can make; this script cannot make it for you, only put
#     the evidence in front of you and pause for a yes/no (see --yes below).
#   - Calls `projector publish --message ...` for step (e).
#   - Automates the (f) sanity check on the *result*: the new public
#     commit must not be empty, and must not touch any file outside what
#     step (b) predicted. Still fails loudly (non-zero) if that ever
#     doesn't hold -- the commit it made is NOT rolled back (same
#     fix-forward policy as `projector publish`'s own build/test gate),
#     but you will know immediately, before you push.
#   - Prints, but never runs, the exact `git push` command for a human to
#     review and execute.
#
# What this script does NOT do:
#   - It does NOT run the private repo's unit or acceptance suites.
#     `projector publish` already runs its own verify_build hook
#     (`swift build --build-tests && swift test`) once against the
#     *projected public tree* as its internal safety gate; running the
#     private suite again here would duplicate that gate for no benefit.
#     Run Scripts/release-gate.sh yourself beforehand if you want the full
#     acceptance suite (real simulator) covered too -- this script assumes
#     you already did, it does not check for it.
#   - It does NOT run `git push`, ever, under any flag.
#   - It does NOT judge whether the file list "matches the intended
#     changes" -- it shows you the list and (outside --dry-run/--yes)
#     waits for you to say so.
#
# Usage:
#   Scripts/publish.sh "commit message"                 # real publish
#   Scripts/publish.sh --message-file path/to/msg.txt
#   printf 'msg' | Scripts/publish.sh --message-stdin
#   Scripts/publish.sh --dry-run "commit message"        # run every check
#                                                         # except the
#                                                         # actual publish
#                                                         # and push
#   Scripts/publish.sh --yes "commit message"            # skip the
#                                                         # interactive
#                                                         # confirmation
#                                                         # (for authorized
#                                                         # non-interactive
#                                                         # callers only)
#   Scripts/publish.sh --repo /path/to/other/checkout ... # target a repo
#                                                          # other than the
#                                                          # one this script
#                                                          # lives in -- for
#                                                          # rehearsing
#                                                          # against a
#                                                          # scratch clone,
#                                                          # not routine use
#
# Exit status: 0 only if every pre-publish check passed and (outside
# --dry-run) the publish itself and the post-publish check both passed.
# Non-zero, with a message on stderr identifying which check failed,
# otherwise.

set -euo pipefail

DEFAULT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$DEFAULT_REPO_ROOT"

PROJECTOR="/Users/juntaki/work/git-projector/.venv/bin/projector"

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

# ── Argument parsing ──────────────────────────────────────────────────────

DRY_RUN=0
ASSUME_YES=0
MESSAGE=""
MESSAGE_SET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --repo)
            # Mirrors projector's own --repo flag. Defaults to this
            # script's own repo (the normal, real-use case). Exists so a
            # scratch clone/worktree can be validated with this exact
            # script before ever pointing it at the real private repo --
            # not for routine use.
            [[ $# -ge 2 ]] || fail "--repo requires a path argument"
            REPO_ROOT="$(cd "$2" && pwd)"
            shift 2
            ;;
        --message)
            [[ $# -ge 2 ]] || fail "--message requires an argument"
            MESSAGE="$2"
            MESSAGE_SET=1
            shift 2
            ;;
        --message-file)
            [[ $# -ge 2 ]] || fail "--message-file requires a path argument"
            [[ -f "$2" ]] || fail "--message-file: no such file: $2"
            MESSAGE="$(cat "$2")"
            MESSAGE_SET=1
            shift 2
            ;;
        --message-stdin)
            MESSAGE="$(cat -)"
            MESSAGE_SET=1
            shift
            ;;
        -h|--help)
            sed -n '2,85p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            fail "unrecognized option: $1 (see --help)"
            ;;
        *)
            if [[ "$MESSAGE_SET" -eq 1 ]]; then
                fail "commit message given more than once (positional and --message*/--message-stdin)"
            fi
            MESSAGE="$1"
            MESSAGE_SET=1
            shift
            ;;
    esac
done

if [[ "$DRY_RUN" -eq 0 && "$MESSAGE_SET" -eq 0 ]]; then
    fail "a commit message is required unless --dry-run is given (positional arg, --message, --message-file, or --message-stdin)"
fi

[[ -x "$PROJECTOR" ]] || fail "projector not found or not executable at $PROJECTOR"
[[ -d "$REPO_ROOT/.git" || -f "$REPO_ROOT/.git" ]] || fail "$REPO_ROOT does not look like a git repo (no .git)"
cd "$REPO_ROOT"

# ── Step (a): private repo must be clean, and HEAD must be shown for the ────
# operator to confirm it is the commit they mean to publish. This script
# cannot know "intended" on its own -- it can only make sure nothing
# uncommitted sneaks into the snapshot, and put HEAD in front of you.

section "Step 1/6: private repo git status (checklist step a)"

dirty="$(git -C "$REPO_ROOT" status --porcelain)"
if [[ -n "$dirty" ]]; then
    echo "$dirty" >&2
    fail "private repo working tree is not clean -- commit, stash, or discard the above before publishing"
fi
echo "private repo is clean."

head_line="$(git -C "$REPO_ROOT" log -1 --format='%H %s')"
echo "private HEAD: $head_line"
echo "  -> confirm this is the commit you intend to publish."

# ── Step (b): projector diff -- leak scan + predicted file list ────────────
# `projector diff` itself exits non-zero when its leak scan finds hits, so
# its exit code alone is the gate; we still capture output to (1) show the
# operator the file list for step (c) and (2) use that same list as the
# ground truth for step (d) and the post-publish check.

section "Step 2/6: projector diff (checklist step b: leak scan + file list)"

diff_log="$(mktemp -t mutantkit-publish-diff.XXXXXX)"
trap 'rm -f "$diff_log"' EXIT

diff_rc=0
"$PROJECTOR" --repo "$REPO_ROOT" diff >"$diff_log" 2>&1 || diff_rc=$?
cat "$diff_log"

if [[ "$diff_rc" -ne 0 ]]; then
    fail "projector diff failed (exit $diff_rc) -- most likely the leak scan found hits, see output above. Refusing to publish."
fi

if grep -q '^up to date -- nothing to publish$' "$diff_log"; then
    fail "projector diff reports nothing to publish -- refusing to run a publish that would produce an empty commit"
fi

if grep -qE '^  \.\.\. and [0-9]+ more$' "$diff_log"; then
    truncated=1
    echo "warning: projector diff truncated its file list at 50 entries -- this script cannot mechanically verify the .github overlay check or the post-publish subset check against the missing entries. Review the full list by hand (e.g. re-run with a narrower checkpoint) before trusting this run's automated checks below."
else
    truncated=0
fi

# awk, not sed -- BSD sed's BRE dialect (macOS /bin/sed, matching this
# repo's other scripts' bash 3.2 target) doesn't take \+/\| the way GNU
# sed does, and this needs to stay portable rather than assume GNU sed.
predicted_files=()
while IFS= read -r line; do
    predicted_files+=("$line")
done < <(awk '
    /^(would change|changes) [0-9]+ file\(s\):$/ { infiles=1; next }
    infiles && /^  \.\.\. and [0-9]+ more$/ { next }
    infiles && /^  / { sub(/^  /, ""); print; next }
    infiles && /^$/ { infiles = 0 }
' "$diff_log")

echo
echo "predicted file list (${#predicted_files[@]} shown) -- checklist step (c): review this against the changes you intended:"
if [[ "${#predicted_files[@]}" -gt 0 ]]; then
    printf '  %s\n' "${predicted_files[@]}"
fi

# Note: "${arr[@]}" on a zero-element array is an "unbound variable" error
# under `set -u` on bash < 4.4 (this repo's other scripts target the
# system /bin/bash, 3.2 on macOS) -- every array expansion below is
# guarded the same way, either by an explicit length check first or via
# the "${arr[@]+"${arr[@]}"}" idiom.
predicted_contains() {
    local needle="$1" f
    for f in "${predicted_files[@]+"${predicted_files[@]}"}"; do
        [[ "$f" == "$needle" ]] && return 0
    done
    return 1
}

# ── Step (d): oss-public/.github vs the public repo's actual .github ───────
# The overlay wholesale-replaces .github/ on every publish, so any
# difference here WILL be published. That is fine when the difference is
# already visible in step (b)'s predicted file list (an operator reviewed
# it in step (c)); it is exactly the silent-CI-revert failure mode this
# check exists to catch when it is NOT.

section "Step 3/6: oss-public/.github vs public repo .github (checklist step d)"

status_log="$("$PROJECTOR" --repo "$REPO_ROOT" status 2>&1 || true)"
echo "$status_log"
public_repo="$(printf '%s\n' "$status_log" | sed -n 's/^public repo: //p' | head -n 1)"
[[ -n "$public_repo" && -d "$public_repo" ]] || fail "could not determine the public repo path from 'projector status' output above"

oss_github="$REPO_ROOT/oss-public/.github"
public_github="$public_repo/.github"
[[ -d "$oss_github" ]] || fail "expected overlay directory not found: $oss_github"

# Plain array + linear-scan dedup, not an associative array: this repo's
# other Scripts/*.sh target the system /bin/bash (3.2 on macOS), which has
# no `declare -A`/mapfile -- kept compatible with that rather than
# requiring a newer bash just for this script.
github_mismatches=()

mismatch_seen() {
    local needle="$1" f
    for f in "${github_mismatches[@]+"${github_mismatches[@]}"}"; do
        [[ "$f" == "$needle" ]] && return 0
    done
    return 1
}

if [[ -d "$oss_github" ]]; then
    while IFS= read -r -d '' f; do
        rel=".github/${f#"$oss_github"/}"
        pub_f="$public_github/${rel#.github/}"
        if [[ ! -f "$pub_f" ]] || ! cmp -s "$f" "$pub_f"; then
            mismatch_seen "$rel" || github_mismatches+=("$rel")
        fi
    done < <(find "$oss_github" -type f -print0)
fi

if [[ -d "$public_github" ]]; then
    while IFS= read -r -d '' f; do
        rel=".github/${f#"$public_github"/}"
        oss_f="$oss_github/${rel#.github/}"
        if [[ ! -f "$oss_f" ]]; then
            mismatch_seen "$rel" || github_mismatches+=("$rel")
        fi
    done < <(find "$public_github" -type f -print0)
fi

if [[ "${#github_mismatches[@]}" -eq 0 ]]; then
    echo "oss-public/.github matches the public repo's current .github exactly -- nothing to publish there."
else
    echo "oss-public/.github differs from the public repo's .github in ${#github_mismatches[@]} file(s):"
    unpredicted=()
    for rel in "${github_mismatches[@]}"; do
        if predicted_contains "$rel"; then
            echo "  $rel  (accounted for in the predicted file list above -- OK)"
        else
            echo "  $rel  (NOT in the predicted file list)"
            unpredicted+=("$rel")
        fi
    done
    if [[ "${#unpredicted[@]}" -gt 0 ]]; then
        if [[ "$truncated" -eq 1 ]]; then
            fail "${#unpredicted[@]} .github file(s) differ and are not visible in projector diff's (truncated) file list -- cannot confirm this isn't a silent CI change. Re-run 'projector diff' directly and review the full list by hand."
        fi
        fail "${#unpredicted[@]} .github file(s) would be silently changed by this publish without appearing in projector diff's predicted file list: ${unpredicted[*]} -- refusing (this is exactly the silent-CI-revert failure mode this check exists to catch)."
    fi
fi

# ── Step (d2): assert-projection-workflow-invariants.sh ────────────────────
# Strictly stronger than step (d) above, not a replacement for it: step (d)
# is a byte-level diff of oss-public/.github against the public repo's
# current .github, so it flags an intended, reviewed edit exactly the same
# way it flags a silent regression, and it has no notion of "workflow",
# "job", or "trigger" -- it cannot tell that a `needs:` edge was dropped, a
# trigger was narrowed, or the ci-fixtures.json/matrix contract drifted.
# This guard understands all of that, and is the check that actually would
# have caught this project's own worst historical incident (2026-09-01: a
# stale oss-public/ silently reverted action-smoke-test.yml's
# `pull_request` trigger and dropped four ci.yml jobs -- a regression that,
# once published, is invisible to `projector diff` forever after, because
# both sides then match). See its own header comment
# (Scripts/assert-projection-workflow-invariants.sh) for the full case and
# its "WHERE TO CALL IT FROM" section for why it must run here and not as a
# git-projector hook: by the time any hook runs, `projector publish` has
# already mirrored the projection into the public repo's working tree, so
# the "baseline" a hook would compare against IS the proposal.
#
# No overrides are passed. The guard's own defaults -- derived from
# .public-tree.toml -- are exactly right for a real publish: the projected
# tree is oss-public/ (the sole source of the projected .github/, per the
# overlay rule), and the baseline is the public repo's HEAD, proven
# identical to what `origin` is currently serving (not a stale clone, not a
# local commit GitHub has never seen). Scripts/projection-workflow-waivers.json
# is already a tracked file (empty today), so no waiver-related flag is
# needed either. None of the four evidence-weakening flags
# (--allow-dirty-public-workflows, --allow-stale-public-baseline,
# --public-baseline-from-worktree, --allow-untracked-waivers) are passed --
# per this codebase's own trust stance, a real publish must not loosen any
# of them; that is deliberate, not an oversight.
#
# --receipt records what was actually approved (this guard's own sha256,
# the baseline commit, a digest of the projected .github/ + fixtures) so a
# publish that skipped this gate is distinguishable from one that passed
# it. We additionally require the receipt to exist and say "pass" in code,
# rather than trusting the exit status alone -- a check that reports 0 but
# produces no evidence of what it approved has not, by this script's own
# "a check that could not run has NOT passed" standard, actually passed.

section "Step 4/6: pre-publish CI-invariant guard (checklist step d2)"

guard_script="$REPO_ROOT/Scripts/assert-projection-workflow-invariants.sh"
[[ -x "$guard_script" ]] || fail "$guard_script not found or not executable"

guard_receipt="$(mktemp -t mutantkit-publish-guard-receipt.XXXXXX)"
trap 'rm -f "$diff_log" "$guard_receipt"' EXIT

guard_rc=0
"$guard_script" --receipt "$guard_receipt" || guard_rc=$?

if [[ "$guard_rc" -ne 0 ]]; then
    fail "assert-projection-workflow-invariants.sh failed (exit $guard_rc) -- see its output above. Refusing to publish: this projection would silently change the public repo's CI. If a reduction it reports is real and reviewed, add a waiver to Scripts/projection-workflow-waivers.json exactly as the guard's own output instructs, then re-run this script."
fi

[[ -s "$guard_receipt" ]] || fail "assert-projection-workflow-invariants.sh exited 0 but wrote no receipt to $guard_receipt -- a pass with no evidence of what was approved is not a pass. Refusing to publish."

guard_receipt_result="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("result", ""))
except Exception:
    print("")' "$guard_receipt" 2>/dev/null || true)"
[[ "$guard_receipt_result" == "pass" ]] || fail "assert-projection-workflow-invariants.sh's receipt at $guard_receipt does not record result=pass (got '${guard_receipt_result:-<unreadable>}') -- refusing to publish without unambiguous evidence the guard actually passed."

echo "pre-publish CI-invariant guard passed (receipt: $guard_receipt)."

# ── Step (c) gate: pause for a human/agent go-ahead before the real ────────
# publish. Skipped entirely for --dry-run (nothing is published) and for
# --yes (an already-authorized, non-interactive caller).

if [[ "$DRY_RUN" -eq 1 ]]; then
    section "Dry run: stopping before publish/push (checklist steps e-g not run)"
    echo "All pre-publish checks (a, b, d, d2) passed, and the file list above is what a real run would predict for step (c)."
    echo "Nothing was published; the public repo was not touched."
    exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
    section "Confirm before publishing (checklist step c)"
    echo "About to run: projector publish against $public_repo"
    read -r -p "Proceed? [y/N] " reply </dev/tty || fail "no terminal available to confirm -- pass --yes if this is an authorized non-interactive run"
    case "$reply" in
        y|Y|yes|YES) ;;
        *) fail "not confirmed -- aborting before publish" ;;
    esac
fi

# ── Step (e): the real publish ──────────────────────────────────────────────
# `projector publish` builds+tests the merged public tree once as its own
# safety gate, and commits locally to the public repo clone. It does not
# push, and neither do we.

section "Step 5/6: projector publish (checklist step e)"

"$PROJECTOR" --repo "$REPO_ROOT" publish --message "$MESSAGE"

# ── Post-publish validation (part of checklist step f, automated) ─────────
# The resulting public commit must be non-empty, and must not touch
# anything outside what step (b) predicted. If either check fails, the
# commit already made in the public repo is NOT rolled back (fix forward,
# same policy `projector publish` itself documents for its own build/test
# gate) -- but you will see this before pushing.

section "Step 6/6: validating the resulting public commit (checklist step f)"

public_files_log="$(git -C "$public_repo" show --name-only --format='' HEAD)"
public_files=()
while IFS= read -r f; do
    [[ -n "$f" ]] && public_files+=("$f")
done <<<"$public_files_log"

if [[ "${#public_files[@]}" -eq 0 ]]; then
    fail "the public commit just made has an EMPTY file list (git show --name-only HEAD) -- this should be impossible given step (b) found changes; investigate before pushing. Public repo: $public_repo"
fi

echo "git -C $public_repo show --stat HEAD:"
git -C "$public_repo" show --stat HEAD

if [[ "$truncated" -eq 1 ]]; then
    echo "warning: predicted file list was truncated -- skipping the automated subset check; verify $public_repo's new commit by hand against the full 'projector diff' output before pushing."
else
    outside=()
    for f in "${public_files[@]}"; do
        predicted_contains "$f" || outside+=("$f")
    done
    if [[ "${#outside[@]}" -gt 0 ]]; then
        fail "the public commit changed file(s) that projector diff did NOT predict: ${outside[*]} -- refusing to consider this publish safe. The commit already exists, unpushed, at $public_repo (git -C $public_repo show --stat HEAD). Investigate before pushing or resetting it."
    fi
    echo "public commit's file list is a subset of what 'projector diff' predicted -- OK."
fi

new_sha="$(git -C "$public_repo" rev-parse HEAD)"

section "Publish complete -- human review and push required"
echo "Committed locally to $public_repo at ${new_sha:0:12}. NOT pushed."
echo
echo "Review it, then push it yourself:"
echo
echo "  git -C $public_repo show --stat HEAD"
echo "  git -C $public_repo push origin main"
