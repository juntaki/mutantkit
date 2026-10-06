# JSON output contracts

Every machine-readable artifact and `--json` command output MutantKit
produces, its schema version, and the compatibility rules that apply to all
of them. See [docs/cli-contract.md](cli-contract.md) for the surrounding
exit-code/stdout/stderr contract.

## Compatibility rule

**A new optional field is non-breaking. A new required field, or a removed,
renamed, or retyped field, is breaking.** This has been the lived practice
throughout this codebase's history — every schema-version bump on record
(e.g. `schemataPlan` going from 1 to 2 for ADR-0005 PR F, when
`SchemataPlacement.embedded` changed from a flat set of fields to a list of
per-target placements) corresponds to exactly this kind of incompatible
change, and every other addition (`RunReport.batchExecution`,
`executionStrategy`, `operationalIssues`, all added after `RunReport`
shipped) is an `Optional`/defaulted field a reader can ignore. It was never
written down as a rule until now.

**Unknown fields are always ignored on decode.** MutantKit's `Codable`
types use Swift's synthesized or straightforward hand-written
`init(from:)` implementations, none of which reject a JSON object for
carrying an extra key — the same "ignore what you don't recognize" policy
`docs/configuration.md` documents for `mutantkit.yml` itself. A field a
future version adds and an older reader doesn't know about is silently
skipped, not an error.

**A `schemaVersion` mismatch is a different case, and fails closed.**
`schemaVersion` is not "ignore if unknown" — it is the signal that the rest
of the document might not decode the way the reader expects, and readers
that check it (`MutationPlan.decode(from:)`, `RunReport.decode(from:)`)
throw rather than guess. Not every type checks its own `schemaVersion` at
decode time today; where a reader path doesn't check it, that is a decoding
convenience, not a claim that a version mismatch there is safe.

## Registry

