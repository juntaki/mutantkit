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
# Also builds and bundles MutantKitSchemataRuntime for every platform this
# release supports (macOS, iOS Simulator) under lib/mutantkit/schemata/,
# alongside a manifest.json SchemataRuntimeLibraryLocator's bundled-runtime
# path (see that type and SchemataRuntimeManifest) validates before linking
# any of them — this is what lets a released binary run schemata mode with
# no source checkout and no MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE at all.
#
# Usage:
#   Scripts/release-build.sh <version> [output-dir]
#
# <version> — e.g. "0.1.0". Do not include a leading "v".
# [output-dir] — defaults to ./dist
#
# Requires: swift toolchain, tar, shasum (macOS default) or sha256sum, and
# (for the iOS-Simulator schemata runtime) an Xcode install with the
# iPhoneSimulator SDK — see Scripts/build-schemata-runtime.sh's own header.

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

echo "swift build -c release --product MutantKitSchemataRuntime"
swift build -c release --product MutantKitSchemataRuntime

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

PACKAGE_NAME="mutantkit-macos-arm64"
PACKAGE_DIR="$(mktemp -d)/$PACKAGE_NAME"
mkdir -p "$PACKAGE_DIR"
cp .build/release/mutantkit "$PACKAGE_DIR/mutantkit"
cp LICENSE "$PACKAGE_DIR/LICENSE"

# --- Bundled schemata runtime -----------------------------------------
#
# SchemataRuntimeManifest.swift and SchemataRuntimeLibraryLocator.swift's
# own `expectedRuntimeABIVersion`/`schemaVersion` are read directly out of
# their source of truth here (the C header, and the Swift manifest type
# itself) rather than duplicated as separate literals in this script — a
# hand-maintained second copy is exactly the kind of drift that would make
# a genuine release silently mismatch the very ABI check it's supposed to
# satisfy.
RUNTIME_ABI_HEADER="Sources/MutantKitSchemataRuntimeC/include/mutantkit_protocol_v3.h"
RUNTIME_ABI_VERSION="$(grep -Eo '#define +MUTANTKIT_V3_RUNTIME_ABI_VERSION +[0-9]+' "$RUNTIME_ABI_HEADER" | grep -Eo '[0-9]+$')"
if [[ -z "$RUNTIME_ABI_VERSION" ]]; then
    echo "error: could not read MUTANTKIT_V3_RUNTIME_ABI_VERSION from $RUNTIME_ABI_HEADER" >&2
    exit 1
fi

MANIFEST_SWIFT_FILE="Sources/AppleBuildAdapters/SchemataRuntimeManifest.swift"
MANIFEST_SCHEMA_VERSION="$(grep -Eo 'static let supportedSchemaVersion = [0-9]+' "$MANIFEST_SWIFT_FILE" | grep -Eo '[0-9]+$')"
if [[ -z "$MANIFEST_SCHEMA_VERSION" ]]; then
    echo "error: could not read supportedSchemaVersion from $MANIFEST_SWIFT_FILE" >&2
    exit 1
fi

SCHEMATA_DIR="$PACKAGE_DIR/lib/mutantkit/schemata"
mkdir -p "$SCHEMATA_DIR/macosx" "$SCHEMATA_DIR/iphonesimulator"
cp .build/release/libMutantKitSchemataRuntime.a "$SCHEMATA_DIR/macosx/libMutantKitSchemataRuntime.a"

# Built into a scratch directory, not straight into $SCHEMATA_DIR: the
# script also leaves its own intermediate .o object file in its output
# directory, which must never end up inside the shipped package.
SIMULATOR_BUILD_DIR="$(mktemp -d)"
echo "Scripts/build-schemata-runtime.sh $SIMULATOR_BUILD_DIR"
Scripts/build-schemata-runtime.sh "$SIMULATOR_BUILD_DIR"
cp "$SIMULATOR_BUILD_DIR/iphonesimulator/libMutantKitSchemataRuntime.a" "$SCHEMATA_DIR/iphonesimulator/libMutantKitSchemataRuntime.a"

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

MACOS_ARCHIVE="$SCHEMATA_DIR/macosx/libMutantKitSchemataRuntime.a"
SIMULATOR_ARCHIVE="$SCHEMATA_DIR/iphonesimulator/libMutantKitSchemataRuntime.a"
MACOS_SHA256="$(sha256_of "$MACOS_ARCHIVE")"
SIMULATOR_SHA256="$(sha256_of "$SIMULATOR_ARCHIVE")"
MACOS_ARCHITECTURES="$(lipo -archs "$MACOS_ARCHIVE" | tr -s ' ' '\n' | sed 's/.*/"&"/' | paste -sd, -)"
SIMULATOR_ARCHITECTURES="$(lipo -archs "$SIMULATOR_ARCHIVE" | tr -s ' ' '\n' | sed 's/.*/"&"/' | paste -sd, -)"

cat > "$SCHEMATA_DIR/manifest.json" <<EOF
{
  "schemaVersion": ${MANIFEST_SCHEMA_VERSION},
  "runtimeABIVersion": ${RUNTIME_ABI_VERSION},
  "archives": [
    {
      "platform": "macosx",
      "path": "macosx/libMutantKitSchemataRuntime.a",
      "sha256": "${MACOS_SHA256}",
      "architectures": [${MACOS_ARCHITECTURES}]
    },
    {
      "platform": "iphonesimulator",
      "path": "iphonesimulator/libMutantKitSchemataRuntime.a",
      "sha256": "${SIMULATOR_SHA256}",
      "architectures": [${SIMULATOR_ARCHITECTURES}]
    }
  ]
}
EOF

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
