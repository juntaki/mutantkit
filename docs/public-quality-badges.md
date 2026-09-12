# Public quality/supply-chain signals

MutantKit's own `merge-gate` (`.github/workflows/ci.yml`) is the actual
release gate — every job it requires must succeed, no exceptions. The
services on this page are external, informational signals a visitor sees
alongside that gate (via a badge, a dashboard, or a scorecard run against
the public repo). None of them block a merge or a release today. This page
exists so a real ERROR/gap on one of them reads as "known, disposition
recorded" rather than "unnoticed" — the same standard this project holds
its own known-issues to.

## Codecov

Project + patch coverage, uploaded from the same `lcov.info` the `unit`
job's own coverage-lane comment describes generating once per CI run.
`informational: true` on both statuses — not yet wired as a blocking
check, and `main` is not branch-protected on it. Coverage as of the
v1.0.0 cycle: **76.13%** project-wide.

## SonarCloud

Runs static analysis (bugs, vulnerabilities, duplication, security
hotspots) against every push/PR. `continue-on-error: true` in `ci.yml`,
and not part of `merge-gate` — a Sonar outage or a missing `SONAR_TOKEN`
never blocks a merge.

**Known gap, not yet fixed:** SonarCloud's own Quality Gate on this
project currently reports `ERROR`, but not for a code-quality reason —
Bugs, Vulnerabilities, and Security Hotspots are all clean; the failing
condition is a **New Code coverage** threshold (default "Sonar way" gate,
80%) that Sonar cannot evaluate because it never receives coverage data at
all (`0.0%` reported, not a real low measurement). `sonar-project.properties`
documents why: SwiftPM's `llvm-cov`-produced `lcov.info` is fed to Codecov
directly, but SonarCloud's Swift analyzer has no first-party lcov importer,
and wiring a converted "Generic Test Coverage" XML report was deliberately
left undone rather than shipped silently broken.

Disposition: fix, not ignore — the plan is to convert the same
`lcov.info` already produced for Codecov into Sonar's Generic Coverage XML
format and wire `sonar.coverageReportPaths` to it, so Sonar's own gate
reflects the same real, measured coverage Codecov already reports rather
than an artifact of missing data. Tracked as a real fix because an
externally-visible quality dashboard that reads "ERROR" for a reason that
has nothing to do with code quality is exactly the kind of confusing
signal this page exists to prevent — not merely a cosmetic badge concern.

## OpenSSF Scorecard

Supply-chain posture, scored dimension by dimension against the public
repo. One real, actionable finding closed during the v1.0.0 cycle:

- **Binary-Artifacts.** `Tests/MutantKitTests/Fixtures/macho-test-binary`
  was a checked-in, opaque Mach-O binary used by `MachOCodeHashTests`/
  `TestProductHasherTests` as a "real enough" binary to hash. Replaced
  with `MinimalMachO` (`Tests/MutantKitTests/Support/MinimalMachO.swift`),
  a hand-assembled, minimal-but-valid arm64 Mach-O built entirely from
  Swift source at test time — every byte is visible in a diff, reviewable,
  and reproducible, rather than living in a binary blob no code review
  meaningfully inspects. This was already partially true before this
  fix: `MachOCodeHashTests`' own linkage tests
  (`differentIndirectSymbolBindingChangesTheHash` and its siblings)
  already used a predecessor of this exact generator, because the checked-
  in fixture could not prove "identical `__text`, different indirect-symbol
  binding" on demand. Extending it to replace the checked-in binary
  entirely, rather than leaving the two approaches side by side, was the
  more consistent fix — not a change made only to move a score.

Other Scorecard dimensions (branch protection, dangerous workflow
patterns, token permissions, dependency pinning) are tracked as ordinary
engineering backlog, not duplicated here — this page is specifically for
gaps that could otherwise read as unnoticed rather than deliberately
dispositioned.
