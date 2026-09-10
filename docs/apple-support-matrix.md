# Apple support matrix

MutantKit's real, stated support contract across the axes that actually
vary: Swift, Xcode, macOS, SwiftPM, XCTest, Swift Testing, iOS Simulator,
`isolated`, `schemata`. Four labels, used consistently across every table
below:

- **Supported** — proven end-to-end (`doctor`/`plan`/baseline/killed/
  survived/report, `integrity == 0`) against a real toolchain, and kept
  that way by a test that still runs. A row earns this by citation, not
  by "the code path exists."
- **Tested** — proven at least once, but not continuously (a one-off
  manual run, or a narrower proof than the full pipeline above).
- **Best-effort** — expected to work from the code's own design, not
  independently proven; not known broken.
- **Unsupported** — proven broken, or explicitly out of scope, with the
  reason on record.

This does not weaken any of the schemata backend's own trust guarantees —
runtime image identity, UUID validation, the bundled runtime, or simulator
acceptance. No source
in `Sources/AppleBuildAdapters`, `Sources/SwiftFrontend`, or the schemata
runtime changed to produce this document; it is a synthesis of evidence
that already existed, cross-referenced in one place for the first time.

## Toolchain floor

Two different questions get conflated under "what Swift/Xcode/macOS
version does MutantKit need" — this matrix answers them separately.

### Building and running MutantKit itself

| | Requirement | Status | Proof |
|---|---|---|---|
| macOS | 14+, Apple Silicon | **Supported** | `README.md`'s own `## Install`; `Package.swift`'s `platforms: [.macOS(.v14)]` |
| Xcode | 16+ | **Supported** (documented; not asserted anywhere at build or run time) | `README.md`'s own `## Install` |
| Swift | 6.0+ | **Supported**, hard-enforced | `Package.swift:1` — `// swift-tools-version:6.0`, unchanged since the project's first commit; SwiftPM refuses to resolve a `6.0`-tools package on an older toolchain, so this floor cannot silently regress |
| Intel Mac | building from source only, no prebuilt binary | **Supported** for source builds, **unsupported** for `brew install`'s prebuilt path | `README.md`'s own `### Building from source`: "platforms the prebuilt binary does not cover yet (Intel Macs, ...)" |

The "Xcode 16+" line is CI-enforced, not just documented:
`ci.yml`'s `lint` job runs a `Toolchain floor (Xcode 16+, Swift 6+)` step
that fails the build if `xcodebuild -version` reports a major version below
16 or `swift --version` reports an Apple Swift major version below 6.
Every other job's own `Toolchain` step still only prints
`swift --version && xcodebuild -version` for failure context — the `lint`
job's floor check is the single gate, so a runner-image drift that drops
below 16+/6.0+ fails fast instead of silently changing what CI proves.
The GitHub-hosted `macos-15` runner image still ships whichever
Xcode/Swift version it currently carries; this repo pins neither, it only
refuses to run below the floor.

### What toolchain a target project (the project under test) can use

A separate, real question: once MutantKit is built (with a *current*
toolchain), what is the oldest toolchain a project it mutates can itself
require?

| Target toolchain | Status | Proof |
|---|---|---|
| Xcode 15.2 / Swift 5.9.2 / macOS 14.2 SDK | **Tested** once, not continuously | A real GitHub Actions run (`github-actions macos-14`, internal and not part of this public repo — formerly `Benchmarks/results/compatibility/xcode-15.2-swift-5.9-macos-14/gate-result.json`) with `mutantKitBuildSucceeded: true`, `mutantKitRunSucceeded: true` against a real, minimal SwiftPM fixture (1 file, `relational-operator-replacement`, one mutant killed). MutantKit itself was built with Xcode 16.2 in that same run — this proves the *target project's* toolchain floor, not a lower build floor for MutantKit itself. |
| Anything older than Xcode 15.2 / Swift 5.9.2 | **Unknown** | Never attempted; no claim either way. |

That gate was built for a different purpose (a fair toolchain for comparing
against another mutation-testing tool) and ran once via manual dispatch, not
on every push — real evidence, correctly scoped as "tested once," not
"supported" in the continuous sense every other table in this document uses.

## Project kind × test framework (`isolated` mode)

Every row proven by a real acceptance test running the full pipeline
(`doctor`, `plan`, baseline, a real killed mutant via a real
`XCTAssert`/`#expect` failure, `report`, `integrity == 0`) against a real
toolchain — summarized here, with each row's own acceptance-test file as
its proof:

