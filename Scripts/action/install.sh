#!/usr/bin/env bash
#
# install.sh — the entire effect of the repo-root action.yml's `mode: install`
# path (and the first phase of `mode: ci`): resolve which release to install,
# download it (or substitute a test binary — see MUTANTKIT_ACTION_TEST_BINARY_DIR
# below), verify it, put it on PATH, and report the installed version.
#
# Extracted out of action.yml into its own script for exactly one reason: it
# is the one piece of the Action that a smoke test cannot exercise against a
# binary built from the exact commit under test (see orchestrate-ci.sh's own
# doc comment for why CI-mode orchestration *can* — this step's whole job is
# downloading a *published* release, and the commit under test has not been
# released yet). MUTANTKIT_ACTION_TEST_BINARY_DIR below is the seam that lets
# a smoke test still exercise every *other* line of this script (platform
# check, PATH wiring, single-line version output) without a real release.
#
# Inputs (environment variables, set by action.yml):
#   MUTANTKIT_ACTION_VERSION_INPUT  — inputs.version, "" if not set explicitly.
#   MUTANTKIT_ACTION_REF             — github.action_ref (empty for `uses: ./`
#                                       or a branch ref like `uses: ...@main`).
#   MUTANTKIT_ACTION_GH_TOKEN        — token for `gh attestation verify`
#                                       (inputs.attestation-token, falling back
#                                       to github.token — resolved by action.yml).
#   MUTANTKIT_ACTION_TEST_BINARY_DIR — INTERNAL/TEST-ONLY. When set, this
#                                       directory's own `mutantkit` binary is
#                                       used verbatim: no download, no checksum,
#                                       no attestation verification. Exists so
#                                       action-smoke-test.yml's CI-mode job can
#                                       exercise doctor/plan/run/gate against a
#                                       binary built from the exact PR HEAD
#                                       under test, which has no published
#                                       release to download. Never set this in
#                                       a real consumer workflow — it is not a
#                                       documented, supported input, and
#                                       bypasses every integrity check this
#                                       script otherwise performs.
#
# Outputs: appends to $GITHUB_PATH and $GITHUB_OUTPUT exactly as the
# composite action's own `outputs.version` documents.
set -euo pipefail

os="$(uname -s)"
arch="$(uname -m)"
if [ "$os" != "Darwin" ] || [ "$arch" != "arm64" ]; then
  echo "::error::juntaki/mutantkit only ships a macOS arm64 binary (got $os/$arch). Run this action on a macos-* Apple Silicon runner (e.g. macos-14 or macos-15)." >&2
  exit 1
fi

install_dir="$RUNNER_TEMP/mutantkit-install"
mkdir -p "$install_dir"

if [ -n "${MUTANTKIT_ACTION_TEST_BINARY_DIR:-}" ]; then
  echo "::warning::MUTANTKIT_ACTION_TEST_BINARY_DIR is set — using a local test binary instead of downloading a release. This must never happen in a real consumer workflow."
  bin_dir="$install_dir/mutantkit-macos-arm64"
  mkdir -p "$bin_dir"
  cp "$MUTANTKIT_ACTION_TEST_BINARY_DIR/mutantkit" "$bin_dir/mutantkit"
  chmod +x "$bin_dir/mutantkit"
else
  # Precedence (P13 review, item 2): an explicit `inputs.version` always wins.
  # Otherwise, a `uses: juntaki/mutantkit@vX.Y.Z` tag pin resolves to that
  # exact release, so pinning the Action ref also pins the binary version —
  # without this, `version: default: "latest"` would let a pinned Action ref
  # silently install tomorrow's binary. Only a ref that is not itself a
  # release tag (`uses: ./`, `uses: ...@main`) falls back to the floating
  # `latest` release, and says so out loud rather than silently.
  version="$MUTANTKIT_ACTION_VERSION_INPUT"
  if [ -z "$version" ]; then
    if [[ "$MUTANTKIT_ACTION_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
      version="$MUTANTKIT_ACTION_REF"
      echo "No version input given — installing $version, the release this Action was invoked at (\`uses: .../mutantkit@$version\`)."
    else
      version="latest"
      echo "::warning::No version input given and this Action was not invoked at a release tag (ref: '${MUTANTKIT_ACTION_REF:-<none>}') — falling back to the floating 'latest' release. Pin \`with: version:\` for a reproducible build."
    fi
  fi

  if [ "$version" = "latest" ]; then
    base_url="https://github.com/juntaki/mutantkit/releases/latest/download"
  else
    base_url="https://github.com/juntaki/mutantkit/releases/download/${version}"
  fi

  (
    cd "$install_dir"
    curl -fLO "$base_url/mutantkit-macos-arm64.tar.gz"
    curl -fLO "$base_url/SHA256SUMS"
    shasum -a 256 -c SHA256SUMS

    # SHA256SUMS only proves the tarball matches what was published — it says
    # nothing about who published it. Restricted to `--repo juntaki/mutantkit`
    # *and* `--signer-workflow` naming this repo's own release workflow: proves
    # this tarball was built by juntaki/mutantkit's own release.yml, from a
    # specific commit, not merely that the bytes match a same-named file an
    # attacker controlling the download path could equally have supplied.
    echo "Verifying build provenance attestation…"
    GH_TOKEN="$MUTANTKIT_ACTION_GH_TOKEN" gh attestation verify mutantkit-macos-arm64.tar.gz \
      --repo juntaki/mutantkit --signer-workflow juntaki/mutantkit/.github/workflows/release.yml
    GH_TOKEN="$MUTANTKIT_ACTION_GH_TOKEN" gh attestation verify SHA256SUMS \
      --repo juntaki/mutantkit --signer-workflow juntaki/mutantkit/.github/workflows/release.yml

    tar xzf mutantkit-macos-arm64.tar.gz
  )
fi

bin_dir="$install_dir/mutantkit-macos-arm64"
echo "$bin_dir" >> "$GITHUB_PATH"

# `mutantkit --version` is deliberately multi-line (see Sources/CLI/Version.swift
# — build identity, Swift/Xcode/schema versions, one per line). `outputs.version`
# is documented as a single value, and $GITHUB_OUTPUT's plain `key=value` line
# format cannot carry an embedded newline — writing the raw multi-line string
# there produces a malformed output file the runner rejects outright. `head -n1`
# is the fix: the first line alone (e.g. "mutantkit 0.1.0-dev") is exactly the
# plain version string every consumer of `outputs.version` actually wants.
full_version="$("$bin_dir/mutantkit" --version)"
installed_version="$(printf '%s\n' "$full_version" | head -n1)"
if [ -z "$installed_version" ]; then
  echo "::error::mutantkit --version produced no output" >&2
  exit 1
fi
echo "version=$installed_version" >> "$GITHUB_OUTPUT"
echo "Installed $installed_version"
