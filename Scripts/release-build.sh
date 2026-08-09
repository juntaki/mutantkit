#!/usr/bin/env bash
#
# release-build.sh — build a release `mutantkit` binary with a real version
# and commit SHA embedded, and package it exactly as an end user downloads
# it: a tarball plus a SHA256SUMS file, no repo checkout required to use it.
#
# Sources/CLI/Version.swift documents this itself: "The placeholders are
# substituted by the release script" — this is that script. It edits
# Version.swift in place, builds, packages, then reverts the edit so the
# working tree is never left with a stamped version.
#
# Usage:
#   Scripts/release-build.sh <version> [output-dir]
#
# <version> — e.g. "0.1.0". Do not include a leading "v".
# [output-dir] — defaults to ./dist
#
# Requires: swift toolchain, tar, shasum (macOS default) or sha256sum.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:?usage: scripts/release-build.sh <version> [output-dir]}"
OUTPUT_DIR="${2:-dist}"
COMMIT_SHA="$(git rev-parse HEAD)"
VERSION_FILE="Sources/CLI/Version.swift"

if [[ "$VERSION" == v* ]]; then
    echo "error: pass the version without a leading 'v' (got '$VERSION')" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain "$VERSION_FILE")" ]]; then
    echo "error: $VERSION_FILE already has uncommitted changes; refusing to stamp over them" >&2
    exit 1
fi

restore_version_file() {
    git checkout -- "$VERSION_FILE"
}
trap restore_version_file EXIT

echo "Stamping $VERSION_FILE: version=$VERSION commit=$COMMIT_SHA"
sed -i '' \
    -e "s/public static let version = \".*\"/public static let version = \"${VERSION}\"/" \
    -e "s/public static let commitSHA: String? = nil/public static let commitSHA: String? = \"${COMMIT_SHA}\"/" \
    "$VERSION_FILE"

echo "swift build -c release --product mutantkit"
swift build -c release --product mutantkit

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

PACKAGE_NAME="mutantkit-macos-arm64"
PACKAGE_DIR="$(mktemp -d)/$PACKAGE_NAME"
mkdir -p "$PACKAGE_DIR"
cp .build/release/mutantkit "$PACKAGE_DIR/mutantkit"
cp LICENSE "$PACKAGE_DIR/LICENSE"

TARBALL="$OUTPUT_DIR/${PACKAGE_NAME}.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$PACKAGE_DIR")" "$PACKAGE_NAME"

(
    cd "$OUTPUT_DIR"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${PACKAGE_NAME}.tar.gz" > SHA256SUMS
    else
        sha256sum "${PACKAGE_NAME}.tar.gz" > SHA256SUMS
    fi
)

echo
echo "Built: $TARBALL"
echo "Checksums:"
cat "$OUTPUT_DIR/SHA256SUMS"
