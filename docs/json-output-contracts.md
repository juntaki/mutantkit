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
| `commandError` | 1 | Every `--json`-supporting command's failure path (`JSONErrorEnvelope`) | object |

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