Every constant below is declared in `Sources/MutationModel/CoreTypes.swift`,
`SchemaVersion`. "Top-level shape" is either a JSON *object* carrying a
document-level `schemaVersion` field, or a bare JSON *array* whose elements
each carry their own `schemaVersion` — see
[Array-vs-object exception](#array-vs-object-exception) below.

| Constant | Value | Produced by | Top-level shape |
| --- | --- | --- | --- |
| `plan` | 1 | `plan.json` (written by `mutantkit plan`/`run`/`dry-run`) | object |
| `result` | 1 | `report.json` (written by `mutantkit run`), a.k.a. `RunReport` | object |
| `schemataPlan` | 2 | The schemata-mode execution plan (`SchemataPlan`), internal to schemata execution | object |
| `agentEvidenceReport` | 1 | `mutantkit inspect --json` (`AgentEvidenceReport`) | object |
| `runHistoryRecord` | 1 | `mutantkit history --json` (`RunHistoryRecord`) | **bare array**, per-element `schemaVersion` |
| `operatorCatalogEntry` | 1 | `mutantkit operator-catalog --json` (`OperatorCatalogEntry`) | **bare array** with no operator ID given (per-element `schemaVersion`); a single **object** when an operator ID is given |
| `qualityGateResult` | 1 | `mutantkit gate --json` (`QualityGateResult`) | object |
| `buildDiagnosis` | 1 | `mutantkit doctor --json` (`BuildDiagnosis`) | object |
| `configurationValidationResult` | 1 | `mutantkit config --json` (`ConfigurationValidationResult`) | object |
| `trustReport` | 1 | `mutantkit trust --json` (`TrustReport`) | object |
| `testObligationFixPlan` | 1 | `mutantkit fix-plan --json` (`TestObligationFixPlan`) | object |
| `nextFixRecommendation` | 1 | `mutantkit next --json` (`NextFixRecommendation`) | object |
| `verifyResult` | 1 | `mutantkit verify --json` (`VerifyResult`) | object |
| `verifyRunResult` | 1 | `mutantkit verify-run --json` (`VerifyRunResult`) | object |
| `commandError` | 1 | Every `--json`-supporting command's failure path (`JSONErrorEnvelope`) | object |

`trust --json` carries an optional `verification` object (the re-verification
`trust` runs internally: `planSupplied`, `planSource`, `planPath`, `passCount`,
`failCount`, `notVerifiableCount`, `unverifiedRequiredChecks`, `checks`).
`trustworthy` is fail-closed: `true` only when the stored `integrity.passed` is
true, no check failed, and every required check (`report.results`,
`plan.identity`, `plan.mutationIDs`, `result.identity`, `result.provenance`,
`integrity.recompute`, `score.recompute`) was verifiable and passed. The new
`trustStatus` says which case applies: `trustworthy`, `mismatch` (a check
failed, or the stored integrity did not pass; exit code `2`) or
`notFullyVerified` (nothing failed but a required check could not be verified,
named in `verification.unverifiedRequiredChecks`; exit code `5`). Without
`--plan`, `trust` first looks for a `plan.json` with the report's `planID` next
to the report and in the project root; if none is found, the plan-dependent
checks are not verifiable and a clean report is `notFullyVerified`, never
`trustworthy`. A mismatch outranks `notFullyVerified`. A report whose results were verified by an
older verifier version than the current one is also `notFullyVerified` (exit
code `5`), even with `--plan`: `result.provenance` is then not verifiable,
because a report cannot be re-judged without its observations. The required
checks are not relaxed for it; `trust` prints "report was produced by an older
verifier" with the versions and says to re-run for a verifiable report.
`trustworthy` therefore means "every required check re-verified". That is a
semantic tightening of the existing key: a report that earlier versions called
trustworthy can now be `false` when it carries older-verifier results. `planSource` is
`supplied`, `discovered` or `none`. Not-verifiable checks are never counted as
passed. `score` is withheld on a `mismatch`; on `notFullyVerified` it is the
stored value and unverified. Existing keys are unchanged.

`verify-run --json` and `trust --json`'s `verification` object carry
`complete`, an additive boolean that is `true` only when every check passed:
none failed and none is not verifiable. `passed` keeps its meaning (no check
failed), so `passed: true, complete: false` is a PARTIAL verification, and the
`verify-run` text output ends with `PARTIAL: ...` instead of
`Fully verified: every check passed.` A partial report must never be read as
fully verified.

`verify-run --json` and `trust --json` report `tierBPerformed: true` only when
an evidence archive (written by a run with `evidence.archive: true`) was read
and at least one result was re-judged from its raw observations under the
confirmation policy the run recorded; a `tierB` object then gives the counts.
`report.json` gains an optional `evidenceArchive` (`runID`, `manifestHash`,
`entryCount`); `--evidence <dir>` selects an archive explicitly. Without an
archive both commands behave as before and results that need raw observations
stay not verifiable. The archive's hashes show an edited archive is not the one
the run wrote; they are not a signature.

Tier B is a consistency check with two explicit limits. An archive passed with
`--evidence` for a report that records no `evidenceArchive` is an unbound
archive: only its own consistency is checked (`archive.binding` is not
verifiable), nothing is re-judged from it and `tierBPerformed` stays `false`.
And the confirmation policy Tier B re-judges under is read from the archive's
own manifest. When a project configuration whose `configurationHash` equals the
plan's is available, the policy it implies is compared with the manifest's and a
disagreement fails `archive.policy`; otherwise `archive.policy` is not
verifiable ("policy taken from the archive itself, not independently bound").
No Tier B check is among the required checks, so a Tier B pass never makes a
report `trustworthy` on its own.

`trust --json` also carries an optional `killEvidence` object counting how
the assertion kills were credited (`withinSelection`, `wholeSuiteRan`,
`failingTestsUnnamed`, `attributionNotRecorded`, `batchAttributed`) and how many
results went through more than one confirmation round
(`cascadeConfirmations`). In `report.json`, a result's `evidence` may carry
`assertionKillAttribution` and `confirmationChain`, both optional and both
written only by the verifier; a result without them is never read as one whose
kill stayed inside its test selection. A verifier version bump (13) means a
cached or checkpointed assertion kill whose observation recorded no test
execution is re-verified and is no longer credited as a kill.

With `retestKilledMutants` on, a confirmed assertion kill's
`assertionKillConfirmation` also carries an optional `control` (`status`:
`passedOnBaseline`, `failedOnBaseline` or `notEstablished`, the `method`, the
control run's status and failing tests): the unmutated build run against the
same tests. A kill is confirmed only with `passedOnBaseline`; a failing control
makes the result `flaky` (disposition `baselineControlFailed`) and a missing or
unusable one makes it `infrastructureFailure` (`baselineControlNotEstablished`).
A record without `control` is unknown, never controlled, and `verify-run`
reports it as not verifiable (older result) or failed (current rules). The
evidence archive stores the control run with the observations, so Tier B
re-derives the same status. A verifier version bump (14) means an older cached
or checkpointed kill is re-verified and, lacking a control, is no longer
credited as a kill.

Whether a failing test lies inside the run's selection is decided from the full
test identifier (target, suites, type, method and parameter list), not its last
two path components: a failing test that only shares a type and method name
with a selected one (another target or enclosing suite, another overload or
parameterized variant) is not inside the selection. A tolerated difference is
only decoration (a trailing `()`, a missing target or suite prefix, a module
prefix on the type). The kill then becomes `infrastructureFailure` with
`assertionKillAttribution.disposition` `outsideSelection` and the names in
`unmatchedFailingTests`, visible in `trust`'s `killEvidence`. A verifier version
bump (15) means an older cached kill is re-verified under this rule. Version
16 reads a Swift Testing selection recorded with a doubled trailing `()` as the
same test.

Every result records the `verificationVersion` of the verifier that judged it.
A cached result from an earlier version is never served: the cache treats it as
a miss and the mutant is run again. A resumed checkpoint is re-judged from its
raw observations under the current rules, never taken as stored. A result in a
finished report keeps the version it was judged under, which is why `trust`
cannot call an older report `trustworthy` (exit code `5`) and a fresh run is
needed. None of this changes a stored report's contents or can produce a wrong
result: the worst case is a re-run.

Two more `--json` outputs exist outside this registry, both intentionally:

- `mutantkit survivors --json` (`SurvivorActionabilityReport`) has **no
  `schemaVersion` field at all** — it was never added to this type. Treat it
  as an accepted gap, not a hidden inconsistency to work around: a consumer
  of `survivors --json` cannot version-gate on this field the way every
  other command's output allows.
- `mutantkit inspect --json` on its not-found path (`InspectCommand.ErrorJSON`)
  — see [Legacy exception](#legacy-exception-inspects-errorjson) below.

## Array-vs-object exception

`history --json` and `operator-catalog --json` (with no operator ID
argument) print a bare JSON array at the top level, with each element
carrying its own `schemaVersion`. Every other `--json` command prints a
single JSON object with one document-level `schemaVersion` field, wrapping
whatever list-shaped data it has inside a named field instead of at the top
level.

This is an **intentional, accepted exception**, not an oversight to fix:
both commands' natural output is "a list of independent records," and each
record already needs its own `schemaVersion` regardless of how the outer
document is shaped (a `RunHistoryRecord` or an `OperatorCatalogEntry` can
be read on its own, outside the context of a `history`/`operator-catalog`
invocation — e.g. copied out of a larger stream). Wrapping either output in
an outer `{ schemaVersion, items: [...] }` envelope would be a breaking
change to two already-shipped, real integrations for no reader benefit,
since nothing about the outer document needs its own version independent of
its elements'. `operator-catalog <id> --json` (single operator) does not
have this exception — it already returns a single object, since there is
exactly one record to return.

## Legacy exception: `InspectCommand.ErrorJSON`

`mutantkit inspect <id> --json`, on the "no such mutation in this plan"
path, emits `InspectCommand.ErrorJSON` — a bare `{"error": "<message>"}`
object with no `schemaVersion` field and none of `JSONErrorEnvelope`'s
`ok`/structured `code`/`remedy` fields every other command's error path
uses.

This is a **permanently frozen legacy exception, not an unmigrated
accident** — confirmed by `Sources/CLI/JSONOutput.swift`'s own doc comment
on `JSONErrorEnvelope`, which identifies `InspectCommand.ErrorJSON` by name
as "the only precedent" for a `--json` error shape and notes it "predates
the `schemaVersion` convention every success shape here already follows."
`JSONErrorEnvelope` was introduced later, specifically because this shape
existed and every other command needed a real, structured error contract
`ErrorJSON` was never designed to be. Migrating `inspect`'s not-found path
onto `JSONErrorEnvelope` now would be a breaking change to an existing,
real `--json` consumer for a cosmetic consistency gain — not planned. A
consumer of `inspect --json`'s error path must handle this one shape
specially; every other command's error path is `JSONErrorEnvelope`.