| Project kind | Test framework | Status | Proof |
|---|---|---|---|
| `swiftPackageMacOS` | XCTest | **Supported** | `SwiftPackageMacOSXCTestAcceptanceTests` |
| `swiftPackageMacOS` | Swift Testing | **Supported** | `SwiftPackageMacOSAcceptanceTests`/`SwiftPackageMacOSCoverageAcceptanceTests` |
| `xcodeProject` | XCTest | **Supported** | `XcodeAcceptanceTests`/`XcodeProjectAcceptanceTests`, `XcodeCoverageSelectionAcceptanceTests` |
| `xcodeProject` | Swift Testing | **Supported** | `XcodeSwiftTestingAcceptanceTests` |
| `xcodeWorkspace` | XCTest | **Supported** | `XcodeAcceptanceTests`/`XcodeWorkspaceAcceptanceTests` |
| `xcodeWorkspace` | Swift Testing | **Supported** | `XcodeSwiftTestingAcceptanceTests` |
| `swiftPackageApple` (iOS-only SwiftPM package, driven via `xcodebuild`) | XCTest | **Supported** | `SwiftPackageIOSAcceptanceTests` |

`selectCoveringTests`-narrowed per-test coverage attribution is proven at
the root for every Xcode Swift Testing scheme, not just the fixtures that
originally exercised it — a real bug (`TestIdentifier
.onlyTestingArgument` missing the trailing `()` `xcodebuild` requires to
match a Swift Testing `@Test` at all) was found and fixed at that shared
call site, proven by `XcodeSwiftTestingAcceptanceTests
.swiftTestingCoverageSelectionNarrowsAttribution`.

## Project kind × destination (`schemata` mode)

Full detail, including exactly why the two unsupported rows are
unsupported and the "fallback is not failure" distinction, lives in
`docs/schemata-support-matrix.md` — summarized here for this matrix's own
completeness:

| Project kind | Test framework | Destination | Status |
|---|---|---|---|
| `swiftPackageMacOS` | XCTest / Swift Testing / mixed | host (macOS) | **Supported** |
| `xcodeProject` | XCTest | iOS Simulator | **Supported** |
| `swiftPackageApple` | XCTest | iOS Simulator | **Unsupported** — root-caused (`resolveSchemataBuildReceipt` fails to parse build settings for this project-kind/build-system pairing); falls back to `isolated` automatically, score stays correct |
| `xcodeWorkspace` | XCTest | iOS Simulator | **Unsupported** — no schemata target-resolution case exists for `.xcodeWorkspace` at all; whole-run degradation to `isolated`, not per-mutant |

`xcodeProject`/Swift Testing is not a separate schemata row: schemata's
own result classification reads the same `.xctestrun`-driven output
regardless of which framework produced it, proven once at the SwiftPM
level (`docs/schemata-support-matrix.md:34-39`).

## UI tests (XCUITest)

| Project kind | Test framework | Execution | Status |
|---|---|---|---|
| `xcodeProject`/`xcodeWorkspace`, existing UI test target/scheme | XCUITest | `isolated`, iOS Simulator | **Supported** — `AccessibilityUISubstrateAcceptanceTests.uiTestOnlyMutationIsKilled` proves a real, operator-generated mutant (`swift.core.relational-operator-replacement`) killed exclusively through a UI test target, end to end |

No UI-automation DSL and no new project kind — an existing Xcode
project/workspace UI test target/scheme is driven the same way any other
`isolated`-mode test target is. Full account:
`docs/execution.md`'s UI-test section and
`Research/phase5a-ui-test-substrate-2026-09/README.md`. This row was
declared supported in `README.md`'s own "Supported today" table before
v0.4 Trust Closure Workstream D but had no citation in this matrix — the
underlying evidence was real and already existed, this closes the
citation gap between the two documents, not a correctness gap.

## Test selection (`selectCoveringTests`) and batching (`testBatchSize`)

Two independent axes, both declared **supported** in public docs
(`docs/benchmarks.md`, `docs/configuration.md`) but, until v0.4 Trust
Closure Workstream B, without a shared citation naming which test
framework each was actually proven against:

