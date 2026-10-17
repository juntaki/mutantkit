# Schemata mode: supported configurations

`execution.strategy: schemata` links a small C runtime into the mutated
build and confirms activation from the process itself, instead of running
every mutant as a fully isolated build+test. It reuses a shared schemata
build where supported; actual performance is workload-dependent, and this
is not a benchmarking claim — only the configurations below are covered at
all, and everywhere else, MutantKit falls back to isolated mode
automatically, with the score staying correct either way.

This matrix is not aspirational. Every row is proven by a real end-to-end
run against a real project (a real `swift build`/`xcodebuild`, a real
simulator where noted, a real linked runtime), not inferred from which
adapter types happen to declare `SchemataBuildable` conformance. "Supported"
here means all of:

- a real E2E run against a real project,
- schemata actually activated for the run's own embeddable candidates
  (not a silent 100% fallback to isolated),
- zero integrity violations,
- zero *unexpected* isolated fallback (a candidate the run's own baseline
  coverage already knows is unreached is expected to fall back — see
  "Fallback is not failure" below).

`mutantkit doctor`'s own "Schemata execution" line reports exactly this
table's Supported/Unsupported column for the project it is run against —
`ExecutionCapabilitiesDiagnosis.schemataSupported(for:)` is the one place
that answers it, kept next to this doc specifically so the two cannot
drift apart; update both together.

| Project kind | Test framework | Destination | Status | Proof |
| --- | --- | --- | --- | --- |
| `swiftPackageMacOS` | XCTest | host (macOS) | **Supported** | `SchemataSupportedMatrixSwiftPMMacOSAcceptanceTests.xcTestFullyActivates` |
| `swiftPackageMacOS` | Swift Testing | host (macOS) | **Supported** | `SchemataSupportedMatrixSwiftPMMacOSAcceptanceTests.swiftTestingFullyActivates` |
| `swiftPackageMacOS` | XCTest + Swift Testing, mixed in one bundle | host (macOS) | **Supported** | `SchemataSupportedMatrixSwiftPMMacOSAcceptanceTests.mixedFrameworksFullyActivate` |
| `xcodeProject` | XCTest | iOS Simulator | **Supported** | `SchemataMatrixIOSSimulatorAcceptanceTests.fullyActivatesNoFallback` + `startupHitAndReceiptUUIDMatchOnIOSSimulator` (override) + `ReleaseBundledSchemataXcodeIOSSimulatorAcceptanceTests.xcodeProjectSchemataRunSucceedsFromBundledRuntimeAlone` (bundled release runtime, no override) |
| `swiftPackageApple` (SwiftPM package for a non-host Apple platform) | XCTest | iOS Simulator | **Unsupported** | `SchemataSupportedMatrixSwiftPackageAppleAcceptanceTests` — pinned, see below |
| `xcodeWorkspace` | XCTest | iOS Simulator | **Supported** | `SchemataSupportedMatrixXcodeWorkspaceAcceptanceTests.requestingSchemataExecutesAndOnlyUncoveredMutationsFallBack` |

Swift Testing vs. XCTest is not tested separately for `xcodeProject`: schemata
activation and evidence collection read the same `.xctestrun`-driven test
result regardless of which framework produced it (there is no
framework-specific branch anywhere in the schemata result-classification
path) — proven once, for the SwiftPM matrix rows above, which is where the
mixed-framework case actually matters.

Out of scope for schemata support, not merely "unsupported here": physical
iOS devices, Mac Catalyst, tvOS, watchOS, and visionOS. `SchemataRuntimePlatform
.resolve(destination:)` fails closed (`nil`, never a guess) for every one of
these — see `Tests/MutantKitTests/Unit/SchemataRuntimePlatformTests.swift`,
which pins the exact destination-string shapes. No schemata runtime is built
or bundled for any of them. This says nothing about isolated-mode support for
these platforms/destinations — that is a separate question this matrix does
not answer, and no claim about it should be inferred from schemata's own
scope here.

## SwiftPM packages with more than one test target on Xcode 27

The `swiftPackageMacOS` rows above were measured with one test target. With
Xcode 27 (Swift 6.4), `swift build --build-tests` links each test target into
its own bundle (`<Target>.xctest`) instead of one combined
`<Package>PackageTests.xctest`, and a package's library code is statically
linked into every one of them. For a package with two or more test targets the
chunk's build receipt cannot say which single image holds a target's code, and
the resolver refuses to pick one (`more than one built image was discovered and
none exactly matches a declared product containing target <name>`). Every
chunk then forfeits schemata and its mutants run in isolated mode, reported in
`fallbackReasonCounts["buildReceiptUnavailable"]`. Results stay correct; there
is no schemata speedup for such a package on Xcode 27. Xcode 26.5 and earlier
resolve the single combined bundle and are not affected. Resolving it would
need a receipt that names every image containing the code, which the current
receipt format does not express.

