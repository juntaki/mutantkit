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
| `5` | `notFullyVerified` | `mutantkit trust` found no mismatch but could not verify every required check (typically because the plan the report names was not found, or because the report's results were verified by an older verifier version than the current one), so it does not call the report trustworthy. Distinct from `2`, which means a check failed. |
| `6` | `qualificationFailed` | `run --require-schemata` asked for a valid schemata measurement and the run did not deliver one: schemata was not requested, the whole run degraded, no mutation executed through schemata, or more mutations fell back to isolated execution than `--max-unexpected-fallbacks` (default `0`) allows. `buildReceiptUnavailable` and `sharedChunkBuildFailure` fallbacks always fail it. Meant for qualification, benchmarks and acceptance tests; ordinary runs should keep tolerating fallback. |
| `7` | `interrupted` | `run` was stopped by `SIGINT`, `SIGTERM` or `SIGHUP`. Finished mutants are in the checkpoint, a report marked partial was written when any mutant had a result, and the exact resume command was printed. Never `0`: the plan was not fully measured. |

`MutantKitExit.onFailure` is the one place that maps an uncaught Swift error
to `operationalError` explicitly, so a plain file-I/O or JSON-decode failure
that reaches the top of a command doesn't fall through to
`ArgumentParser`'s own default failure exit code by accident. An error that
already carries a deliberate `ExitCode` (any of the non-zero codes
above) passes through unchanged.

## Interrupting `run`

With the default `isolated` execution strategy, `SIGINT` (Ctrl-C), `SIGTERM` and
`SIGHUP` stop `mutantkit run` gracefully instead of killing it:

1. **First signal**: no new mutant is started. Mutants already running finish
   (bounded by the mutant timeout) and are checkpointed as usual.
2. **Second signal**: in-flight work is cancelled; the child process trees are
   terminated through the same path a timeout uses. A mutant cut short this way
   is not checkpointed or reported, so it simply runs again on resume.
3. **Third signal**: the process exits immediately. Nothing is lost: every
   finished mutant was already flushed to the checkpoint.

Afterwards `run` writes its usual reports for the mutants that finished, prints
the checkpoint path and the exact command to resume (the command you typed,
without `--no-resume`), and exits with `7`. The report is **partial**:
`report.json` carries an `interruption` object (`signal`, `completedMutants`,
`plannedMutants`), the console and CI-summary reports say "PARTIAL RESULT", and
the report has no score and fails integrity (every unfinished mutant is listed
as a planned mutation without a result), so `gate`, `trust` and `verify-run`
refuse it. A partial run is not recorded to `.mutantkit/history`. A signal that
arrives after the last mutant finished changes nothing: that report is complete.

A signal during the baseline waits for the baseline to finish unless repeated;
the run then stops before starting any mutant. Runs that cannot fingerprint
their inputs (for example outside a git repository) never resume from a
checkpoint, and say so instead of printing a resume command. Other execution
strategies (`schemata`) keep the default signal behaviour for now.

## Re-verifying a finished report: `verify-run` and `trust`

Both commands re-run the verifier's checks over a report instead of believing
what it says about itself. They check internal consistency and
re-derivability, not authenticity: the report is still assumed to be the one
the run produced.

```bash
mutantkit verify-run report.json [--plan plan.json] [--evidence <dir>] [--json]
mutantkit trust --report report.json [--plan plan.json] [--evidence <dir>] [--json]
```

- **Tier A** (always): plan identity, source anchors and recorded source evidence, per-result provenance,
  and a recomputation of the integrity block and the score from the results.
  `--plan` supplies the plan the report was produced from; `trust` also looks
  for it next to the report and in the project root, `verify-run` does not.
  Checks that need the plan are "not verifiable" without it.
- **Tier B** (only with an evidence archive, see `evidence.archive` in
  [configuration](configuration.md)): results are re-judged from the raw
  observations the run archived. `--evidence <dir>` selects an archive; by
  default the one the report records is used. Without an archive the checks
  that need raw observations stay "not verifiable".
- A check that cannot be verified is never counted as passed.

| Command | Result | Exit |
| --- | --- | --- |
| `verify-run` | no check failed, every check passed ("Fully verified") | `0` |
| `verify-run` | no check failed, but some could not be verified (`PARTIAL`; `complete: false` in `--json`) | `0` |
| `verify-run` | a check failed ("MISMATCH") | `2` |
| `verify-run` | report, plan or `--evidence` directory unreadable | `1` |
| `trust` | every required check verified and passed (`trustworthy`) | `0` |
| `trust` | a check failed, or the stored integrity did not pass (`mismatch`) | `2` |
| `trust` | nothing failed but a required check could not be verified (`notFullyVerified`) | `5` |

`verify-run` exits `0` for a partial verification, so a script that needs a
full one must read `complete` from `--json` (or the text line `Fully verified`)
rather than the exit code alone. `trust` is the fail-closed one: a report is
`trustworthy` only when every required check was re-verified. A report whose
results were judged by an older MutantKit verifier version than the current
one can never be `trustworthy`: it exits `5` with "produced by an older
verifier", and a fresh run is the way out. The `--json` shapes are in
[json-output-contracts](json-output-contracts.md).

## stdout vs. stderr

**Diagnostics go to stderr. On a `--json` invocation, the `--json` document
is the only thing written to stdout.** An agent parsing `--json` output must
never be handed prose on a path it did not anticipate — this is stated
directly in `Sources/CLI/JSONOutput.swift`'s own doc comment, and is the
reason `JSONOutput.emitError` exists: a command that cannot proceed still
emits exactly one JSON document (a `JSONErrorEnvelope`), not an uncaught
error that prints to stdout or stderr as unstructured text.

Every diagnostic in `Sources/CLI` that is printed before a `throw ExitCode`
goes to stderr; separate developer tools are not part of this contract. Treat
"diagnostics to stderr" as a checked, call-site-verified invariant for this
command's own diagnostics, not just an intended one.

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
