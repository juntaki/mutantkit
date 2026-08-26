#!/usr/bin/env bash
#
# build-schemata-runtime.sh — cross-compile MutantKitSchemataRuntimeC for the
# iOS Simulator, producing the platform slice `swift build` cannot.
#
# `swift build --build-tests` already produces the macOS archive at
# $(swift build --show-bin-path)/libMutantKitSchemataRuntime.a. That archive is
# macOS-only, so linking it into an iOS-Simulator-targeted chunk fails with
#   ld: building for 'iOS-simulator', but linking in object file ... built for 'macOS'
# This script produces the sibling SchemataRuntimeLibraryLocator looks for
# when resolving `SchemataRuntimePlatform.iOSSimulator`:
#   <output-dir>/iphonesimulator/libMutantKitSchemataRuntime.a
#
# Usage: scripts/build-schemata-runtime.sh [output-dir]
#   [output-dir] defaults to $MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE, else .build/debug
#
# Requires an Xcode installation with the iPhoneSimulator SDK — this is a
# source-checkout-only step. It compiles Sources/MutantKitSchemataRuntimeC
# directly, which a released `mutantkit` binary (scripts/release-build.sh
# ships only the binary and LICENSE, never this source) does not have
# available. There is currently no way to set up iOS-Simulator schemata mode
# starting from a released binary alone; that requires cloning this repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/Sources/MutantKitSchemataRuntimeC"
OUTPUT_DIR="${1:-${MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE:-$REPO_ROOT/.build/debug}}"
DEST="$OUTPUT_DIR/iphonesimulator"

# The real, empirically-measured floor, not a guess: an arm64 iOS-Simulator
# slice cannot go below iOS 14.0 — Apple Silicon simulator support did not
# exist before iOS 14 / Xcode 12, and clang silently clamps a lower
# `-mios-simulator-version-min` up to 14.0 on the arm64 slice specifically
# (verified against this SDK: requesting 12.0/13.0 for -arch arm64 still
# yields `minos 14.0` in the compiled object's LC_BUILD_VERSION; the x86_64
# slice alone would accept a lower value, but a fat archive with two
# different per-slice `minos` values buys nothing and is confusing to
# inspect). 14.0 is therefore the *lowest value that is not a lie*: MutantKit
# does not otherwise declare or validate a minimum iOS deployment target for
# projects it mutates, so picking the lowest true floor — rather than a
# higher round number like 15.0 — maximizes which real projects this archive
# can link into. A static archive's `minos` only needs to be <= the
# consuming project's own deployment target to link cleanly, so a lower
# floor here is strictly safer, never a downgrade.
DEPLOYMENT_TARGET="14.0"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$DEST"

# Both simulator slices in ONE invocation (measured: ~0.4s total on Xcode
# 26.6 / iPhoneSimulator SDK 26.5). x86_64 costs a fraction of a second more
# and covers Intel hosts/CI runners and any project built with
# ONLY_ACTIVE_ARCH=NO; omitting it would fail those links for no saving.
xcrun --sdk iphonesimulator clang \
    -arch arm64 -arch x86_64 \
    -mios-simulator-version-min="$DEPLOYMENT_TARGET" \
    -isysroot "$SDK_PATH" \
    -I "$SRC_DIR/include" \
    -O2 -Wall \
    -c "$SRC_DIR/mutantkit_protocol_v3.c" \
    -o "$DEST/mutantkit_protocol_v3.o"

xcrun libtool -static -o "$DEST/libMutantKitSchemataRuntime.a" \
    "$DEST/mutantkit_protocol_v3.o"

echo "Built: $DEST/libMutantKitSchemataRuntime.a"
lipo -info "$DEST/libMutantKitSchemataRuntime.a"
