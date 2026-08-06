# ADR-0003: The schemata evidence and plan contract

- **Status:** Accepted (types only — no execution backend implements this yet)
- **Date:** 2026-07-28

## Context

`ExecutionMode.schemata` (`Sources/MutationModel/CoreTypes.swift`) has existed
as a reserved, unimplemented case since v0.1's design, and
`OperatorDescriptor.schemataEligible` has existed per-operator since the same
point — both placeholders for a schemata execution mode that has never had a
real contract behind it.

An earlier draft of that contract assumed three things that turned out not to
hold:

1. **A single, universal lowering.** The draft embedded every mutation site
   the same way — an `if`/`if`-expression switching on an active-mutant
   check. Swift's `if` expression is only legal in variable-initialization,
   `return`, and direct-assignment position; it cannot replace an arbitrary
   subexpression the way ternary's `?:` can. Worse, `if` expression branches
   are independently type-checked against a shared expected type, while
   `?:` uses bidirectional inference, so the *lowering choice itself* can
   change whether the inactive schema type-checks identically to the
   original — precisely the correctness question this design exists to
   settle, not reopen.
2. **One evidence shape for both backends.** `ActivationEvidence` (a
   whole-binary hash comparison: does the mutant's build product differ
   from the baseline's) is sound when one binary maps to one mutant, which
   is true in isolated mode and false in schemata mode — every mutant in a
   schema shares one binary and one `sourceAfterHash`, so a hash diff proves
   nothing about which embedded mutant a given test run actually exercised.
3. **A point-at-a-time embedding API.** Embedding one candidate at a time
   cannot see nested mutations, mutations sharing an expression tree,
   byte-offset drift from an earlier edit in the same file, or cross-
   operator semantic conflicts where two edits each compile alone but
   change each other's inferred types together.

## Decision

**No universal lowering — a per-candidate eligibility classification instead.**
`SchemataEligibility` (`Sources/MutationModel/SchemataLowering.swift`)
classifies each candidate as `.eligible(loweringKind:rewriteEnvelope:
conflictKeys:)` or `.isolatedOnly(reason:)` *before* anything is embedded.
`SchemataLoweringKind` enumerates the shapes a lowering can actually take
(`literalSelection`, `expressionTernary`, `statementBranch`,
`returnExpression`, `declarationInitializer`) rather than assuming one shape
covers every site. `schemataEligible: Bool` on `OperatorDescriptor` stays as
a coarse, operator-level default; per-site eligibility is the real gate.

**Evidence splits by backend, not shared.** `MutationApplicationEvidence` is
`.isolated(ActivationEvidence)` or `.schemata(SchemataActivationEvidence)` —
two distinct proofs, not one shape stretched to cover both. Schemata's proof
is three-part:

- **Build evidence** (`SchemataEmbeddingEvidence`) — which mutant was
  actually built into which schema, at build time. Carries both
  `mutationDiff` (the logical mutation a human reviews) and `embeddingDiff`
  (what the lowering actually generated) as separate fields, since they can
  differ once a candidate is wrapped in a runtime selector, and collapsing
  them would hide exactly the "did the lowering introduce something
  unintended" question this evidence exists to let a reviewer answer.
- **Activation evidence** (`SchemataActivationEvidence`) — what a specific
  test *process* requested, selected, and hit, as `SchemataSelectorToken`
  values (see the addendum below for why a bare index was not enough).
  `provesActivation` is `true` only when `requestedToken == selectedToken ==
  hitToken`, and `hitToken` is `Optional` — `nil` means no hit was durably
  recorded (a crash, a hang, or an evidence-transport failure before the
  mutated site executed), not a fabricated zero. A caller must not credit a
  kill/crash/verified-timeout verdict without `provesActivation == true`,
  the same `unprovenActivation` discipline `ResultClassifier.swift` already
  applies to isolated-mode results — and, per the addendum, `provesActivation`
  alone is *not* the scoring gate; `SchemataMutationEvidence
  .provesScorableExecution` is.

**The plan (`plan.json`) stays the single source of truth for *what
mutations exist*; a companion `SchemataPlan` (`schemata-plan.json`) records
schemata-specific placement facts** — mutation → chunk, mutation → dense
local index, lowerer ID/version, conflict group, fallback reason,
target/module/product, expected image set — without duplicating or risking
disagreement with `MutationPlan` itself. `SchemataPlanEntry.chunkID == nil`
means isolated-fallback; `fallbackReason` explains why.

**`schemataPlanID` is content-addressed, never positional.** (Named
`schemaID` in this ADR's first draft; renamed by the addendum below once a
second, chunk-scoped identity was added alongside it.) Derived from an
explicit, ordered, delimited preimage — backend identity/version, toolchain
hash, build-arguments hash, and the sorted `(mutationID, chunkID,
selectorToken, chunkArtifactID, lowererID, lowererVersion)` tuple for every
entry — the same discipline `MutationID.compute` and `MutationPlan
.workUnitID` already use. `SchemataPlan.init` pre-sorts entries by
`mutationID` before deriving the hash, so two plans built from an identical
input set agree on `schemataPlanID` regardless of discovery or chunking
order. A sequential chunk-numbering scheme was explicitly rejected:
renumbering every later chunk on a single addition would invalidate schema
build cache, artifact cache, and historical benchmark comparisons for no
reason connected to what actually
changed.

**Lowering operates on a whole chunk, not one candidate at a time.**
`SchemataLowerer` (`Sources/SwiftFrontend/SchemataLowerer.swift`) has
`analyze(_:context:) -> SchemataEligibility` for the first, per-candidate
pass that builds the conflict graph, and `lower(_:sources:) throws ->
SchemataProgram` that commits an entire `SchemataChunk` at once — the unit
that can actually see cross-candidate conflicts, not a signature that
forces conflict detection to happen some other way, later, against
already-embedded output.

## Consequences

### What this ADR does not do

No execution backend exists yet. `MutationRunner`, the CLI, and every
reporter are untouched — these types have no caller in production code, by
design (see the roadmap's S0/S1 staging: contract first, runtime second).
`MutationOutcome` (`Sources/MutationModel/MutationOutcome.swift`) does not
yet gain a `backendMismatch` case: adding a live enum case now would force
every exhaustive `switch` over `MutationOutcome` across the reporting and
scoring layers to handle a case that cannot occur until a schemata backend
exists to produce it, for no near-term benefit. That case is deferred to
whichever stage first needs to *produce* a `backendMismatch` result (the
differential-validation work), not added speculatively here.

### Every future schemata stage builds on these types without redefining them

S1 (bool-literal lowering) implements `SchemataLowerer` for real, against
`.literalSelection` only. S2 (the SwiftPM runtime) is the first thing that
actually constructs a `SchemataActivationEvidence` from a live process. S4
(the chunk planner) is what actually populates `SchemataPlanEntry
.conflictGroup` from a real conflict graph instead of `nil`. None of them
need to change the shape defined here — only implement against it.

## Addendum: S1 review corrections (still S1, not S2)

A second review of the S0 contract, done alongside the S1 bool-literal
implementation, found five gaps the "implement, don't redefine" claim above
could not survive intact. All five are contract corrections, not new
capability — made before any runtime consumes these types, so the blast
radius was five source files and their tests, not a runtime ABI, cache, or
report schema. Recorded here so the claim above stays honest: everything
*after* this addendum is what "just implement against it" now means.

**Selector identity is `(namespace, localIndex)`, not a bare index.** A
lone per-chunk `UInt32` cannot tell two chunks loaded into the same process
apart — an app and a linked framework, each with their own independently
numbered schema, would both claim "index 0" for their first mutation.
`SchemataSelectorToken` pairs a `namespace` (derived from the owning
chunk's content-addressed `chunkID`) with a 1-based `localIndex`; `0` is
reserved as the "no mutation selected" sentinel, so an uninitialized or
bootstrap-time read of the runtime global can never be mistaken for a live
selection. Generated call sites are `__mutantkitIsActive(namespace,
localIndex)`.

**Plan identity and artifact identity are two different hashes.**
`SchemataPlan.schemataPlanID` (renamed from `schemaID`) still identifies the
whole plan's mutation-to-chunk arrangement, and still changes when any
mutation anywhere is added — that part was correct. What was missing was a
*second*, chunk-scoped identity: `SchemataPlanEntry.chunkArtifactID`
(computed by the lowerer as `SchemataProgram.artifactID`), covering what the
lowerer itself can see — runtime ABI version, lowerer identity/version,
target/module/product, every lowered source file's content hash, and the
token map. A build orchestrator threading in platform/toolchain/build-
argument inputs (the role `SchemataPlan.toolchainHash`/`buildArgumentsHash`
already play at the plan level) extends this further before using it as an
actual cache key. The point of the split: adding a mutation to one chunk
changes `schemataPlanID` (correctly — the arrangement changed) but must not
change any *other*, untouched chunk's `chunkArtifactID`, so that chunk's
build cache entry stays valid.

**Build proof and run proof are one type, not two independently-checked
ones.** `SchemataEmbeddingEvidence` (built) and `SchemataActivationEvidence`
(selected + hit) used to be checked separately, with nothing enforcing they
describe the same mutant. `SchemataMutationEvidence` now bundles both and
gates scoring on `provesScorableExecution`: the activation's own
`requested == selected == hit`, *and* `embedding.schemaArtifactID ==
activation.schemaArtifactID`, *and* matching manifest hashes, *and*
`embedding.selectorToken == activation.requestedToken`, *and* the hit image
among `embedding.imageUUIDs`. `MutationApplicationEvidence.schemata` now
holds this composite, not the activation evidence alone.

**`SchemataLowerer.analyze` takes the point's source, not just the point.**
A `MutationPoint` alone (byte range + text) cannot answer "would a
selector-wrapped rewrite break this site's surrounding syntax" — a
`@ViewBuilder`-style result-builder body, the case this addendum's `analyze`
now actually detects (previously the `.resultBuilderBody` case existed in
`SchemataUnsupportedReason` but nothing produced it). `analyze` re-parses
the source and inspects the matched node's ancestors, the same
re-derive-from-bytes discipline `SourceAnchorVerifier` already uses rather
than trusting a node kept alive from discovery. `OperatorExclusions
.isInsideResultBuilderBody` (moved out of `ElseClauseDeletionOperator`,
which had its own private copy) is now shared by both. This does not solve
every syntax-context hazard a lowering could hit — a body-transforming
attached macro, say, has no detector anywhere in this codebase yet and is
not attempted here — but the two concretely known ones (macro-call
arguments, already excluded by discovery's own `OperatorExclusions
.isExcluded`; result-builder bodies, now excluded at analysis time too) are
covered.

**`lower(_:sources:)` no longer trusts the chunk planner.** It is the last
line of defense against a chunk-planner bug, not just a byte-splicing
engine: it fails closed on an empty chunk, a token space too large for a
dense `UInt32`, a duplicate `MutationID`, a duplicate source path, and any
two points in the same file whose byte ranges overlap (a running-max-end
sweep over sorted ranges, not just adjacent-pair comparison — three points
where the first fully contains the third, with the second touching neither,
still needs the first/third pair caught). After construction, it asserts
its own output: exactly one entry per input point, no duplicate mutation
IDs, no duplicate selector tokens.

### A per-candidate model complicates simple operator-level questions

"Is `swift.core.ternary-branch-swap` schemata-eligible?" no longer has a
single yes/no answer — the honest answer is "eligible at sites the
semantic-fingerprint check can prove type-invariant, `isolatedOnly`
elsewhere." `OperatorDescriptor.schemataEligible` remains as a coarse
default for tooling that only needs an operator-level signal (e.g. the CLI
listing what *might* run under schemata); anything that needs to know for a
specific site must call `SchemataLowerer.analyze` and read the real answer.

## Addendum 2: persistence and trust-boundary corrections

A third review, focused specifically on `SchemataPlan` persistence and
`SchemataMutationEvidence`'s use as a scoring gate, found six more gaps —
all in how these types survive a JSON round trip and how evidence is
trusted, not in the lowering logic addendum 1 already covers.

**`SchemataPlan` is now always bound to the `MutationPlan` it was built
from.** `SchemataPlan.init` takes the `MutationPlan` itself, not loose ID
strings, and records both `mutationPlanID` (`MutationPlan.planID`) and
`mutationPlanWorkUnitID` (`MutationPlan.workUnitID` — the mutation *set*,
distinct from plan lineage). Production code must decode through
`SchemataPlan.decodeAndValidate(_:against:)`, never a bare
`JSONDecoder().decode(SchemataPlan.self, from:)`: it re-verifies that
`schemataPlanID` still matches its own recomputation (catching a hand-
edited or truncated file), that the decoded `mutationPlanID`/
`mutationPlanWorkUnitID` match the `MutationPlan` handed in (catching a
`schemata-plan.json` paired with the wrong `plan.json`), that no
`MutationID` or `SchemataSelectorToken` repeats across entries, and that
entries and the plan's mutations correspond one-to-one (nothing silently
dropped, nothing invented).

**`SchemataSelectorToken`'s `Decodable` conformance is now hand-written,
not synthesized.** Synthesized `Decodable` assigns fields directly,
bypassing `init(namespace:localIndex:)`'s `localIndex > 0` precondition
entirely — a hand-edited `schemata-plan.json` could decode a `localIndex:
0` token (the reserved inactive sentinel) that no code path could ever
construct. The explicit `init(from:)` now throws `DecodingError
.dataCorruptedError` instead.

**`schemataPlanID` and `sourceEmbeddingID` are full, untruncated SHA-256
hashes, not `ContentHash.shortDigest`'s 64-bit truncation.** `MutationID`
and `workUnitID` truncate because they are human-facing labels, where a
collision means "two mutations happen to share a short name" — an
acceptable risk for something a person reads and types. `schemataPlanID`
and `sourceEmbeddingID` are trust-boundary identities a build cache and an
evidence check are keyed on; a collision there means silently reusing the
wrong cached binary. Both now use `ContentHash.of(...)` directly.

**The `schemataPlanID` preimage now folds in every entry field via a
canonical (`.sortedKeys`) JSON encoding, not a hand-maintained list.** The
first draft's manual field list silently omitted `fallbackReason`,
`conflictGroup`, and `target`/`module`/`product` — semantically part of an
entry's identity, just not listed. Two entries differing only in
*why* they fell back to isolated execution could produce the identical
`schemataPlanID`. A canonical encoding cannot omit a field that exists on
the type, now or in the future, closing this class of gap permanently
rather than just for the fields found this time.

**`SchemataPlanEntry`'s placement is now an enum, not five independently-
nilable fields.** `SchemataPlacement.embedded(chunkID:selectorToken:
sourceEmbeddingID:lowererID:lowererVersion:)` /
`.isolatedFallback(reason:)` replaces `chunkID: String?`, `selectorToken:
SchemataSelectorToken?`, `chunkArtifactID: String?`, and `fallbackReason:
SchemataUnsupportedReason?` as four separately-optional fields — a shape
that could represent states no real lowering produces (`chunkID` set with
`selectorToken` nil, say) with nothing to catch it. Existing accessor names
(`chunkID`, `selectorToken`, `sourceEmbeddingID`, `fallbackReason`,
`isEmbedded`) remain as computed properties over the enum, so most call
sites read unchanged.

**`SchemataMutationEvidence.provesScorableExecution` is now explicitly
documented as insufficient on its own, and `verify(against:
SchemataScoringContext)` is the actual production gate.**
`provesScorableExecution` checks only internal self-consistency — that the
embedding and activation halves agree with *each other*. A well-formed,
internally-consistent evidence bundle can still be stale: genuinely
produced by an earlier run of the identical artifact and token, replayed
or left over on disk, and every internal check still passes. `verify`
additionally binds the evidence to facts only the harness that launched
this specific process knows — the `MutationID` it expected, the plan
entry's `sourceEmbeddingID` and `SchemataSelectorToken`, and the run nonce
and process ID it actually observed. A caller must never credit a
kill/crash/verified-timeout verdict to a schemata result without `verify`
returning `true`.

**Renamed, not just refactored: `SchemataPlanEntry.chunkArtifactID` and
`SchemataProgram.artifactID` are now `sourceEmbeddingID`.** The name
"artifact ID" implied a finished, cache-ready build identity; what the
lowerer actually produces is narrower — everything *it* can see (runtime
ABI, lowerer identity/version, target/module/product, lowered source
content, token map), not the platform/toolchain/SDK/build-argument/linker
inputs a build orchestrator would still need to fold in. `SchemataEmbeddingEvidence
.schemaArtifactID` keeps its name deliberately: it is filled in once real
evidence exists, by construction equal to whatever a build orchestrator's
eventual final artifact identity turns out to be — currently the lowerer's
`sourceEmbeddingID`, until a build orchestrator exists to produce
something richer.

### Explicitly deferred, not forgotten

Two items from this review are recorded here as open follow-up rather than
implemented now, because no consumer exists yet for either:

- **Selector namespace collisions.** `SchemataChunk.namespace` is a 64-bit
  value derived from `chunkID`; two chunks loaded into the same process
  could theoretically collide. Detecting this requires a component that
  knows about *multiple* chunks loaded together — the chunk planner (S4)
  or the runtime bootstrap (S2) — neither of which exists yet. Implementing
  collision detection with no real caller to wire it into would be
  speculative; this is the concrete first task for whichever of S2/S4
  lands first.
- **A `SchemataLowerer` registry.** `SchemataLowererDescriptor` (lowerer
  ID, version, runtime ABI version, supported operator IDs) is now a
  protocol requirement, so a registry can reject a duplicate lowerer ID or
  an ambiguous double-registration without downcasting — but no registry
  exists yet, since `BoolLiteralSchemataLowerer` is still the only
  conforming type. Building the registry itself is S4's concern, once a
  second lowerer makes "which lowerer handles this operator" a real
  question.

`SchemataSourceFile.contents` staying `String` rather than `Data` was also
raised and considered lower priority (P2): `MutationApplication` and
`SourceAnchorVerifier` already round-trip through `String(decoding:as:
UTF8.self)` at their boundaries without incident, and the byte-level work
inside `BoolLiteralSchemataLowerer.lower` already operates on `[UInt8]`
internally regardless of the public `String` interface. Revisiting this
is left for whenever a second lowerer's needs actually motivate it.

## Addendum 3: S2 lands — the SwiftPM runtime is real

S2 (the runtime this ADR's addenda kept deferring to) now exists, scoped to
SwiftPM: `MutantKitSchemataRuntimeC` — a plain C target, `bool
__mutantkitIsActive(uint64_t namespace, uint32_t local_index)` — reads
`MUTANTKIT_SCHEMATA_TOKEN` (`"<namespace>:<localIndex>"`) once, lazily, via
`pthread_once`, and appends one line (`<namespace>:<localIndex>:<pid>:
<eventSequence>`) to `MUTANTKIT_SCHEMATA_EVIDENCE_PATH` on every hit. Every
lowered file `BoolLiteralSchemataLowerer` produces now starts with `import
MutantKitSchemataRuntimeC`, and `SchemataEvidenceCollector`
(`MutationExecution`) is the host-side half, turning that plain-text file
into a `SchemataActivationEvidence`.

Proven end to end, not just unit-tested in isolation:
`SchemataSwiftPMRuntimeAcceptanceTests` runs a real `swift build` of a
throwaway package with a path dependency on this repo, lowers a real fixture
through the real `BoolLiteralSchemataLowerer`, and runs the resulting binary
as two real subprocesses — one with no requested token (must read exactly
like the original program) and one requesting the embedded mutation's own
token (must read like the mutant, and leave a hit `SchemataEvidenceCollector`
turns into `provesActivation`-worthy evidence).

**A known, deliberate simplification this stage does not resolve:**
`SchemataEvidenceCollector.collectActivationEvidence` sets `selectedToken`
equal to `requestedToken` — this runtime has no channel to independently
confirm "what actually got loaded" distinct from "did a hit occur." A real
dyld/startup-time confirmation (the intended job of the still-open
`selectedToken` field) is future work. This does not weaken the score-
worthiness gate today: with `selectedToken == requestedToken` always,
`provesActivation` reduces to "was a hit durably recorded for the expected
process and token," which still fails closed on every case that matters
(the mutated site never ran, the token never propagated, a stale file from
a different process) — it just cannot yet additionally distinguish "the
right binary loaded but never hit" from "the wrong binary loaded" the way
the field's name promises for the eventual Xcode/dyld backend (S3).

Xcode-hosted runtime injection (S3) is unstarted and expected to be
materially harder: SwiftPM's own build graph can add a local path
dependency without touching a user's checked-in files (the mutated build
already runs from a disposable sandbox copy, per the isolated-mode design),
but an `.xcodeproj`/`.xcworkspace` has no equivalent "just add a dependency"
mechanism without either modifying project files (defeating the "no
permanent project change" goal) or finding a way to inject a linker
flag/library at the `xcodebuild` invocation layer instead.

## Addendum 4: S3 lands — Xcode-hosted injection, no `.pbxproj` edit

S3 (flagged in addendum 3 as "materially harder" than SwiftPM) is now
proven for the macOS unit-test case: `SchemataXcodeRuntimeAcceptanceTests`
links the real `MutantKitSchemataRuntimeC` into a real `xcodebuild`-built
test target using only `OTHER_LDFLAGS`/`LIBRARY_SEARCH_PATHS` command-line
overrides — no `.pbxproj` modification at all.

**The mechanism required one correction to S1/S2's own output.**
`BoolLiteralSchemataLowerer` originally prepended `import
MutantKitSchemataRuntimeC` to every lowered file, which worked for SwiftPM
(S2) because SwiftPM has a dependency graph an `import` can resolve
against. Xcode has no equivalent — there is no "add this as a package
dependency" step available purely from the command line, the same
constraint that rules out a `.pbxproj` edit in the first place. The fix
generalizes to both backends at once: the lowered preamble is now a
self-contained `@_silgen_name("__mutantkitIsActive")` declaration
(`BoolLiteralSchemataLowerer.runtimePreamble`), which needs the Swift
compiler to see only a raw function signature — no header, no module map,
no import — and needs the *linker*, separately, to find the symbol.
SwiftPM's target dependency graph still satisfies the linker half for S2
(confirmed unchanged end to end); Xcode's `-l`/`-L` build-setting overrides
satisfy it for S3.

**Two real infrastructure bugs surfaced while building the acceptance test
itself, not in the runtime or lowerer:**

1. An early draft's test helper shelled out to `swift build --product
   MutantKitSchemataRuntime` on demand, from *inside* the already-running
   `swift test` process — both processes contend for the same package's
   build lock, so this deadlocked every run. Fixed by having `MutantKitTests`
   depend on the `MutantKitSchemataRuntimeC` target directly (no test file
   imports it; the dependency exists purely so `swift build --build-tests`,
   already run before any test executes, produces
   `libMutantKitSchemataRuntime.a` as a side effect) — the same pattern
   `AcceptanceSupport.binary()` already relies on for the `mutantkit`
   executable.
2. Setting environment variables on the `xcodebuild` `Process` object
   itself does not reliably reach the actual `xctest` process Xcode's own
   tooling launches for a test run — confirmed empirically: the mutation
   never activated even with a correct token set this way. Fixed by
   building once (`xcodebuild build-for-testing`), then writing a modified
   copy of the produced `.xctestrun` plist with the desired
   `EnvironmentVariables` dictionary injected per target, and running each
   variant via `xcodebuild test-without-building -xctestrun <path>` — the
   same mechanism a scheme's own "Environment Variables" editor pane
   ultimately writes to.

**Still open, by design of this stage's scope**, per addendum 3's own
framing: this suite deliberately targets macOS, not iOS Simulator, so it
proves nothing yet about code signing, simulator boot, or dyld image load
order inside a sandboxed simulator process — the harder sub-problems
addendum 3 named as separate and still unstarted. A real
`MutationRunner`/chunk-planner integration (choosing when to use the
schemata backend at all, building the actual chunk-to-target mapping,
wiring `SchemataEvidenceCollector` into `ResultClassifier`) also remains
entirely unstarted — S2 and S3 both prove the injection *mechanism* in
isolation, deliberately staged before either is wired into a real run.

## Addendum 5: S4 lands — the chunk/conflict planner

S4 turns a `MutationPlan` into a `SchemataPlan` for real:
`SchemataChunkPlanner.plan` classifies every mutation (asks the registered
lowerer's `analyze`, falls back to `.isolatedOnly` for anything ineligible
or unsupported), groups eligible points into chunks scoped to one
lowerer/target/module/product each (never mixed — a chunk boundary is never
crossed by a differently-routed mutation), splits any group larger than a
configurable `maxChunkSize`, lowers every chunk for real, and — the item
addendum 3 explicitly deferred for lack of a multi-chunk consumer —
checks every produced chunk's derived selector namespace against every
other chunk's, failing closed on a collision rather than letting two
chunks alias each other's activation tokens.

`SchemataLowererRegistry` (also new) is the "which lowerer handles this
operator" registry addendum 3 deferred for lack of a second lowerer:
duplicate `lowererID`s and two lowerers both claiming the same operator ID
both refuse construction rather than resolving by array order.

Explicitly scoped narrower than "the final chunking strategy": chunks are
grouped by exact target/module/product match only, split purely by count
(no build-time balancing), and there is still no cross-operator conflict
graph (`SchemataUnsupportedReason.structuralConflict` and
`SchemataPlanEntry.conflictGroup` remain unused by this planner — every
lowerer's own `analyze`/`lower` is still solely responsible for rejecting
what it cannot safely embed, same as S1). A caller supplies target/module/
product per file directly; deriving that mapping from a real Xcode/SwiftPM
build graph is a build-adapter integration, not attempted here. Wiring this
planner into `MutationRunner`/`RunCommand` — actually choosing to run a
schemata build instead of isolated mode — also remains entirely unstarted,
consistent with every stage through S4 proving one mechanism in isolation
rather than assembling the full pipeline prematurely.

## Addendum 6: S6 (part 1) — startup-mutant detection

`SchemataUnsupportedReason.processStartRequired` existed since S0 but
nothing ever produced it until now. `BoolLiteralSchemataLowerer.analyze`
gained a real check (`SchemataStartupDetection`): a boolean literal sitting
directly in the initializer expression of a `static`/`class` or module-
scope *stored* binding — `let` or `var`, both share the identical once-only
initialization semantics at that scope — is no longer eligible.

This closes a real gap in S1's own compile-viability acceptance suite: its
`globalInitializer` case (`let featureEnabled = true`) only ever proved the
embedded form *type-checks*. It says nothing about whether embedding it is
*safe* — and it is not: a module-scope `let`/`static let`/`static var`'s
initializer runs exactly once per process and is memoized, so the first
test to touch it would see the requested token's effect, and every later
test (of a different mutant, or of the same one, in the same process) would
silently observe the cached result of that first access regardless of what
its own run requested. The runtime mechanism still activates correctly
once; per-test attribution — the entire point of schemata mode over
running everything in isolation — does not hold. That compile-viability
test still passes and still proves something real (the lowered *shape*
compiles); it is not what determines eligibility, `analyze` is.

**What is `.processStartRequired`, and what is not:**
- `static`/`class`/module-scope stored `let` or `var` initializers: not
  eligible, regardless of mutability — both are computed exactly once.
- Instance (non-static) stored property initializers: still eligible — run
  once per *instance*, and most call sites create more than one instance
  across a test run, giving real per-test differentiation in the common
  case. (A true singleton instance would have the identical hazard, but
  that is a runtime fact syntax alone cannot see — an accepted gap, the
  same trade-off this codebase's other syntax-only checks already make.)
- Computed properties (`static var x: Bool { ... }`, no stored
  initializer): still eligible — the accessor body runs on every access,
  never memoized, regardless of `static`.
- A closure *held by* a startup-only binding (`static let f: () -> Bool =
  { true }`): still eligible — the closure *value* is created once, but
  its *body* runs once per call to `f()`, not once at binding time. The
  detector stops climbing at the first enclosing function/closure/accessor
  boundary for exactly this reason.

**Explicitly not attempted here** (multi-image — the other half of S6's
name): whether the runtime behaves correctly when
`MutantKitSchemataRuntimeC`, a static library, ends up linked into more
than one Mach-O image in the same process (an app plus a framework it
links, say) — each image would get its own copy of the runtime's static
globals (the `pthread_once`-guarded parsed token, the atomic event-sequence
counter), which does not break per-chunk correctness (namespaces are
already scoped per chunk, and a chunk is scoped to one target) but would
mean the event-sequence counter is no longer globally monotonic across
images sharing one process. No acceptance test yet proves this either way.

## Addendum 7: S7 (scoped) — ResultClassifier gains a schemata path

The full S7 ("auto/hybrid execution mode") would mean `MutationRunner`/
`RunCommand` actually choosing between isolated and schemata backends per
run — which needs a real build orchestrator (compiling an actual chunk via
a real `xcodebuild`/`swift build` invocation, not the throwaway packages
S2/S3's acceptance tests stage), batch execution logic (running one already-
built binary/test-bundle repeatedly with a different requested token per
mutant, collecting `SchemataEvidenceCollector` output after each), wiring
into `Configuration`'s already-present but unimplemented `execution
.strategy` field, and an integrity check for schemata results analogous to
`Integrity.swift`'s existing `mutationNotActivated` check. All of that
touches the same production code paths every real isolated-mode run
already depends on — a different risk profile than S1-S6, which were all
self-contained new subsystems with zero blast radius on existing behavior.

Given that, this stage is deliberately narrower: `ResultClassifier` gains
`classifySchemata(_:evidence:context:coverage:)`
(`SchemataResultClassifier.swift`), the schemata-backend counterpart to the
existing `classify(_:activation:coverage:)` — same "an unknown never
becomes `.survived`, and a kill needs proof too" discipline, gated on
`SchemataMutationEvidence.verify(against:)` (the real production gate,
not the merely-self-consistent `provesScorableExecution`) rather than
`ActivationEvidence.provesActivation`. A new, independent function, not an
overload of the existing isolated-mode ones — those already have several
call sites (`confirmKill`, `confirmCrash`, `confirmTimeout`) built around
isolated mode's one-build-per-mutant retry flow, which schemata's shared-
build, many-mutants-per-process model does not resemble. `MutationRunner`
does not call any of this yet, and nothing about existing isolated-mode
behavior changes.

Left for whenever the full S7 integration is actually undertaken: the
build orchestrator, batch/retry execution logic for schemata (`confirmKill`/
`confirmCrash`/`confirmTimeout` equivalents), `Configuration.execution
.strategy` wiring, an `Integrity.swift` check for schemata results, and
the actual `MutationRunner`/`RunCommand` call sites that would make any of
this reachable from a real `mutantkit run`.

## Addendum 8: a fourth review, several real bugs found and fixed

A fourth review, done after S1-S7 all merged, found genuine defects — not
just scope/design questions like earlier addenda. Recorded here with the
same discipline: what was actually wrong, what the fix is, and what is
still explicitly not done.

**P0: a chunk spanning more than one file could not compile at all.**
`BoolLiteralSchemataLowerer.lower` prepended `runtimePreamble` (the
`@_silgen_name` declaration) to *every* touched file. `SchemataChunkPlanner`
groups by target/module/product with no file-boundary awareness, so a
chunk spanning two files was a real, reachable shape — and would fail with
"invalid redeclaration of `__mutantkitIsActive`" the moment the compiler
saw both files in the same module, breaking the *entire chunk's* build,
not just one embedded mutant. Fixed: the declaration now lives in exactly
one generated file per chunk (`BoolLiteralSchemataLowerer
.runtimeDeclarationFile`, deterministic name and content so sibling
chunks targeting the identical target/module/product produce it byte-
identically). `SchemataSwiftPMRuntimeAcceptanceTests
.multiFileChunkCompilesLinksAndActivatesIndependently` proves this with a
real two-file chunk and a real `swift build` — this is exactly the kind of
bug unit-level reasoning about the lowerer's output could not have caught,
since every existing unit test happened to use single-file chunks.

**P0: S6's startup-mutant exclusion was reasoning about a model this
codebase never adopted.** Documented in full in addendum 6's own
correction below — the short version: `SchemataStartupDetection` assumed a
many-mutants-per-process execution model where a memoized `static let`
could leak one test's activation into another's. The actual, deliberately-
chosen model (fresh process per mutant, one requested token fixed for that
process's entire lifetime, set before the process even launches) has no
such hazard — a memoized value there is computed exactly once *with the
process's one token already active*, indistinguishable from how isolated
mode's own one-mutation-per-binary model already works. The exclusion,
and the now-unused `SchemataStartupDetection` module and its dedicated
test file, are removed; `.processStartRequired` is no longer produced by
this lowerer (the `SchemataUnsupportedReason` case itself stays — a
genuinely different future backend might still need it).

**P0: `classifySchemata` credited an unproven pass as `.survived`.**
Mirrored isolated mode's `classifyPassing` too literally: there, an
unproven pass staying `.survived` is safe *because* `Integrity.swift`'s
`mutationNotActivated` check already exists downstream to catch it and
turn it into a loud violation. No schemata-aware integrity check exists
yet. Mirroring the pattern without its backstop meant nothing would ever
catch an unproven schemata pass — this file's own founding "an unknown
never becomes `.survived`" rule, silently broken for exactly the backend
that most needed it enforced. Fixed: `classifySchemata` now returns
`.infrastructureFailure` for this case, with a diagnosis explaining why
(revisit once a real schemata integrity check exists to be the actual
backstop).

**P0: `SchemataActivationEvidence.runNonce` was never actually observed
from the runtime.** The collector built activation evidence by copying the
*host's own expected* `runNonce`/`schemaArtifactID`/`manifestHash` into the
constructed evidence, rather than reading anything the runtime itself
reported — meaning `SchemataMutationEvidence.verify(against:)`'s nonce
check compared the host's expectation against itself, proving nothing. A
hit line from a stale evidence file (a leftover from an earlier run
sharing the same path) with a coincidentally-reused PID could be credited
to a fresh run. Fixed (partially — see "still open" below):
`MutantKitSchemataRuntimeC` now reads `MUTANTKIT_SCHEMATA_RUN_NONCE` at
the same point it reads the token, and embeds it in every hit line
(`<namespace>:<localIndex>:<pid>:<eventSequence>:<runNonce>`).
`SchemataEvidenceCollector` now matches hits on token, PID, *and* run
nonce all at once, and only ever reports a `runNonce` in the returned
evidence when a hit that already carried that identical nonce was found —
never assumed. `schemaArtifactID`/`manifestHash`/`imageUUID` remain host-
supplied, not independently runtime-observed; see "still open."

**P1: the runtime recorded a hit line on every activation, not just the
first.** A mutated site reached in a loop wrote one line per iteration —
wasted I/O the scoring runtime never needed (only "was it hit at all"
matters for scoring, not a count). Fixed: `mutantkit_hit_recorded`, an
`atomic_bool` guarding `mutantkit_record_hit`, records at most once per
process regardless of how many times an active site executes.

**P1: `SchemataChunkPlanner`'s chunk-ID collision check had a real gap at
the truncated length it used.** `chunkID` used `ContentHash.shortDigest`
(64 bits, truncated) and fed directly into `SchemataChunk.namespace`
(itself a second hash of the chunkID string). The collision check's
`existing == program.chunkID` exemption assumed "identical chunkID string
= the same chunk, not a collision" — true only if `chunkID` itself is
collision-resistant, which a 64-bit truncated hash is not to the standard
this codebase already holds every other trust-boundary identity to. Fixed:
`chunkID` now uses `ContentHash.of` (full SHA-256), the same fix already
applied to `schemataPlanID` and `sourceEmbeddingID` for the identical
reason.

**P1: Xcode injection overwrote a project's own existing build settings.**
`OTHER_LDFLAGS=-lMutantKitSchemataRuntime` and
`LIBRARY_SEARCH_PATHS=<path>` as command-line overrides *replace* whatever
the project already had, rather than appending to it — a real project
with its own linker flags would lose them. Fixed:
`OTHER_LDFLAGS=$(inherited) -lMutantKitSchemataRuntime` and
`LIBRARY_SEARCH_PATHS=$(inherited) <path>`.
`runtimeLinksAndActivatesViaBuildSettingOverridesOnly` now gives the
fixture project a pre-existing `OTHER_LDFLAGS: -framework Accelerate` and
inspects the *built binary* via `otool -L` to confirm both the pre-
existing and injected linkage survive — a merely-successful build would
not have proven this, since nothing in the fixture's code actually calls
an Accelerate symbol.

### Still open (recorded, not attempted here)

- **`schemaArtifactID`, `manifestHash`, and `imageUUID` remain host-
  supplied, not independently confirmed by the runtime at process
  startup.** A "runtime protocol v2" — a distinct startup event the
  runtime emits with its own observed build/manifest/image identity,
  separate from a hit event — would close this the rest of the way. Not
  attempted here: it is a real runtime ABI redesign, not a bounded fix,
  and (per addendum 3, still true) `selectedToken == requestedToken`
  already means `provesActivation` fails closed on every case that
  matters today; this closes the *remaining* gap around a compromised or
  badly-misconfigured evidence path, not the score-worthiness gate
  itself.
- **`SchemataXcodeRuntimeAcceptanceTests` still only proves a test's
  pass/fail flips — it collects no runtime evidence at all.** Wiring
  `SchemataEvidenceCollector` into the Xcode path (the built test bundle
  writing to a known evidence path, read back after `test-without-
  building` exits) is straightforward in principle but not done here.
- **No acceptance coverage yet for multi-image, a schemata-embedded
  mutant crashing, or one timing out.** Every acceptance suite to date
  proves the pass/fail-flip and evidence-collection mechanisms; none
  exercises the crash or timeout paths through `classifySchemata`
  end-to-end, and none proves the runtime behaves correctly when its
  static globals are duplicated across more than one Mach-O image sharing
  a process (a concern addendum 6 already named as unstarted).
- **The C runtime's ABI still uses `@_silgen_name` and a double-
  underscore-prefixed C symbol.** Both work reliably across every
  toolchain version tested so far, but neither is the hardened choice a
  production ABI spanning many Xcode/Swift versions would want — a real
  generated module map plus ordinary C import, injected via `-I`, would
  be more robust. Deliberately not attempted: it is a larger design
  change touching both the SwiftPM and Xcode paths together, not a
  bounded fix, and nothing has broken from the current choice yet.

None of S5 (a second operator's lowering) or the real `MutationRunner`
integration should start until whichever of the above items actually
blocks them is addressed — the same staging discipline every prior
addendum in this ADR already asks for.

## Addendum 9: fifth review, the generated-file fix from addendum 8 did not
survive contact with a real Xcode project

A re-review of the addendum-8 state (`ea24f61`) found that its own fix for
the multi-file "invalid redeclaration" bug — emitting the runtime
declaration into a dedicated `.generated.swift` file, appended once per
chunk — does not actually solve S3's stated goal ("no `.pbxproj` edit") in
general. It only appeared to, because both places that fix was proven
against (the SwiftPM acceptance package, and the xcodegen-generated Xcode
fixture) auto-discover every file under a source directory. A real,
pre-existing Xcode project lists specific files in its own Compile
Sources build phase; writing a new file to disk does not add it there.

**P0: the generated declaration file is invisible to a real Xcode
project's Compile Sources phase.** Fixed by removing the generated file
entirely: `BoolLiteralSchemataLowerer.lower(_:sources:)` now prepends
`runtimePreamble` into whichever *existing* file in the chunk's full
`sources` set sorts first by `relativePath` — deterministic and stable
across every sibling chunk of the same target, since `sources` is always
that target's complete file listing, not just the subset a given chunk
happens to touch. No new file is ever created.
`multiFileChunkCompilesLinksAndActivatesIndependently` was updated to
assert `loweredSources.count` is unchanged (no new file) and that the
declaration lands specifically in the lexicographically-first of the
chunk's two real files — proven again with a real `swift build`.

**P0: `SchemataTargetInfo`'s `(target, module, product)` key could merge
mutations from two unrelated projects.** Two different Xcode projects (or
SwiftPM packages) can trivially share target/module/product names; the
planner had no way to tell them apart. Fixed: `SchemataTargetInfo` gained
a `projectIdentity` field, threaded into `SchemataChunkPlanner`'s internal
grouping key and `chunkID` derivation. Callers are expected to pass a
build-system-stable identity (resolved project path or target GUID for
Xcode, package identity for SwiftPM) — not a display name. A new test
(`identicallyNamedTargetsInDifferentProjectsNeverShareAChunk`) pins that
two identically-named targets in different projects still produce
separate chunks.

**P0: `MutationApplicationEvidence.provesActivation` conflated two
different strengths of proof.** Its generic delegation — `ActivationEvidence
.provesActivation` (sound on its own) for `.isolated`, `SchemataMutationEvidence
.provesScorableExecution` (internal self-consistency only, not the real
gate) for `.schemata` — let a caller read one boolean off the enum with no
way to tell which guarantee they actually got. Removed entirely; callers
must switch on the case and use each backend's own, correctly-scoped
property. Also renamed `provesScorableExecution` to
`provesInternalConsistency`, since the old name read as though it *were*
the score-worthiness gate rather than the cheap first filter `verify
(against:)`'s own doc comment already said it was.

**P1: an empty/unset run nonce silently degraded the stale-replay
protection addendum 8 added.** The C runtime previously wrote a hit line
with an empty `runNonce` field whenever `MUTANTKIT_SCHEMATA_RUN_NONCE`
was unset, and `SchemataEvidenceCollector` would happily match it against
an equally-misconfigured (also-empty) `context.runNonce` — exactly the
kind of accidental match the nonce exists to prevent. Fixed in both
directions: the C runtime now refuses to write a hit line at all when its
own run nonce is empty (a misconfigured harness gets "no evidence
collected," a loud `infrastructureFailure`, not a usable-looking but
unprotected hit); and the collector now treats an empty
`context.runNonce` as never matching, regardless of what is in the file.

**P2: `mutantkit_parse_token`'s `sscanf` accepted trailing garbage.**
`sscanf(raw, "%" SCNu64 ":%" SCNu32, ...)` returning `2` only means two
conversions succeeded, not that the whole string was consumed — a token
value like `"42:3garbage"` parsed as `(42, 3)` with the trailing text
silently ignored. Fixed with `%n` plus an explicit `raw[consumed] == '\0'`
check.

**P2: a non-positive `maxChunkSize` silently produced one unbounded
chunk.** `SchemataChunkPlanner.plan` now rejects `maxChunkSize <= 0` with
`SchemataChunkPlanningError.invalidMaxChunkSize` before doing anything
else, instead of the array-chunking helper quietly treating it as "one
big chunk."

**Deferred, evaluated and judged not worth the churn right now:**
`SchemataPlan.decodeAndValidate` still validates only against its parent
`MutationPlan`, not against the *current* execution context's backend/
toolchain/lowerer/runtime-ABI versions — real, but `decodeAndValidate` has
no production caller yet (only test round-trips), so there is no concrete
call site to design the extended signature against without guessing.
`classifySchemataPassing` still checks a coverage-miss before consulting
evidence, which could in principle hide a genuine coverage/evidence
contradiction — but `coverage` is always `nil` from every real caller
today (no schemata coverage source exists yet), so the branch this review
flagged is currently unreachable in practice. Both remain open items for
whichever future change gives them a real caller — revisit then rather
than designing them against a hypothetical one now.

**Still open (unchanged from addendum 8, not attempted this round):** the
Xcode PID problem (`SchemataEvidenceCollector.collectActivationEvidence`
requires `expectedProcessID`, which the SwiftPM path can read directly
from its own `Process` but the Xcode path cannot, since `xcodebuild`
launches `xctest` as an unobserved descendant) is real and still
unaddressed; `SchemataXcodeRuntimeAcceptanceTests` still collects no
runtime evidence, only pass/fail. Closing this needs the "runtime startup
event" protocol addendum 8 already named as future work — a real ABI
redesign, not a bounded fix, and out of scope for this round alongside
everything else already listed as still open above.
