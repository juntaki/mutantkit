#!/usr/bin/env bash
#
# release-artifact-gate.sh — verify a real, built `mutantkit` release
# *artifact* (the tarball an end user actually downloads) end-to-end,
# entirely outside this source checkout.
#
# This is deliberately distinct from, and complementary to, `release-gate.sh`:
# that script gates the *source tree* (build + unit tests + the real-simulator
# acceptance suite, all run against this checkout itself). Nothing in that
# suite ever packages a tarball, extracts it somewhere else, or proves that a
# binary with zero access to this repository can resolve its own bundled
# schemata runtime and run a real mutation. This script is the artifact-level
# complement: it never mutates or asserts anything about this checkout's
# source — only about the tarball `scripts/release-build.sh` produces from it.
#
# Pipeline (each phase a hard gate on the next):
#   1. scripts/release-build.sh <version> <build-dir>  — produce the real
#      tarball, stamped with <version> and this checkout's own commit SHA.
#   2. Verify the tarball's own SHA256SUMS against the tarball bytes on disk.
#   3. Extract to a second, separate temp dir — simulating an end user's
#      machine with no access to this repo at all.
#   4. Check the extracted layout against an allowlist read directly out of
#      release-build.sh's own output-construction logic.
#   5. Run the extracted `mutantkit --version`; confirm the reported version
#      and embedded commit SHA match what step 1 actually built.
#   6. Decode and validate lib/mutantkit/schemata/manifest.json against the
#      real shape SchemataRuntimeManifest.swift expects.
#   7. Verify every declared runtime archive's SHA-256 against the manifest's
#      own declared digest, and its real architecture slices via `lipo`.
#   8. The critical end-to-end step: from a temp directory outside every
#      mutantkit checkout, with MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE
#      explicitly unset, clone a small pinned real corpus (swift-numerics)
#      and run the *extracted packaged binary* — `plan` then `run` — against
#      it, resolving its schemata runtime purely from what it bundles.
#   9. Confirm this checkout's own working tree is left clean.
#
# Usage: Scripts/release-artifact-gate.sh <version>
#   <version> — e.g. "0.1.0" or "0.0.0-f7-test". Passed straight through to
#   release-build.sh; this script never chooses or bumps a real release
#   version itself — that decision is out of scope here.
#
# Exits non-zero on the first failing phase (set -e below), with a clear
# diagnosis printed before it does.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

section() {
    echo
    echo "=================================================================="
    echo "== $1"
    echo "=================================================================="
}

fail() {
    echo
    echo "FAIL: $1" >&2
    echo
    echo "=================================================================="
    echo "== Release artifact gate FAILED"
    echo "=================================================================="
    exit 1
}

VERSION="${1:?usage: Scripts/release-artifact-gate.sh <version>}"

# ── Scratch directories — all outside this checkout, all under mktemp -d ────
BUILD_DIR="$(mktemp -d -t mutantkit-release-artifact-build)"
EXTRACT_DIR="$(mktemp -d -t mutantkit-release-artifact-extract)"
CORPUS_DIR="$(mktemp -d -t mutantkit-release-artifact-corpus)"

cleanup() {
    rm -rf "$BUILD_DIR" "$EXTRACT_DIR" "$CORPUS_DIR"
}
trap cleanup EXIT

echo "Build dir:   $BUILD_DIR"
echo "Extract dir: $EXTRACT_DIR"
echo "Corpus dir:  $CORPUS_DIR"

# ── Phase 1/9: build the real tarball ────────────────────────────────────
section "Phase 1/9: Scripts/release-build.sh $VERSION <build-dir>"

BUILD_COMMIT_SHA="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
echo "Building from commit: $BUILD_COMMIT_SHA"

"$REPO_ROOT/Scripts/release-build.sh" "$VERSION" "$BUILD_DIR"

PACKAGE_NAME="mutantkit-macos-arm64"
TARBALL="$BUILD_DIR/${PACKAGE_NAME}.tar.gz"
[[ -f "$TARBALL" ]] || fail "expected tarball not found at $TARBALL"
[[ -f "$BUILD_DIR/SHA256SUMS" ]] || fail "expected $BUILD_DIR/SHA256SUMS not found"

# ── Phase 2/9: verify SHA256SUMS against the tarball's real bytes ───────────
section "Phase 2/9: shasum -a 256 -c SHA256SUMS"

(
    cd "$BUILD_DIR"
    shasum -a 256 -c SHA256SUMS
) || fail "SHA256SUMS did not verify against the built tarball's actual bytes"