| Selection mechanism | XCTest | Swift Testing |
|---|---|---|
| `-only-testing:` (unbatched, `selectCoveringTests` alone) | **Supported** — `XcodeCoverageSelectionAcceptanceTests` | **Supported** — `XcodeSwiftTestingAcceptanceTests.swiftTestingCoverageSelectionNarrowsAttribution` |
| Batched `.xctestrun` `OnlyTestIdentifiers` (`testBatchSize` + `selectCoveringTests`) | **Supported** — `XcodeBatchTestingAcceptanceTests` | **Supported** (v0.4 Workstream B) — `XcodeBatchTestingSwiftTestingAcceptanceTests`, confirming empirically that the bare `qualifiedName` (no trailing `()`) is the correct `OnlyTestIdentifiers` form for a Swift Testing target, against a real `xcodebuild` batch run |

Before Workstream B, `BatchXCTestRunBuilder.build(items:)`'s own doc
comment named this Swift Testing cell explicitly as "never verified
empirically, only for XCTest" — a real supported-path correctness gap this
audit closed with a targeted acceptance test rather than narrowing the
contract. `testBatchSize` itself remains a non-default, opt-in setting
(`docs/benchmarks.md`: slower than `simulatorPool` at scale, kept for
CI runners that restrict simulator-clone provisioning) — that recommendation
is unchanged; only the correctness-evidence gap for its Swift Testing cell
is closed.

**Recorded residual scope (not a v0.4 blocker):** both batched-selection
acceptance suites (`XcodeBatchTestingAcceptanceTests` and its Swift Testing
mirror) exercise exactly one shape — two mutants whose selection is the
identical two-test pair, landing in one batch, everything killed as
expected. Neither one separately proves single-sided narrowing within a
batch (test A's own batched selection actually excludes test B, and vice
versa) or the negative/fail-closed cases (an invalid `OnlyTestIdentifiers`
entry, or an unexpected test executing outside the requested selection).
The invalid-selection fail-closed guarantee *is* covered, but only at the
unit level and framework-agnostically —
`BatchXCTestRunBuilderTests.selectionMatchingNoTargetThrows` pins that a
selection naming a target with none of the batch's own tests throws
`BatchXCTestRunError` rather than silently running everything. This gap
predates Workstream B (the pre-existing XCTest suite never covered these
shapes either) and is not specific to Swift Testing; it is deferred as
future acceptance-test work, not a v0.4 correctness gap, since it does not
change any current supported/default behavior.

## Apple platform breadth (macOS / iOS / tvOS / watchOS / visionOS)

| Platform | `isolated` | `schemata` |
|---|---|---|
| macOS | **Supported** | **Supported** (`swiftPackageMacOS`) |
| iOS | **Supported** | **Supported** (`xcodeProject`, iOS Simulator) |
| tvOS | **Tested at the unit level, real-simulator proof deferred** | **Unsupported, explicitly out of scope** |
| watchOS | **Tested at the unit level, real-simulator proof deferred** | **Unsupported, explicitly out of scope** |
| visionOS | **Tested at the unit level, real-simulator proof deferred** | **Unsupported, explicitly out of scope** |

**tvOS/watchOS/visionOS, `isolated` mode**: three real, confirmed
iOS-only hardcodings (destination-string labeling, device name/UDID
resolution, simulator-lease mutual exclusion) were found and fixed, with
unit-test coverage — including visionOS's own real
`SimRuntime.xrOS-...` → `platform=visionOS Simulator` translation, see
`Tests/MutantKitTests/Unit/DestinationResolverTests.swift`. **No
real-simulator end-to-end acceptance test exists yet for these three
platforms** — the fix is proven at the unit level, not by an actual
`xcodebuild test` run against a real tvOS/watchOS/visionOS Simulator
destination the way the iOS rows above are. The adapter code itself is
finished and needs no further changes — only that one acceptance test
remains unwritten, blocked on CI/simulator-runtime availability, not on
anything else.

**tvOS/watchOS/visionOS, `schemata` mode**: explicitly out of scope, not
merely untested — `SchemataRuntimePlatform.resolve(destination:)` fails
closed (`nil`, never a guess) for all three
(`Tests/MutantKitTests/Unit/SchemataRuntimePlatformTests.swift` pins the
exact destination-string shapes), and no schemata runtime archive is
built or bundled for any of them.

**Explicitly out of scope, both modes**: physical iOS devices and Mac
Catalyst. `schemata` fails closed for both, by the same mechanism as
above (`docs/schemata-support-matrix.md:41-49`). `isolated` mode's status
on these is genuinely unattempted, not proven broken — no claim either
way.

## Operator verdict parity (`isolated` vs `schemata`)