## Why the two unsupported rows are unsupported

**`swiftPackageApple` + iOS Simulator.** This project kind resolves its
schemata targets via the same `SwiftPMTargetResolver` `swiftPackageMacOS`
uses, while the actual build runs through `XcodeBuildAdapter` (`xcodebuild`
— `swift build` cannot build a package with no macOS slice at all). That
specific pairing's `resolveSchemataBuildReceipt` fails for every chunk:

```
could not parse build settings for target <name>: expected exactly one
buildSettings entry named <name>, found 0
```

Every mutation forfeits schemata and re-runs isolated
(`fallbackReasonCounts["buildReceiptUnavailable"]`, the fail-closed
fallback) — the report is still fully correct, just never actually
schemata. Fixing the receipt resolver for this hybrid pairing is real
production work, out of scope for the phase that measured this matrix.

**`xcodeWorkspace`** was unsupported until schemata build receipt v3: the target-resolution switch had no
case for it, so every run degraded to isolated. It now reads the workspace's member
`.xcodeproj` files from `contents.xcworkspacedata`, resolves each like a lone project and
re-roots source paths at the workspace directory; a member that cannot be resolved is skipped
with a warning and its files run isolated. A scheme with an empty Build action (a test-only
scheme) is handled by reading the scheme's dependency targets from their own project.
Also exercised on macOS (native destination) against RxSwift's `Rx.xcworkspace`.

## Fallback is not failure

A `schemata`-requested run against a *supported* configuration can still
report individual mutations falling back to isolated — this is expected,
correct behavior, not a defect, in two cases:

- A candidate the run's own shared baseline coverage already proves is
  never reached (`SchemataMutationRunner.SchemataFallbackReason
  .knownUncovered`, or the equivalent dynamic `activation.noHit`/
  `activation.noStartup` reasons) is routed to isolated confirmation before
  or after a token attempt — the same "prove it or don't score it"
  discipline schemata mode always applies.
- A genuine, per-chunk infrastructure problem (`sharedChunkBuildFailure`,
  `buildReceiptUnavailable`) removes that chunk's mutations from schemata's
  fast path for that run, but never removes them from the report — they
  still get a real isolated verdict.

The **Supported** rows above were specifically verified against fixtures
where every discovered candidate is fully covered by a dedicated test, so a
healthy run shows genuinely zero fallback of any kind — proof the mechanism
itself has no gap, not merely that fallback stayed "expected" throughout.

## Operators

Every operator that is both schemata-eligible (has a `SchemataLowerer` in
`SchemataLowererRegistry.builtIn`) and default-enabled is verdict-parity
tested against the isolated backend, on the same `MutationPoint`s, for every
run:

| Operator | Differential coverage |
| --- | --- |
| `bool-literal-inversion` | `SchemataIsolatedDifferentialAcceptanceTests`, `XcodeSchemataIsolatedDifferentialAcceptanceTests` |
| `relational-operator-replacement` | `RelationalOperatorSchemataIsolatedDifferentialAcceptanceTests` |
| `logical-connector-replacement` | `LogicalConnectorSchemataIsolatedDifferentialAcceptanceTests` |
| `unary-not-removal` | `UnaryNotSchemataIsolatedDifferentialAcceptanceTests` |
| `return-value-replacement` | `ReturnValueSchemataIsolatedDifferentialAcceptanceTests` |
| `ternary-branch-swap` | `TernaryBranchSwapSchemataIsolatedDifferentialAcceptanceTests` |

All six show 100% verdict parity between backends today. `ArithmeticOperatorReplacementOperator`
is schemata-ineligible (no registered lowerer) and always runs isolated,
regardless of profile.

## Developer/debug escape hatch

`MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` still exists and still works —
point it at a directory containing `libMutantKitSchemataRuntime.a` (and an
`iphonesimulator/` subdirectory for the iOS-Simulator slice) to link a
locally-built runtime instead of a release install's bundled one. This is
for MutantKit's own development loop (running the acceptance suite from a
source checkout, or testing a runtime change before it's released) — an
ordinary user never needs to set it. See `SchemataRuntimeLibraryLocator`'s
own doc comment for the exact resolution order (override always wins over
the bundled path).

## Checking the schemata runtime before a run

`mutantkit doctor` reports a `Schemata runtime` item (`code: schemataRuntime`): whether the
runtime archive a schemata build links against can be found and trusted, per platform.

- A bundled runtime (a released install) is reported as verified: manifest, SHA-256 digest and
  runtime ABI version are checked.
- A developer override (`MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE`) is reported as an override,
  with a warning. Only the file's presence and source staleness are checked.
- Without either, the item is a warning, because isolated execution does not need the runtime.
  `doctor --require-schemata-runtime` makes it a failure, for qualification runs. Without a
  runtime every schemata chunk build fails and mutants report `infrastructureFailure`.