# ── Phase 3/9: extract to a second, separate temp dir ───────────────────────
#
# This is the "end user's machine" step: EXTRACT_DIR has no relationship to
# this git checkout at all, only to the tarball's own bytes.
section "Phase 3/9: extract to a second temp dir (simulated end-user machine)"

tar xzf "$TARBALL" -C "$EXTRACT_DIR"
PACKAGE_DIR="$EXTRACT_DIR/$PACKAGE_NAME"
[[ -d "$PACKAGE_DIR" ]] || fail "extracted tarball did not produce $PACKAGE_DIR"

# ── Phase 4/9: extracted layout must match an explicit allowlist ────────────
#
# Read directly out of release-build.sh's own PACKAGE_DIR construction
# (the `cp .../mutantkit`, `cp .../LICENSE`, and the `lib/mutantkit/schemata/`
# tree it builds) — not guessed.
section "Phase 4/9: extracted package layout vs. allowlist"

EXPECTED_FILES="LICENSE
lib/mutantkit/schemata/iphonesimulator/libMutantKitSchemataRuntime.a
lib/mutantkit/schemata/macosx/libMutantKitSchemataRuntime.a
lib/mutantkit/schemata/manifest.json
mutantkit"

ACTUAL_FILES="$(cd "$PACKAGE_DIR" && find . -type f | sed 's|^\./||' | sort)"
EXPECTED_SORTED="$(echo "$EXPECTED_FILES" | sort)"

if [[ "$ACTUAL_FILES" != "$EXPECTED_SORTED" ]]; then
    echo "Expected files:" >&2
    echo "$EXPECTED_SORTED" >&2
    echo "Actual files:" >&2
    echo "$ACTUAL_FILES" >&2
    fail "extracted package layout does not match the allowlist derived from release-build.sh"
fi
echo "Layout matches allowlist exactly:"
echo "$ACTUAL_FILES"

MUTANTKIT_BIN="$PACKAGE_DIR/mutantkit"
[[ -x "$MUTANTKIT_BIN" ]] || fail "$MUTANTKIT_BIN is not present/executable"

# ── Phase 5/9: --version reports the real version and commit SHA ────────────
section "Phase 5/9: extracted binary --version vs. what was actually built"

VERSION_OUTPUT="$("$MUTANTKIT_BIN" --version)"
echo "$VERSION_OUTPUT"

FIRST_LINE="$(echo "$VERSION_OUTPUT" | head -n1)"
[[ "$FIRST_LINE" == "mutantkit $VERSION" ]] \
    || fail "expected first line 'mutantkit $VERSION', got '$FIRST_LINE'"

echo "$VERSION_OUTPUT" | grep -qF "commit: $BUILD_COMMIT_SHA" \
    || fail "expected 'commit: $BUILD_COMMIT_SHA' in --version output, got:\n$VERSION_OUTPUT"

# ── Phase 6/9: manifest.json shape vs. SchemataRuntimeManifest.swift ────────
#
# Expected schemaVersion/runtimeABIVersion read from the same sources of
# truth release-build.sh itself reads from — never a second hardcoded
# literal that could quietly drift from the real contract.
section "Phase 6/9: manifest.json shape vs. SchemataRuntimeManifest.swift"

RUNTIME_ABI_HEADER="$REPO_ROOT/Sources/MutantKitSchemataRuntimeC/include/mutantkit_protocol_v3.h"
EXPECTED_RUNTIME_ABI_VERSION="$(grep -Eo '#define +MUTANTKIT_V3_RUNTIME_ABI_VERSION +[0-9]+' "$RUNTIME_ABI_HEADER" | grep -Eo '[0-9]+$')"
[[ -n "$EXPECTED_RUNTIME_ABI_VERSION" ]] || fail "could not read MUTANTKIT_V3_RUNTIME_ABI_VERSION from $RUNTIME_ABI_HEADER"

MANIFEST_SWIFT_FILE="$REPO_ROOT/Sources/AppleBuildAdapters/SchemataRuntimeManifest.swift"
EXPECTED_SCHEMA_VERSION="$(grep -Eo 'static let supportedSchemaVersion = [0-9]+' "$MANIFEST_SWIFT_FILE" | grep -Eo '[0-9]+$')"
[[ -n "$EXPECTED_SCHEMA_VERSION" ]] || fail "could not read supportedSchemaVersion from $MANIFEST_SWIFT_FILE"

MANIFEST="$PACKAGE_DIR/lib/mutantkit/schemata/manifest.json"
[[ -f "$MANIFEST" ]] || fail "manifest not found at $MANIFEST"

jq -e . "$MANIFEST" >/dev/null || fail "$MANIFEST is not valid JSON"