Every schemata-eligible, default-enabled operator is differentially
tested against the isolated backend on the same `MutationPoint`s, on
every run — see `docs/schemata-support-matrix.md`'s own "Operators"
table for the full per-operator test citations. All six
(`bool-literal-inversion`, `relational-operator-replacement`,
`logical-connector-replacement`, `unary-not-removal`,
`return-value-replacement`, `ternary-branch-swap`) show 100% verdict
parity today. `ArithmeticOperatorReplacementOperator` has no registered
schemata lowerer and always runs `isolated`, regardless of profile — this
matrix does not re-measure that parity, only cross-references it.

## The CI/acceptance matrix this lands in

**Corrected 2026-09.** This section previously described a `route`/`build`
dynamic-matrix design (path-based routing into a full-vs-narrow run, a
shared `build` job reused by `unit-fast`/`unit-system`/`acceptance`) with
specific `ci.yml` line-number citations. That design does not exist in the
CI actually running today — it was lost in the `git-projector publish`
incident recorded in `HANDOVER.md` and was not restored in that shape; the
restoration (commit `e7fb818` and its `integration/release-ci-repair`
merge) rebuilt a deliberately simpler workflow instead, by design, per that
workflow's own comments. Job names are cited below instead of line numbers,
since line numbers are exactly what drifted silently last time.

The public repo's `.github/workflows/ci.yml`, run on every push/PR (no
`route`, everything unconditional):

- **`lint`**, **`complexity`**, **`analyze`** — static checks (format/lint,
  cognitive-complexity gate, `swiftlint analyze`).
- **`unit`** — the full `swift test` unit suite, once, no fast/system
  split.
- **`acceptance`** — a matrix of all 19 fixtures from
  `Scripts/ci-fixtures.json` (6 host-only SwiftPM, 13 requiring a real iOS
  Simulator), each job doing its own build; there is no shared `build` job
  and no path-based narrowing — every fixture runs on every push.
- **`ror-schemata-differential`** and **`ios-simulator-schemata-runtime`**
  prove the schemata runtime's real linked behavior (not just lowered
  source), on macOS and iOS Simulator respectively.
- **`merge-gate`** — the one required status. With no `route` job there is
  no execution plan to derive an expectation from, so it instead asserts,
  unconditionally, that `lint`, `complexity`, `unit`, `acceptance`,
  `ror-schemata-differential`, and `ios-simulator-schemata-runtime` all
  report `success` — a skip or cancellation on any of them fails the gate,
  by the same "no plan, so nothing here is ever a deliberate skip"
  reasoning as its own comment states.

Separately, `.github/workflows/release-validation.yml` (`workflow_dispatch`
only — deliberately not run on every push, since it costs real minutes on
real hardware) runs **`release-package`** (builds the real release tarball
once), **`release-bundled-schemata-macos`** and
**`release-bundled-schemata-ios-simulator`** (each a clean-machine
end-to-end proof against the *extracted, bundled* runtime — no
`MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` override in either job, the
actual end-user path), and **`release-validation-gate`**. `release.yml`'s
own `require-validation` job refuses to publish a tag whose commit has no
successful run of `release-validation.yml`, so a forgotten manual dispatch
blocks the release rather than shipping unvalidated.

This is a real CI/acceptance matrix, not merely a fixed unit-test job —
every acceptance-test class this document names is exercised by it on
every push (`ci.yml`) or before every release (`release-validation.yml`).

## Summary

| Axis | Status |
|---|---|
| Swift 6.0+ (build MutantKit) | Supported, hard-enforced by `Package.swift` |
| Xcode 16+ / macOS 14+ Apple Silicon (build/run MutantKit) | Supported, documented, CI-enforced (`ci.yml` toolchain-floor step) |
| Target project on Xcode 15.2 / Swift 5.9.2 / macOS 14.2 | Tested once, not continuous |
| SwiftPM (macOS) × XCTest / Swift Testing | Supported, both modes |
| Xcode project/workspace × XCTest / Swift Testing | Supported, `isolated`; `xcodeProject`+XCTest also `schemata`-supported |
| iOS Simulator | Supported, both modes (per the table above) |
| macOS / iOS | Supported, both modes |
| tvOS / watchOS / visionOS | Best-effort (`isolated`, real-simulator proof deferred); unsupported (`schemata`, explicit) |
| Physical iOS device / Mac Catalyst | Unsupported (`schemata`, explicit fail-closed); unknown (`isolated`, unattempted) |
| CI/acceptance matrix | Real and comprehensive — 19 fixtures, isolated/schemata differential, bundled-runtime clean-machine E2E |
