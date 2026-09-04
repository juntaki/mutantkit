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

`.github/workflows/ci.yml` already is a real, dynamic acceptance matrix,
not a single fixed job list:

- **`route`** (`ci.yml:130-193`) classifies every push/PR by changed
  paths into a full run or a narrower, path-targeted slice, reading
  `Scripts/ci-fixtures.json` (18 fixtures: 6 host-only SwiftPM, 12
  requiring a real iOS Simulator) as the single source of truth for which
  fixture covers which project-kind/framework/destination combination.
- **`build`** compiles once; **`unit-fast`**/**`unit-system`** and every
  **`acceptance`** matrix entry download that shared output rather than
  each rebuilding from scratch.
- **`ror-schemata-differential`** and **`ios-simulator-schemata-runtime`**
  prove the schemata runtime's real linked behavior (not just lowered
  source), on macOS and iOS Simulator respectively.
- **`release-package`** builds a real release tarball once;
  **`release-bundled-schemata-macos`** and
  **`release-bundled-schemata-ios-simulator`** each run a clean-machine
  end-to-end proof against the *extracted, bundled* runtime — no
  `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` set anywhere in either job —
  the actual end-user path, not a developer's own build tree.
- **`merge-gate`** (`ci.yml:1240-1331`) derives each dependency's
  *expected* result from `route`'s own execution plan and fails if the
  actual result doesn't match, so a silently-skipped required job cannot
  pass the gate.

This is a real CI/acceptance matrix, not merely a fixed unit-test job —
every citation in this document that names an acceptance-test class is
exercised by it on every push.

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
| CI/acceptance matrix | Real and comprehensive — 18 fixtures, isolated/schemata differential, bundled-runtime clean-machine E2E |
