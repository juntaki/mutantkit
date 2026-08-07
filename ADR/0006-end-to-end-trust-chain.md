# ADR-0006: An end-to-end trust chain — verifier-derived outcomes, per-image build receipts, a binary runtime protocol

- **Status:** Accepted / Implemented — all three stages complete
- **Date:** 2026-07-30 (Stage 1 landed 2026-08-03; Stage 2 landed 2026-08-04; Stage 3 landed 2026-08-04, branch `feature/schemata-proof-chain-v3`)

## Stage progress

```text
1. refactor/verified-core-cutover        COMPLETE
2. feature/schemata-proof-chain-v3       COMPLETE
3. feature/re-enable-schemata-scoring    COMPLETE (see below)
```

### Stage 2 detail

Landed, in two parts:

**Part 1 — real compilation-unit-to-image mapping (closes Finding 4 for real).**

- `BuildTargetIdentity` (`Sources/MutationModel/SchemataBuildReceipt.swift`) replaces every string-based `targetIdentity` field — exact-equality identity (`projectIdentity`/`targetName`/`moduleName`), never a name compared by substring.
- `SwiftPMCompilationUnitImageResolver` (`Sources/AppleBuildAdapters/SwiftPMCompilationUnitImageResolver.swift`) proves a SwiftPM target's built image by `swift package describe` dependency-graph reachability from a real test target — confirmed empirically that modern SwiftPM links every local test target's own dependency closure into one combined `<Package>PackageTests.xctest` bundle, so the ordinary case needs no name matching at all. A build producing more than one image is disambiguated only by exact product-name equality against `swift package describe`'s own `products` list.
- `XcodeCompilationUnitImageResolver` (`Sources/AppleBuildAdapters/XcodeCompilationUnitImageResolver.swift`) resolves each target's real `BUILT_PRODUCTS_DIR`/`EXECUTABLE_PATH`/`WRAPPER_NAME`/`MACH_O_TYPE` via `xcodebuild -showBuildSettings -scheme -target`, refusing `staticlib`/`mh_object` targets that produce no image of their own.
- `SchemataBuildable.resolveSchemataBuildReceipt` (`Sources/MutationExecution/Adapters.swift`) replaces the old `inspectSchemataImages(for:)` — both adapters now produce a real `SchemataBuildReceipt` naming every requested compilation unit's real `BuildTargetIdentity` and the `BuiltImageReceipt` it was proven to land in.
- `SchemataMutationRunner` builds real per-entry `CompilationUnitID`/`BuildTargetIdentity` requests (deduplicated per compilation unit, since two mutations in the same file share one unit) and resolves expected image UUIDs by exact receipt identity — the target-name heuristic (`SchemataMutationRunner.expectedImageUUIDs`'s old `.contains` substring match) is deleted, not kept alongside the real mapping.

**Part 2 — the whole trust chain moved into `MutationVerdictVerifier` (closes Findings 1/2/3 for the schemata path).**

- `SchemataMutationRunner` now collects only raw observations: a `SchemataRunExpectation` (mutation ID, compilation unit, source-embedding ID, selector token, run ID — everything the harness already knows before launch) paired with the real `SchemataBuildReceipt` and the whole unfiltered `RuntimeTranscript`, bundled as `SchemataExecutionObservation` (`Sources/MutationModel/SchemataEvidence.swift`). It decides nothing about whether the mutation was proven built, selected, or hit.
- `SchemataEvidenceCollector.collectActivationEvidence`/`RunContext` are deleted — the runner-embedded chain decision they represented. `SchemataEvidenceCollector.readTranscript` (pure parse, no matching) is all that remains on the collector side.
- `MutationVerdictVerifier.verifySchemataChain` (private, `Sources/MutationModel/MutationVerdictVerifier.swift`) is now the *only* place a schemata result is judged. It builds the complete proof chain from scratch on every classification:

  ```text
  PlannedMutationRef -> sourceEmbeddingID -> CompilationUnitReceipt ->
  BuiltImageReceipt/architecture/LC_UUID -> STARTUP -> HIT -> TestRunResult
  ```

  Every stage requires exactly one candidate via a shared `exactlyOne` helper — zero or more than one candidate both fail closed as `infrastructureFailure`, never `.first`/`.max` picking. This closes Finding 3 exactly as originally specified (the collector does no filtering; the verifier alone accepts only a unique, fully-agreeing chain) and closes the missing half of Finding 2/4: a STARTUP/HIT event's own `compilationUnitID` is checked against the real build receipt's `CompilationUnitReceipt`/`BuiltImageReceipt`, not merely against a caller-asserted image-UUID list.
- `SchemataScoringContext`, `SchemataMutationEvidence`, `SchemataEmbeddingEvidence`, `SchemataActivationEvidence` are deleted outright — no v2-style "runner pre-decides, verifier re-checks" path survives anywhere in the codebase (confirmed by repo-wide grep).

Verified against a real toolchain, not just unit tests: every schemata acceptance suite passes — SwiftPM executable, SwiftPM library+XCTest, linker-injection-only (no manifest dependency), Xcode+simulator, both adapters' `resolveSchemataBuildReceipt` conformance, and the full `SchemataMutationRunner` orchestration loop. Unit coverage includes a dedicated schemata-chain test group in `MutationVerdictVerifierTests` covering wrong `sourceEmbeddingID`/`compilationUnitID`/token/runID/image UUID, duplicate STARTUP/HIT, and a HIT from the wrong process.

**Part 3 — the differential acceptance gate.**

- `SchemataIsolatedDifferentialAcceptanceTests` (SwiftPM) and `XcodeSchemataIsolatedDifferentialAcceptanceTests` (Xcode, via `xcodegen`) each run the identical `MutationPoint` set to completion under both `MutationRunner` (isolated) and `SchemataMutationRunner` (schemata) and compare `MutationID` set, `outcome`, `isScorable`, `sourceDiff`, and (for the killed case) `failingTests` — both real toolchain runs, not fixtures.
- **This suite caught a real production bug on its first run against Xcode**, not a hypothetical: `XcodeCompilationUnitImageResolver` had only ever been exercised through `XcodeSchemataAdapterAcceptanceTests`, which happens to construct its adapter with `projectFile: nil` — a shortcut no real caller uses. The differential suite is the first test to call `resolveSchemataBuildReceipt` through an adapter built the way production actually builds one (an explicit `.xcodeproj` path), and that combination made `xcodebuild -showBuildSettings -scheme X -target Y -project <path>` fail outright ("You cannot specify both a scheme and targets" — reproduced directly with a bare `xcodebuild` invocation, a genuine tool limitation, not a plumbing bug in this codebase). Fixed by dropping `-target`, requesting the scheme's whole per-target settings array, and picking the one entry whose own `target` field matches — fail-closed on zero or more than one match, the same discipline as everywhere else in this chain.
- Both differential suites pass. This is Stage 3's actual gate, closed: the two backends are now proven, not merely believed, to agree on the same mutations end to end for both build systems.

Deliberately not done at the time (closed by Stage 3, see below):

- Confirmation retests were unaffected by Stage 2 because schemata mode gathered none of its own (`SchemataMutationRunner.finalize` had no `confirmations:` parameter) — a fresh-RunID-per-confirmation design remained unexercised until schemata confirmation retesting existed at all.

### Stage 3 detail

Landed as its own final commit (`32bea37`), after a dedicated confirmation-parity effort and a full fail-closed audit — both described below.

**Confirmation parity with isolated mode.**

- `MutationVerdictVerifier.confirmationRequirement(for:policy:)` (public) is the single decision point both `MutationRunner` and `SchemataMutationRunner` consult to ask "does this run's own policy require a confirmation, and which kind" — it replicates `deriveProof`'s reachability preconditions, then reuses the verifier's own private `classify` to answer against the *same* `VerdictVerificationPolicy` (`retestKilledMutants`/`confirmCrashKills`/`confirmTimedOutMutants`) an isolated run would be constructed with. No second, independently-derived confirmation policy exists anywhere in the schemata path.
- `ConfirmationObservation` gained a `schemataObservation: SchemataExecutionObservation?` field alongside the existing isolated-mode `activation: ActivationEvidence?` field (kept untouched, zero isolated-mode churn), folded into a shared `applicationEvidence: MutationApplicationEvidence?` computed property both backends' confirmation code now reads.
- `SchemataMutationRunner.confirmSchemataToken` gathers exactly one confirmation, when `confirmationRequirement` says one is needed, as a genuinely independent process: a fresh `RunID`, a fresh transcript path (never the primary run's own), reusing the already-built chunk artifact (schemata never rebuilds to confirm — every mutation is already embedded in the one shared build). `MutationVerdictVerifier.schemataConfirmationChainProblem` — checked before any kind-specific (`confirmKill`/`confirmCrash`/`confirmTimeout`) rule ever runs — refuses a confirmation whose own `SchemataExecutionObservation` either reuses the primary observation's `RunID` or fails `verifySchemataChain` on its own terms. A confirmation is never credited on the strength of the run it is confirming.
- Isolated mode's own confirmation *cascade* (a batch-attributed timeout's confirming rebuild turning out to be a real kill/crash, needing its own confirmation in turn — `MutationRunner.confirmTimeout`'s nested `retestKilledMutants`/`confirmCrashKills` calls) is gated on `TestRunResult.isBatchAttributedTimeout`, set only by `runBatch`. `SchemataMutationRunner` never batches at all, so this is structurally unreachable for schemata — proven by a dedicated unit test (`SchemataConfirmationCrashTimeoutVerifierTests.timeoutConfirmationFinishingNormallyIsFlakyNotCascaded`), not merely asserted in a comment. Schemata therefore correctly gathers at most one confirmation per mutation.
- Persistence: confirmation observations flow through the existing `MutationObservations.confirmations` shape unchanged, so cache/checkpoint round-trips (which already re-verify everything through `MutationVerdictVerifier.verify` on load, from Stage 1) cover schemata confirmations for free — no new persistence code was needed.

**Real-toolchain acceptance coverage added for confirmation.**

- `SchemataConfirmationAcceptanceTests` (SwiftPM): a real assertion-kill confirmation, end to end. Crash confirmation could not be proven the same way on SwiftPM: `swift test`'s own coordinator process never itself crashes even when a worker does (`fatalError`/`XCTFail`/a real memory fault inside the mutated test all surface as an ordinary `exitCode == 1`, never a propagated signal) — a genuine, pre-existing toolchain-level limitation of `SwiftPackageMacOSAdapter`'s `.crashed` classification (keyed on `ProcessResult.terminatingSignal`), not something Stage 3 introduced. No acceptance test in this repository, isolated or schemata, has ever exercised `.crashed` via real SwiftPM.
- `XcodeSchemataConfirmationAcceptanceTests` (Xcode): a real crash confirmation, end to end — `XCResultAdapter` reads a structured `Crash:` field straight out of the `.xcresult` bundle rather than inferring a crash from a process signal, so this backend *can* prove it, unlike SwiftPM.
- `SchemataConfirmationDifferentialAcceptanceTests` (SwiftPM): with `retestKilledMutants: true`, both `MutationRunner` and `SchemataMutationRunner` reach the *identical* `confirmKill` diagnosis text on the same fixture — proof the two backends route through the one shared verifier function, not two independently-reimplemented ones that merely happen to agree on the outcome enum.
- Multi-target confirmation independence was not given its own new real-toolchain fixture: it decomposes into two mechanisms each already independently proven — per-target confirmation gathering (every `runEntry`/`confirmSchemataToken` call is already per-target-independent, proven by the single-target confirmation suites above) and `MultiTargetVerdict` aggregation/evidence-preservation (already unit-tested in `MultiTargetVerdictTests`, and operates purely on already-decided per-target outcomes regardless of whether confirmation contributed to deciding them).

**Re-enabling scoring.**

- `SchemataRunOrchestration.run` (`Sources/CLI/Commands/SchemataRunOrchestration.swift`) now actually invokes `SchemataMutationRunner` for whatever `SchemataChunkPlanner` embeds, instead of unconditionally routing every requested `.schemata` mutation to isolated fallback. `SchemataMutationRunner` is `public` again.
- **Operator gating is the lowerer registry itself, not a separate gate type.** `SchemataLowererRegistry.builtIn` contains exactly one lowerer (`BoolLiteralSchemataLowerer`, for `BoolLiteralInversionOperator`) — any other operator has no registered lowerer, so `SchemataChunkPlanner` routes it to `.isolatedFallback` automatically and it can never appear in `embeddedIDs`. This is also the one operator every real-toolchain differential suite in Stages 2 and 3 actually exercised (happy path, and — Stage 3 — confirmation, on both SwiftPM and Xcode) — so the set of operators permitted to score and the set proven by differential testing are, today, identical by construction. A `SchemataOperatorGate`-style explicit tracking struct was considered and judged unnecessary while there is only one lowerer to gate; if a second lowerer is added, this equivalence should be re-examined and an explicit per-operator differential-run/disagreement counter introduced before that operator scores.
- `SchemataRunOrchestrationAcceptanceTests` rewritten to assert the real mixed-backend behavior against the `SchemataSwiftPackageMacOS` fixture (bool-literal candidates scored via schemata, a relational-operator candidate via isolated fallback, one reconciled `RunReport`) — verified against the real `mutantkit` binary, not a direct construction.
- This commit (`32bea37`) contains only the scoring-gate flip (`SchemataMutationRunner`'s access level, `SchemataRunOrchestration`'s routing logic) plus its own acceptance test update — no new proof types, parsers, resolvers, or confirmation logic. Those landed in five separate, earlier commits (`12a722a`, `993c680`, `d51cab3`, `706f0e7`, `a9a6508`, `8d0e9f5`), each independently verified before the scoring flip.

**Pre-scoring-enable audit (Section 9 of the driving directive, performed before `32bea37`).**

`swift build`, `swift build --build-tests`, `swift test --skip Acceptance` (914 tests), `MUTANTKIT_ACCEPTANCE=1 swift test` (the full real-toolchain sweep), `swiftformat Sources Tests --lint`, and `swiftlint lint --strict --baseline .swiftlint-baseline.json Sources Tests` were all run with scoring still disabled. `swiftformat` was clean. `swiftlint --strict` surfaced 90 violations on first run — confirmed (by running the identical command against `96439e8`, the last commit before this session's Stage 3 work) that 96 of these already existed before Stage 3 touched anything; this session's own new/modified code was responsible for the delta. Fixed everything attributable to this session's own commits (parameter-count and function-length violations in `SchemataMutationRunner.swift` via an extension split, line-length violations in `MutationVerdictVerifier.swift`, a `SchemataConfirmationVerifierTests.swift` split into two files to stay under the type-body-length limit) — repo-wide violation count is now 61, despite this session's own additions, with the remainder being pre-existing debt in files this session never touched (`MutationRunner.swift`, `XcodeBuildAdapter.swift`, `ReproduceCommand.swift`, and others — left alone as out-of-scope unrelated cleanup). See "Known limitations" below for the two `type_body_length` violations left as documented, pre-existing debt.

Stage 1 landed as designed: `candidateOutcome`/`ResultClassifier`/
`SchemataResultClassifier` are gone: `MutationVerdictVerifier.verify`
takes the run's confirmation policy and derives the outcome itself from
`MutationObservations` (`Sources/MutationModel/MutationVerdictVerifier.swift`).
`ResultLedger<MutationResult>` (insert-once, duplicate `PlannedMutationRef`
is a construction-time error) replaced plain `[MutationResult]` arrays in
`MutationRunner.run`, `PlanSharding.merge`, and `RunReport`'s own
construction path. `MultiTargetVerdict`/`TargetVerdict`
(`Sources/MutationModel/MultiTargetVerdict.swift`) preserve every target's
own verdict instead of `mergeMultiTargetResults` discarding the losing
targets' evidence. `VerdictVerificationPolicy` is required, not defaulted,
at every public call site (`MutationVerdictVerifier.verify`,
`MutationResultCache.init`, `CheckpointStore.init`) — a caller not
exercising confirmation-policy enforcement now has to write `.permissive`
explicitly rather than get it by omission. A follow-up
(`fix/operational-issue-reporting`) added `RunReport.operationalIssues` so
a checkpoint write failure — best-effort by design, never affecting score
or integrity — is visible in `report.json`, not just stderr.

Schemata scoring stayed fail-closed (disabled) through Stage 1 and Stage 2,
exactly as designed — `SchemataRunOrchestration` routed every
`.schemata`-requested mutation through the unchanged isolated-mode
`MutationRunner` and recorded the degradation in
`RunReport.executionStrategy`. Isolated mode was unaffected throughout and
kept scoring/caching the entire time. Stage 3 re-enabled schemata scoring
for the one operator with a registered lowerer (`BoolLiteralInversionOperator`)
— see "Stage 3 detail" above; schemata caching/checkpointing remain
out of scope for v1 (see "Known limitations" below).

## Known limitations (as of Stage 3 completion)

- **Schemata mode has no cache or checkpoint participation.** `SchemataMutationRunner`'s
  own doc comment has said so since Stage 1 ("Sequential only in v1: no
  parallel workers, no checkpointing, no cross-run cache participation")
  and this remains true after Stage 3 — `SchemataRunOrchestration` never
  calls `MutationResultCache`/`CheckpointStore` for the schemata portion of
  a run. What *is* proven is that the shared persistence format itself
  (`MutationObservations`, including `confirmations`) round-trips and
  re-verifies correctly regardless of which backend produced it — a
  schemata observation loaded from a cache/checkpoint envelope passes
  through the identical `MutationVerdictVerifier.verify` call an isolated
  one does. Wiring `SchemataMutationRunner` into actual cache/checkpoint
  *operation* (skipping already-scored mutants across runs, resuming a
  killed process) is separate, unstarted orchestration-layer work.
- **Only one operator can score under schemata mode**: `BoolLiteralInversionOperator`,
  the only entry in `SchemataLowererRegistry.builtIn`. Every other operator
  runs isolated, automatically and correctly (the registry lookup itself
  is the fail-closed gate — see "Re-enabling scoring" above), but this
  means schemata mode's actual mutation-testing speed advantage is
  realized only for bool-literal mutations today. Extending
  `SchemataLowerer` coverage to more operators is future work, gated the
  same way this one was: a real `SchemataLowerer` implementation plus a
  real-toolchain differential-acceptance suite (isolated vs. schemata,
  including confirmation) before that operator is added to the registry.
- **Crash confirmation is unprovable via real SwiftPM acceptance testing**,
  a toolchain-level fact discovered during Stage 3 (`swift test`'s own
  coordinator process never itself crashes even when a worker does). This
  affects test coverage only, not runtime correctness: `confirmCrash`'s
  own logic is fully covered by `SchemataConfirmationCrashTimeoutVerifierTests`
  at the unit level and by `XcodeSchemataConfirmationAcceptanceTests` at
  the real-toolchain level (Xcode's `.xcresult` reports crashes
  structurally, unlike SwiftPM's process exit code). No isolated-mode
  SwiftPM acceptance test in this repository has ever exercised
  `.crashed` either — this is not a schemata-specific gap.
- **One observed flake, not reproduced in isolation**: `XcodeSchemataConfirmationAcceptanceTests`
  failed once during a full concurrent `MUTANTKIT_ACCEPTANCE=1 swift test`
  sweep (a plain assertion failure instead of the expected crash) but
  passed 3/3 when rerun standalone immediately after. Consistent with
  resource contention under heavy parallel `xcodebuild`/simulator load
  during the full sweep, not a logic defect — but not fully root-caused,
  and worth watching if it recurs.
- **`swiftlint --strict` still reports 61 pre-existing violations** across
  files this session did not touch (`MutationRunner.swift` — 2849 lines,
  well over the 1000-line file-length limit; `XcodeBuildAdapter.swift` —
  1551 lines; `ReproduceCommand.swift`'s `run()` — cyclomatic complexity
  13 vs. the 12 limit; and others), plus two `type_body_length` violations
  in files this session *did* touch but did not fully resolve
  (`MutationVerdictVerifier.swift`'s `VerdictProof`-deriving enum, 654
  lines vs. the 300 limit; `SchemataMutationRunner.swift`'s struct body,
  378 lines) — both already over the limit before Stage 3 began (571 and
  358 lines respectively) and left as documented debt rather than a
  disproportionate mid-stage refactor. A dedicated lint-debt cleanup pass
  is recommended as separate follow-up work, not bundled into a future
  ADR-0006 stage.
- **`XcodeUnlinkedSourceAcceptanceTests`'s "A mutation outside every
  target's Compile Sources fails the run closed" test fails**, reproduced
  identically at `96439e8` (the commit immediately before this session's
  Stage 3 work began) — confirmed pre-existing, unrelated to schemata
  confirmation or scoring work, and out of this ADR's scope to fix.

**Everything below this point is the original design record, written
before Stage 1 existed.** It is kept as-is (not rewritten to past tense)
because it is still the accurate target design for Stages 2 and 3 — only
the status above has changed.

## Context

An external review of ADR-0005's PRs A–E, run after PR E landed, returned
REQUEST_CHANGES with four P0 findings and one P1. Quoted and addressed
individually below, each checked against the actual code as it stands
after PR F (`14210da`..`b354c0c`), not assumed from memory.

The review's own framing was that these should land as one unsubdivided
cutover (`refactor/end-to-end-trust-chain-v1`), deleting `ResultClassifier`/
`SchemataResultClassifier`, `MutationResult`'s public initializer, and
every current `MutationResult`-construction path, in favor of a verifier
that is a pure function of raw observations end to end. This ADR is
deliberately **design-only**: the user's own instruction, given after
reviewing this ADR's scope, was to finish PR F first (already done) and
design this proposal separately before any implementation decision is
made about how — or whether — to sequence it as one cutover versus staged
PRs. See "On sequencing" at the end.

### Finding 1 (P0): the verifier still does not judge

**Accurate.** `MutationVerdictVerifier.verify` (PR A) takes
`RawMutationAttempt.candidateOutcome` — the judgment `ResultClassifier`/
`SchemataResultClassifier` already made — and only picks a `VerdictProof`
case matching that outcome's shape. Every PR A–D write-up in ADR-0005
says this explicitly ("PR A's verifier does not yet re-derive this
judgment"; "PR B... does not yet re-derive real classification judgment").
This was a deliberately scoped, documented deferral, not a hidden defect —
but the review is right that it is still true after five PRs, and that
`MutationRunner.verifiedResult`/`SchemataMutationRunner.verifiedResult`
both discard the `VerifiedMutationVerdict`'s `mutationRef`/`proof` after
computing them, converting straight back to a `MutationResult` a classifier
could have produced unverified just as well. The type-level guarantee PR A
promised (`VerifiedMutationVerdict` only constructible via the verifier)
protects nothing yet, because nothing downstream of `verifiedResult`
actually consumes a `VerifiedMutationVerdict` — everything still runs on
`MutationResult`, which anyone can still construct freely.

`workUnitID: plan.planID` (both runners) is a real simplification, not a
bug in the sense the review implies — PR B's own write-up says exactly
why (no finer-grained work-unit concept exists in either runner today).
Worth revisiting if/when work-unit-scoped identity matters for something
concrete; not evidence the verifier's core design is wrong.

### Finding 2 (P0): PR E's image UUID does not prove the mutation-bearing image

**Partially accurate, with one correction to the review's own framing.**
`mutantkit_compute_image_uuid` calls `dladdr` on its own function pointer.
Because `MutantKitSchemataRuntimeC` is a *static* library, every Mach-O
image that links it gets its own independent copy of that function (and
every other symbol in the library) — `mutantkit_startup`'s own doc comment
already says this: "every Mach-O image that statically links this runtime
carries its own copy of these globals and therefore runs its own copy of
this constructor." So `dladdr` on that per-image copy's own address
correctly resolves to *that* image — not some unrelated image that merely
happens to also contain runtime code, which is what the review's wording
("identifies only the image containing runtime code, not necessarily the
mutation site") suggests as the failure mode. For every case this
codebase's lowerer produces today, the mutation site and the runtime
constructor's copy are compiled into the same translation units, hence
the same image — so the identification is correct for what exists.

The real gap: nothing *proves* that correspondence structurally. It holds
today because of how `BoolLiteralSchemataLowerer` happens to work, not
because any type or call encodes "this image's UUID is the one this
specific mutation's call site was compiled into." PR E's own ADR-0005
write-up already flagged this precisely: "deliberately NOT wired into
`SchemataActivationEvidence.imageUUID`/`provesInternalConsistency` yet."
The review's proposed fix — a per-compilation-unit descriptor passed at
each generated call site, so `__mutantkitIsActive` receives proof of which
compilation unit it's being called from, independent of which image
happens to link the runtime — is real hardening worth doing, especially
once PR F's multi-target embedding means a single process can plausibly
load mutations from more than one image at once. It is not, however, a fix
for a currently-observed incorrect verdict; no acceptance test or unit
test has ever demonstrated a case where the current identification
resolves the wrong image. Priority should reflect that distinction: build
this before it can *actually* misattribute a mutation (i.e., before or
alongside whatever wires multi-target evidence into real per-target
verification), not as an emergency fix to a proven-wrong value today.

### Finding 3 (P0): STARTUP/HIT matching is ambiguous under multiple images

**Accurate, and now more relevant given PR F.** `SchemataEvidenceCollector
.collectActivationEvidence` picks `startupEvents.first { token == requested
&& runNonce == context.runNonce }` — under PR E's protocol, two images in
one process sharing a run nonce (a parent process's env inherited by an
unrelated child, or two of this process's own linked images) could both
write a matching STARTUP line, and `.first` picks whichever happened to
be appended first, not the one this specific verification actually needs.
Separately, the HIT search (`hits.filter { token == requested &&
processID == matchingStartup.processID && runNonce == context.runNonce }`)
has no image-UUID term at all — a HIT from a *different* image in the same
process, sharing PID (trivially true — PID is process-wide) and the
requested token (only true if two images happen to reuse token values,
which a shared selector-namespace design should prevent, but the check
does not itself enforce it) would currently be credited. And
`StartupEvent.imageUUID`/`RawHit.imageUUID` — real, parsed values as of
PR E — are computed and then never read by `collectActivationEvidence`,
which still stamps `context.imageUUID` (the host-supplied placeholder)
onto the returned evidence, exactly as PR E's own write-up says it
deliberately does for now.

The review's proposed replacement — the collector does no filtering at
all, handing every parsed event to the verifier as a `RuntimeTranscript`,
and the verifier accepts only a chain where every identity field
(sourceEmbeddingID, compilationUnitID, image UUID across build/STARTUP/HIT,
run ID, token, PID) agrees, with zero or multiple candidates both being
`infrastructureFailure` rather than "pick the first" — is the correct
shape for exactly the reason PR A's own design principle states: a single
place should decide trustworthiness, not a `first`/`last` heuristic
embedded in a collector. This is real, valuable work independent of
Findings 1 and 4.

### Finding 4 (P0): `BuildArtifact` cannot express which compilation unit landed in which image

**Accurate, and larger than it looks.** `BuildArtifact` (`Adapters.swift`)
has `productsDirectory`/`productHash`/`xctestrunPath`/`command` — a single
aggregate hash over "the test binaries," no per-image, per-compilation-unit
breakdown at all. The review's `SchemataBuildReceipt`/`BuiltImageReceipt`
sketch (real Mach-O UUID/content-hash/architecture per built image,
mapped to `CompilationUnitID`) is the natural build-time counterpart to
Finding 2's runtime-observed image UUID — without it, nothing can ever
close the loop PR E's own write-up named: "the real fix needs the
build-time half too... which stays out of scope." This finding is that
build-time half, made concrete.

It is also, honestly, a new subsystem: a Mach-O-parsing build
orchestrator that enumerates every image a schemata build actually
produces, maps each to the compilation unit(s) it was built from, and
persists that mapping — nothing resembling this exists anywhere in this
codebase today (ADR-0004 named its absence repeatedly: "no real build
orchestrator exists yet," across at least four separate stages). Sizing
this honestly against the rest of this ADR matters for the sequencing
question below.

### Finding 5 (P1): the wire protocol is hand-synced text

**Reasonable, lower urgency.** PR E already added a `protocolVersion`
field specifically to catch host/runtime drift loudly rather than
silently — a real, if partial, answer to "the same hole reopens on every
field addition." A fixed-length binary protocol with a shared C header
`import`ed by both sides removes the hand-sync risk at its root, at the
cost of losing text's trivial debuggability (`cat` a hit-log file today;
a binary format needs a decoder). Worth doing, but the lowest-severity
finding here, and the one least entangled with the other four — it could
land independent of any of them.

## Decision (target end state — not this ADR's implementation)

The corrected, combined design this ADR proposes:

```swift
struct MutationObservations {
    let plannedMutation: PlannedMutationRef
    let source: SourceApplicationObservation
    let build: SchemataBuildReceipt?      // isolated mode: a simpler BuildObservation
    let runtime: RuntimeTranscript?        // every parsed STARTUP/HIT event, unfiltered
    let test: TestObservation?
    let coverage: CoverageObservation?
}
```

`MutationVerdictVerifier.verify(_ observations: MutationObservations) ->
VerifiedMutationVerdict` becomes the *only* place an outcome is decided —
a pure function from raw observations to outcome, with `ResultClassifier`/
`SchemataResultClassifier` either deleted or reduced to non-authoritative
observation extraction (turning an XCTest/xcresult stream into a
`TestObservation`, never itself returning an outcome). Isolated and
schemata modes feed the same `MutationObservations` shape, differing only
in whether `build`/`runtime` are populated — a real unification, not two
parallel verifier call sites as today.

Runtime protocol v3 (binary, replacing PR E's text v2):

```text
magic, recordSize, protocolVersion, eventType,
runID[16], sourceEmbeddingID[32], compilationUnitID[32],
token, PID, sequence, imageUUID[16], runtimeABI
```

shared via a `MutantKitSchemataProtocolC` header both the C runtime and
Swift host import — no hand-maintained parallel format description.
`__mutantkitIsActive` takes a `mutantkit_image_descriptor_t*` populated
per compilation unit at generation time, so a HIT event's identity
traces to the specific compilation unit the call site was lowered into,
not merely the image that happened to link the runtime. `nonce` becomes a
fixed 16-byte run ID, not an arbitrary string.

`SchemataEvidenceCollector` stops filtering: it parses every event into a
`RuntimeTranscript` and hands the whole thing to the verifier, which
accepts only a unique chain where `sourceEmbeddingID`, `compilationUnitID`,
and image UUID all agree across the build receipt, STARTUP, and HIT, along
with run ID/token/PID — zero or multiple such chains is
`infrastructureFailure`, never a `first`/`last` pick.

`SchemataBuildReceipt`/`BuiltImageReceipt` replace `manifestHash =
productHash` as a stand-in for per-image identity — a real build
orchestrator responsibility, enumerating and hashing every Mach-O image a
schemata build actually produces.

Persistence: `MutationResultCache`/`CheckpointStore`/`RunReport`/every
reporter accept only `VerifiedMutationVerdict` (or a report-only
projection of it) — never `MutationResult` as an intermediate, freely-
constructible currency. This is the change that would let `IntegrityChecker`
actually narrow to reconciliation-only, closing the gap the PR B/schemata-
migration write-ups both identified: today `MutationResult`'s public
initializer means the cache/checkpoint stores can still receive a
corrupted or hand-built result regardless of what production code does.

### Addendum: a second review round, incorporated

A follow-up review, after reading this ADR, pushed back on the sequencing
below (see "On sequencing") and added four points the original review
round did not cover. All four are correct and are folded into the target
design above/below rather than left as a separate list:

1. **`VerifiedMutationVerdict`'s `mutationRef`/`proof` are computed and
   then discarded.** `MutationRunner.verifiedResult`/`SchemataMutationRunner`'s
   equivalent both call `MutationVerdictVerifier.verify` and then throw
   the result away, converting back to a `MutationResult`. This is why
   `MutationResultCache.store` needs `verificationVersion` passed in by
   its caller (`MutationVerdictVerifier.currentVersion`, threaded
   manually) instead of reading it off the verdict that already carries
   it — a symptom of the same root cause Finding 1 names. The target
   design fixes this at the source: the verdict is never discarded, and
   `verificationVersion` is only ever read off the record already in
   hand, never passed by a caller.
2. **`outcome` and `proof` should not be two separately-settable fields.**
   `VerifiedMutationVerdict` today has `let outcome: MutationOutcome` and
   `let proof: VerdictProof` as independent fields — nothing at the type
   level stops constructing (even inside `MutationModel`, by a future
   change to the verifier) an `outcome: .survived` paired with a
   `.unviable` proof. Folding `outcome` into each `VerdictProof` case
   (`.executed` already implies survived/killed/timedOut from its own
   evidence; `.noCoverage`, `.unviable`, `.excluded` each imply their own
   outcome or carry it as their one authoritative field) removes the
   combination entirely, rather than relying on the verifier to keep them
   in sync by convention.
3. **Early, pre-classification exits (sandbox creation failure, a build
   command that could not even launch) should route through the verifier
   too, as `.excluded` proof — not remain a parallel, unverified
   `MutationResult` construction path.** PR B/the schemata migration
   both deliberately left these ~8 sites unrouted, reasoning that there
   was no `ResultClassifier.Classification` to verify. That reasoning
   under-weighted the actual goal: the point of routing through the
   verifier was never "re-check a classifier's judgment," it is "nothing
   constructs a `MutationResult` outside this one path." An infrastructure
   failure with no classification to verify still has an outcome
   (`.infrastructureFailure`) and a diagnosis — enough for `RawMutationAttempt`
   today, unchanged.
4. **Multi-target results must not collapse to one winner that discards
   the losing targets' evidence.** PR F's `mergeMultiTargetResults` picks
   the highest-ranked outcome and keeps only that target's
   `MutationResult`, permanently losing whichever other targets' evidence
   existed — a real audit-trail loss the "kill wins" product decision
   never asked for (the decision was about the *aggregate outcome*, not
   about discarding proof). The target design keeps every target's own
   verdict:

   ```swift
   struct MultiTargetVerdict {
       let mutationRef: PlannedMutationRef
       let aggregateOutcome: MutationOutcome
       let aggregationPolicyVersion: Int
       /// Every target's own verdict, sorted by a stable target identity
       /// — never insertion order, which depends on chunk-processing order.
       let perTarget: [VerifiedMutationVerdict]
   }
   ```

   `aggregateOutcome` is derived by the same rank policy PR F already
   implements (kill > survived > noCoverage > unviable > environmental >
   infrastructureFailure); `aggregationPolicyVersion` lets that policy
   itself be revised later without silently reinterpreting old records.
   Nothing about a losing target's evidence is thrown away.

## `SchemataPlan`'s fail-open decode path

`SchemataPlan.decodeAndValidate`'s `executionContext` parameter is
optional, defaulting to `nil` — production code can call the weaker,
context-free overload (self-consistency only) as easily as the real one,
and the doc comment's own justification ("no production caller constructs
a `SchemataPlan`-consuming execution path yet") is stale now that PR F's
`SchemataMutationRunner` is exactly such a caller. The fix is a type-state
split, not a runtime check:

```swift
struct UnvalidatedSchemataPlan { /* raw decode result */ }
struct ExecutableSchemataPlan {
    // Only constructible by validating an UnvalidatedSchemataPlan against
    // a non-optional SchemataExecutionContext.
}
```

`SchemataMutationRunner`'s initializer takes one validated execution
bundle (`ExecutableSchemataPlan` plus its `points`/`sources`), not the
current loose `programs`/`points`/`originalSources` triple a caller could
assemble from mismatched sources. Plan inspection (`InspectCommand` and
similar) gets its own explicit, clearly-weaker decode entry point instead
of sharing the same function production code calls.

## Required negative tests (from the review, verified as the right list)

```text
multiple images in one process
a child process inheriting the parent's environment (nonce collision)
STARTUP and HIT reporting different image UUIDs for the same run
proof belonging to a different mutation
duplicate STARTUP events
a truncated/malformed binary event
a runtime ABI mismatch
a forged/hand-edited cache record
a duplicate insert into the ledger (same PlannedMutationRef twice)
a duplicate checkpoint row for one mutation
a multi-target verdict whose perTarget entries are not sorted by a stable
  target identity
decodeAndValidate's context-free overload reachable from a production
  (non-inspection) call site
```

Every one of these is either untested today or actively unenforceable
under the current design — this list is sound and gates whichever stage
below actually touches the area it names.

## On sequencing — revised after the second review round

The first review round asked for one unsubdivided cutover. This ADR's
first draft declined that and proposed four stages (G–J), reasoning that
Finding 4 depends on a build orchestrator that does not exist and that
combining a wire-protocol rewrite with public-API deletion in one change
maximizes blast radius.

**The second review round's rebuttal to that sequencing is correct and is
adopted:** G→H→I→J leaves the trust boundary itself — the actual thing
every finding is about — closed *last*, in stage J, while stages G and H
spend two whole stages adding new evidence types and a new protocol
alongside the old ones, unclosed. That is a smaller version of the exact
failure this whole ADR chain exists to stop: a new correctness mechanism
introduced next to an old one that can still be reached, instead of
replacing it. The original three-part justification for staging still
holds in substance (a build orchestrator is real, separate infrastructure;
big-bang changes have no isolated stage to bisect a regression to) — the
fix is to reorder stages so the trust boundary closes *first*, not to
insist on either one cutover or four parallel-evidence stages. Three
stages, matching the second review round's own proposal:

```text
1. refactor/verified-core-cutover
   MutationObservations → MutationVerdictVerifier → VerifiedMutationRecord
   (renamed from VerifiedMutationVerdict to reflect that it is now the
   only currency, not one of several) becomes the only path from a raw
   attempt to anything reportable. candidateOutcome is deleted; the
   verifier derives outcome from observations. outcome/proof collapse
   into one non-combinable enum (VerdictProof's cases each carry their
   own outcome). MutationResult's public initializer is removed —
   downgraded to a reporter-only projection type nothing constructs
   except by deriving it from a VerifiedMutationRecord. ResultLedger
   replaces [MutationResult] arrays everywhere a set of results is held
   (MutationRunner.run, SchemataMutationRunner.run, RunReport,
   IntegrityChecker, MutationResultCache, CheckpointStore): insert-once,
   a duplicate PlannedMutationRef is a construction-time error, not a
   downstream Integrity violation caught after the fact. Sandbox/build-
   launch early exits route through the verifier as `.excluded` proof —
   no parallel unverified construction path survives anywhere.
   IntegrityChecker narrows to reconciliation-only, for real, because
   nothing else can reach the ledger. MultiTargetVerdict (preserving
   every target's own VerifiedMutationRecord, never discarding a losing
   target's evidence) lands here too, replacing PR F's
   mergeMultiTargetResults. This stage does NOT touch the runtime
   protocol or add build receipts — schemata's own scoring/caching stays
   fail-closed (disabled, not silently wrong) for the duration of this
   stage and the next, reopened only in stage 3. Isolated mode is
   unaffected by that suspension and keeps scoring/caching throughout.

2. feature/schemata-proof-chain-v3
   SchemataBuildReceipt/BuiltImageReceipt (a minimal Mach-O parser
   reading LC_UUID/architectures from already-built artifacts),
   compilation-unit descriptors passed at each generated call site, the
   shared-header binary STARTUP/HIT protocol replacing text v2 entirely
   (no v2 parsing path kept alive alongside it), and a collector that
   stops filtering — it produces an unfiltered RuntimeTranscript and lets
   the verifier (built in stage 1) accept only a unique, fully-agreeing
   chain. SchemataPlan's type-state split (UnvalidatedSchemataPlan /
   ExecutableSchemataPlan) lands here, since it is the schemata
   execution path this stage is already rewriting.

3. feature/re-enable-schemata-scoring
   Every required negative test above passes against the real stage-1/
   stage-2 machinery before schemata scoring/caching is switched back on.
   No new type is introduced in this stage — it is verification and the
   flag flip, not more construction.
```

Stage 1 alone is a large, real, self-contained change — it needs no build
orchestrator and no protocol rewrite, and it is where the trust boundary
actually closes. Stages 2 and 3 build the schemata-specific evidence
chain *inside* a boundary that already only accepts verified records,
rather than around one that still has an open side door. No individual
fix outside these three stages should land in the meantime, per the
second review round's own closing instruction — this ADR agrees with that
constraint now that the sequencing itself closes the boundary first.
