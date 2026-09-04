# Provenance: `stryker-v1.7.json`

Vendored, byte-for-byte, from the upstream Stryker `mutation-testing-elements`
project — the same project whose viewer `StrykerReporter.swift` targets. Not
authored by MutantKit; do not hand-edit. This exists so
`StrykerReporterTests.swift` can validate a real `StrykerReporter` export
against the real, official schema without a network fetch at test time.

- Upstream file: `packages/report-schema/src/mutation-testing-report-schema.json`
- Repository: https://github.com/stryker-mutator/mutation-testing-elements
- Tag fetched: `v1.7.14` — the last release on the `1.x` line before the
  project's `2.0.0` schema break. Pinned to `1.x`, not `master`, because
  `StrykerReporter.schemaVersion` claims `"1.7"`; validating against a later
  schema would silently grade our own claim against the wrong contract. (As
  of this fetch, `master`'s copy differs from `v1.7.14`'s only in the
  `schemaVersion` pattern, which now also accepts major version `2`, and in
  one added `MutantStatus` enum case, `"Pending"`, that the `1.x` line never
  had — see the source URL below for the exact three-line diff.)
- Source URL:
  https://raw.githubusercontent.com/stryker-mutator/mutation-testing-elements/v1.7.14/packages/report-schema/src/mutation-testing-report-schema.json
- Fetched: 2026-09-03.

If `StrykerReporter.schemaVersion` is ever bumped past `"1.7"`, re-vendor from
the matching upstream tag and update this note — the same discipline
`Schema/mutantkit-v1.json` gets from `ConfigurationSchemaParityTests`, applied
to a schema this repo doesn't author.