jq -e --argjson schemaVersion "$EXPECTED_SCHEMA_VERSION" --argjson abiVersion "$EXPECTED_RUNTIME_ABI_VERSION" '
    (.schemaVersion == $schemaVersion) and
    (.runtimeABIVersion == $abiVersion) and
    (.archives | type == "array") and
    (.archives | length == 2) and
    ([.archives[].platform] | sort == ["iphonesimulator", "macosx"]) and
    all(.archives[];
        (.platform | type == "string") and
        (.path | type == "string") and
        (.sha256 | type == "string") and
        (.sha256 | test("^[0-9a-f]{64}$")) and
        (.architectures | type == "array") and
        ((.architectures | length) > 0) and
        all(.architectures[]; type == "string")
    )
' "$MANIFEST" >/dev/null || fail "$MANIFEST does not match the shape SchemataRuntimeManifest.swift expects (schemaVersion=$EXPECTED_SCHEMA_VERSION, runtimeABIVersion=$EXPECTED_RUNTIME_ABI_VERSION required)"

echo "manifest.json shape OK — schemaVersion=$EXPECTED_SCHEMA_VERSION runtimeABIVersion=$EXPECTED_RUNTIME_ABI_VERSION, both platforms present"
cat "$MANIFEST"

# ── Phase 7/9: per-archive digest + architecture verification ───────────────
section "Phase 7/9: per-archive SHA-256 digest and architecture verification"

verify_archive() {
    local platform="$1" expected_archs_desc="$2"
    local rel_path declared_sha256 abs_path actual_sha256 archs

    rel_path="$(jq -r --arg p "$platform" '.archives[] | select(.platform == $p) | .path' "$MANIFEST")"
    declared_sha256="$(jq -r --arg p "$platform" '.archives[] | select(.platform == $p) | .sha256' "$MANIFEST")"
    [[ -n "$rel_path" && "$rel_path" != "null" ]] || fail "manifest has no archive entry for platform '$platform'"

    abs_path="$PACKAGE_DIR/lib/mutantkit/schemata/$rel_path"
    [[ -f "$abs_path" ]] || fail "$platform archive declared at $rel_path but no file exists at $abs_path"

    actual_sha256="$(shasum -a 256 "$abs_path" | awk '{print $1}')"
    [[ "$actual_sha256" == "$declared_sha256" ]] \
        || fail "$platform archive digest mismatch: manifest declares $declared_sha256, actual is $actual_sha256"
    echo "$platform: sha256 OK ($actual_sha256)"

    archs="$(lipo -archs "$abs_path")"
    echo "$platform: lipo -archs -> $archs"
    case "$platform" in
        macosx)
            echo "$archs" | tr -s ' ' '\n' | grep -qx 'arm64' \
                || fail "macosx archive does not contain an arm64 slice (got: $archs)"
            ;;
        iphonesimulator)
            for arch in arm64 x86_64; do
                echo "$archs" | tr -s ' ' '\n' | grep -qx "$arch" \
                    || fail "iphonesimulator archive is missing the $arch slice (got: $archs), expected $expected_archs_desc"
            done
            ;;
    esac

    # Cross-check lipo's own report against the manifest's own declared
    # (informational-only) architectures list, so a truthful manifest is
    # verified, not merely assumed.
    local manifest_archs actual_archs_sorted
    manifest_archs="$(jq -r --arg p "$platform" '.archives[] | select(.platform == $p) | .architectures | sort | join(",")' "$MANIFEST")"
    actual_archs_sorted="$(echo "$archs" | tr -s ' ' '\n' | sort | paste -sd, -)"
    [[ "$manifest_archs" == "$actual_archs_sorted" ]] \
        || fail "$platform: manifest declares architectures [$manifest_archs] but lipo reports [$actual_archs_sorted]"
}

verify_archive "macosx" "arm64 (host)"
verify_archive "iphonesimulator" "arm64 and x86_64"

# ── Phase 8/9: the critical end-to-end step ──────────────────────────────────
#
# From a temp directory with no relationship to any mutantkit/mutantkit-private/
# mutantkit-f7 checkout, with MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE explicitly
# unset, clone a small pinned real corpus and run the *extracted packaged
# binary* to plan and run at least one real mutation, resolving its schemata
# runtime purely from what it bundles.
section "Phase 8/9: real plan+run against swift-numerics, bundled runtime only"

