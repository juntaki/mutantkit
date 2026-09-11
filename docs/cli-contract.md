# CLI contract

The exit-code, `--json`, and stdout/stderr rules every `mutantkit` subcommand
is meant to follow. This is a contract in the sense that CI depends on it —
not aspirational prose. See [docs/json-output-contracts.md](json-output-contracts.md)
for the shape of each `--json` document itself.

## Exit codes

Defined once, in `Sources/CLI/MutantKit.swift`'s `MutantKitExit`, and reused
everywhere rather than improvised per command:

| Code | Name | Meaning |
| --- | --- | --- |
| `0` | `success` | The run completed and its results are trustworthy. A surviving mutant does **not** make this non-zero by default — a survivor is a finding, not a tool failure. |
| `1` | `operationalError` | The tool could not do its job: bad config, unreadable plan, no project found, bad CLI input. |
| `2` | `integrityFailure` | The run happened but its own invariants did not reconcile, so no score was produced. Kept distinct from `operationalError` because the difference matters to whoever reads the CI log — this is "the evidence doesn't add up," not "the tool crashed." |
| `3` | `survivorsFound` | Mutants survived and the caller asked for that to fail the build (e.g. `run --fail-on-survivors`). |
| `4` | `qualityGateFailure` | A trusted report missed an explicit CI mutation-quality threshold (`mutantkit gate`). |

`MutantKitExit.onFailure` is the one place that maps an uncaught Swift error
to `operationalError` explicitly, so a plain file-I/O or JSON-decode failure
that reaches the top of a command doesn't fall through to
`ArgumentParser`'s own default failure exit code by accident. An error that
already carries a deliberate `ExitCode` (any of the four non-zero codes
above) passes through unchanged.

## stdout vs. stderr

**Diagnostics go to stderr. On a `--json` invocation, the `--json` document
is the only thing written to stdout.** An agent parsing `--json` output must
never be handed prose on a path it did not anticipate — this is stated
directly in `Sources/CLI/JSONOutput.swift`'s own doc comment, and is the
reason `JSONOutput.emitError` exists: a command that cannot proceed still
emits exactly one JSON document (a `JSONErrorEnvelope`), not an uncaught
error that prints to stdout or stderr as unstructured text.

This is now audited exhaustively, not just mostly-enforced: every bare
`print(...)`-then-`throw ExitCode` diagnostic in `Sources/CLI` (the `mutantkit`
CLI itself — this does not extend to the separate `BenchmarkRunner` developer
tool, which is not part of this contract) routes to `FileHandle
.standardError` as of the v0.5 Stable Contracts pass. That covers
`OperatorCatalogCommand`, `NextCommand`, `FixPlanCommand`,
`OverrideOptions.apply` in `MutantKit.swift` (shared by five commands'
`--profile`/`--execution-profile` validation), `ConfigurationPreflight`,
`DoctorCommand`, `ExecutionProfileCommand`, `InspectCommand`, `DryRunCommand`,
`InitCommand`, `RunCommand` (including a same-shape instance the original
audit's grep missed, alongside the three it found), `PlanCommand`,
`ReproduceCommand`, `MigrateCommand`, `RunCommand+Reports`, `SetupCommand`,
and `RunCommand+DependencyResolutionPreflight`. A follow-up sweep re-grepped
every `print(...)` within three lines of a `throw ExitCode` across all of
`Sources/CLI` and found none left unconverted. Treat "diagnostics to stderr"
as a checked, call-site-verified invariant for this command's own diagnostics,
not just an intended one.

## `--json` vs. `--format agent`

These are two different, orthogonal things:

- **`--json`**: machine-readable JSON, described in
  [docs/json-output-contracts.md](json-output-contracts.md). Every
  `--json`-supporting command checks this flag first; when it is set, no
  other output format applies.
- **`--format agent`**: a *plain-text*, not JSON, terser rendering aimed at
  an LLM reading the command's output directly — available on `fix-plan` and
  `next` only. It exists because the default human-readable text output is
  verbose (headers, spacing, prose framing) in ways that cost tokens without
  adding information an agent needs; `--format agent` strips that framing
  down to the same facts in a denser layout. It is not a JSON encoding and
  is not covered by the schema-version/compatibility rules in
  `docs/json-output-contracts.md`.

Both flags exist on `fix-plan`/`next`; `--json` wins if both would apply
(each command validates `format` — only `nil` or `"agent"` are accepted —
before branching on `json`, and the `json` branch returns before `format` is
ever consulted). `--format` on any other command, or any value other than
`agent`, is rejected as an operational error (JSON-enveloped under `--json`,
printed to stderr otherwise).
