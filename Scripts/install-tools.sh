#!/usr/bin/env bash
# Install the exact tool artifacts pinned in Scripts/tool-versions.env.
#
# Usage: Scripts/install-tools.sh [--prefix DIR] TOOL...
#   TOOL: swiftlint | swiftformat | swift-complexity | xcodegen
#   --prefix DIR  install into DIR/bin (default: $HOME/.local; CI: /usr/local)
#
# Each artifact is downloaded, verified against its pinned sha256, installed,
# and its reported version must equal the pin -- any mismatch fails. Nothing
# is installed from a package manager's "latest". The same script serves CI
# and local use, so both run the same bytes. Artifacts are macOS arm64.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/tool-versions.env"

prefix="$HOME/.local"
tools=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) prefix="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; exit 2 ;;
        *) tools+=("$1"); shift ;;
    esac
done
[[ ${#tools[@]} -gt 0 ]] || { echo "error: no tool named (see --help)" >&2; exit 2; }
[[ "$(uname -s)-$(uname -m)" == "Darwin-arm64" ]] || {
    echo "error: pinned artifacts are macOS arm64 only (this host: $(uname -s)-$(uname -m))" >&2; exit 1; }

bin="$prefix/bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$bin"

fetch() { # url sha256 dest
    curl -fsSL --retry 3 -o "$3" "$1"
    local got
    got="$(shasum -a 256 "$3" | awk '{print $1}')"
    [[ "$got" == "$2" ]] || { echo "error: sha256 mismatch for $1 (expected $2, got $got)" >&2; exit 1; }
}

verify() { # tool expected-version actual-output
    [[ "$3" == "$2" ]] || { echo "error: installed $1 reports '$3', pinned '$2'" >&2; exit 1; }
    echo "installed $1 $2 -> $bin"
}

for tool in "${tools[@]}"; do
    d="$work/$tool"; mkdir -p "$d"
    case "$tool" in
        swiftlint)
            fetch "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" "$SWIFTLINT_SHA256" "$d/a.zip"
            unzip -q -o "$d/a.zip" swiftlint -d "$d"
            install -m 755 "$d/swiftlint" "$bin/swiftlint"
            verify swiftlint "$SWIFTLINT_VERSION" "$("$bin/swiftlint" version)" ;;
        swiftformat)
            fetch "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip" "$SWIFTFORMAT_SHA256" "$d/a.zip"
            unzip -q -o "$d/a.zip" swiftformat -d "$d"
            install -m 755 "$d/swiftformat" "$bin/swiftformat"
            verify swiftformat "$SWIFTFORMAT_VERSION" "$("$bin/swiftformat" --version)" ;;
        swift-complexity)
            fetch "https://github.com/fummicc1/swift-complexity/releases/download/v${SWIFT_COMPLEXITY_VERSION}/SwiftComplexityCLI-${SWIFT_COMPLEXITY_VERSION}-macos-arm64.tar.gz" "$SWIFT_COMPLEXITY_SHA256" "$d/a.tar.gz"
            tar -xzf "$d/a.tar.gz" -C "$d"
            install -m 755 "$d"/SwiftComplexityCLI-*/SwiftComplexityCLI "$bin/swift-complexity"
            verify swift-complexity "$SWIFT_COMPLEXITY_VERSION" "$("$bin/swift-complexity" --version)" ;;
        xcodegen)
            fetch "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" "$XCODEGEN_SHA256" "$d/a.zip"
            unzip -q -o "$d/a.zip" -d "$d"
            # xcodegen locates SettingPresets via ../share/xcodegen relative to its bin/.
            mkdir -p "$prefix/share"
            rm -rf "$prefix/share/xcodegen"
            cp -R "$d/xcodegen/share/xcodegen" "$prefix/share/xcodegen"
            install -m 755 "$d/xcodegen/bin/xcodegen" "$bin/xcodegen"
            verify xcodegen "$XCODEGEN_VERSION" "$("$bin/xcodegen" --version | sed 's/^Version: //')" ;;
        *) echo "error: unknown tool '$tool'" >&2; exit 2 ;;
    esac
done