case "$CORPUS_DIR" in
    */mutantkit-private*|*/mutantkit-f7/*|*/mutantkit/*)
        fail "CORPUS_DIR ($CORPUS_DIR) looks like it is inside a mutantkit checkout — refusing to run there"
        ;;
esac

unset MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE || true
if [[ -n "${MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE:-}" ]]; then
    fail "MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE is still set — this step must prove the bundled path, not the override path"
fi

SWIFT_NUMERICS_URL="https://github.com/apple/swift-numerics.git"
SWIFT_NUMERICS_COMMIT="899af71c0256d0ad181e3b7eb3453c1065d928a5"
CORPUS_REPO_DIR="$CORPUS_DIR/swift-numerics"

echo "Cloning $SWIFT_NUMERICS_URL @ $SWIFT_NUMERICS_COMMIT into $CORPUS_REPO_DIR"
git clone --quiet "$SWIFT_NUMERICS_URL" "$CORPUS_REPO_DIR"
git -C "$CORPUS_REPO_DIR" checkout --quiet "$SWIFT_NUMERICS_COMMIT"

# Budget selection draws from every discovered operator, and roughly a third
# of this catalog (arithmetic-operator-replacement, assignment-operator-
# replacement, else-clause-deletion, nil-coalescing-fallback, range-boundary-
# replacement, side-effect-call-removal) has no registered SchemataLowerer at
# all (see docs/schemata-support-matrix.md's "Operators" table) — always
# isolated, regardless of profile. A first real run against this exact corpus
# hit exactly this: a 3-mutant budget randomly landed entirely on ineligible
# operators, so effectiveCount was 0 even though the bundled runtime itself
# was never at fault. Disabling those operators here means every mutant this
# budget can select is schemata-eligible, so this step actually exercises the
# bundled runtime rather than gambling on the budget sampler's luck.
cat > "$CORPUS_REPO_DIR/mutantkit.yml" <<'EOF'
version: 1
project:
  kind: swiftPackageMacOS
sources:
  include: [Sources/**]
operators:
  profile: experimental
  disable:
    - swift.core.arithmetic-operator-replacement
    - swift.core.assignment-operator-replacement
    - swift.core.else-clause-deletion
    - swift.core.nil-coalescing-fallback
    - swift.core.range-boundary-replacement
    - swift.core.side-effect-call-removal
execution:
  strategy: schemata
  budget:
    maxMutants: 5
reports: [console, json]
EOF

echo
echo "-- mutantkit plan --"
(
    cd "$CORPUS_REPO_DIR"
    "$MUTANTKIT_BIN" plan --output plan.json
) || fail "mutantkit plan failed against swift-numerics"

[[ -f "$CORPUS_REPO_DIR/plan.json" ]] || fail "mutantkit plan did not write plan.json"

echo
echo "-- mutantkit run --"
(
    cd "$CORPUS_REPO_DIR"
    "$MUTANTKIT_BIN" run --plan plan.json --report json
) || fail "mutantkit run failed against swift-numerics"

REPORT="$CORPUS_REPO_DIR/.mutantkit/report.json"
[[ -f "$REPORT" ]] || fail "mutantkit run did not write $REPORT"

jq -e '.baseline.passed == true' "$REPORT" >/dev/null \
    || fail "baseline did not pass — see $REPORT"

jq -e '(.integrity.violations | length) == 0' "$REPORT" >/dev/null \
    || fail "integrity violations present — see $REPORT"

jq -e '.executionStrategy != null and .executionStrategy.requested == "schemata"' "$REPORT" >/dev/null \
    || fail "run did not record a schemata executionStrategy — see $REPORT"

EFFECTIVE_COUNT="$(jq -r '.executionStrategy.effectiveCount' "$REPORT")"
[[ "$EFFECTIVE_COUNT" -gt 0 ]] \
    || fail "executionStrategy.effectiveCount was $EFFECTIVE_COUNT — no mutant actually ran through the schemata backend, only the bundled-runtime *presence* was proven, not its use"

echo
echo "Real mutation run against swift-numerics succeeded via the bundled runtime alone:"
jq '{baseline: .baseline.passed, integrity: (.integrity.violations | length), executionStrategy}' "$REPORT"

# ── Phase 9/9: this checkout's own working tree is left clean ───────────────
section "Phase 9/9: git status --short (must be empty)"

GIT_STATUS_OUTPUT="$(cd "$REPO_ROOT" && git status --short)"
if [[ -n "$GIT_STATUS_OUTPUT" ]]; then
    echo "$GIT_STATUS_OUTPUT" >&2
    fail "this checkout's working tree is not clean after the gate ran"
fi
echo "Working tree clean."

section "Release artifact gate PASSED"
echo "Tarball:       $TARBALL"
echo "Version:       $VERSION"
echo "Commit:        $BUILD_COMMIT_SHA"
echo "Schemata run:  effectiveCount=$EFFECTIVE_COUNT against swift-numerics @ $SWIFT_NUMERICS_COMMIT"
