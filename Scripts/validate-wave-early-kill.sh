#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export MUTANTKIT_ACCEPTANCE=1
export MUTANTKIT_ACCEPTANCE_SIMULATOR=1
export MUTANTKIT_WAVE_ACCEPTANCE=1

swift build --build-tests
swift test --filter XcodeWaveEarlyKillAcceptanceTests
