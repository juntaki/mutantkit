# Archived benchmark workflows

These workflows are historical, manual research harnesses retained for reproducibility. They were moved out of `.github/workflows/` after their one-off validation phases completed so they no longer appear as live GitHub Actions workflows or consume CI attention.

The active public automation surface is intentionally small:

- `.github/workflows/ci.yml` — push/PR correctness gates
- `.github/workflows/codeql.yml` — security analysis
- `.github/workflows/release.yml` — release packaging and publication
- `.github/workflows/action-smoke-test.yml` — periodic composite-action smoke test

To rerun an archived benchmark, copy the specific workflow back into `.github/workflows/` on a temporary branch, pin/review its toolchain assumptions, run it manually, and remove it again afterward. Do not treat these archived files as continuously supported CI.
