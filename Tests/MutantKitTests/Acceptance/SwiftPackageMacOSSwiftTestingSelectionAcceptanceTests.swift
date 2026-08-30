@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// P12-B: pins the discovery → filter → `swift test --filter` round trip for
/// Swift Testing tests against the real toolchain, the per-test coverage
/// attribution that round trip feeds, and the "zero executed is never an
/// authoritative pass" contract for a selection that matches nothing.
///
/// Before Phase B2, every test here failed against `main`:
/// `TestIdentifier.swiftTestFilterArgument` did not escape `(` `)` and
/// anchored with a bare `$`, so it matched the discovered identifier's own
/// list-output string zero times — confirmed live in B0 reproduction, and
/// fixed in `SwiftPackageMacOSAdapter.swift`. `impossibleSelectionIsNotAuthoritativePass`
/// additionally needs Phase B3's `classify` change to pass.
///
/// Deliberately goes through the adapter's own public `TestSelecting`/
/// `BuildAdapter` conformance rather than asserting on the private
/// `swiftTestFilterArgument` string itself (which is not visible outside
/// `SwiftPackageMacOSAdapter.swift` even via `@testable import`) — the
/// contract this phase must hold is about real `swift test` behaviour, not
/// about one candidate regex.
@Suite(
    "Acceptance: SwiftPM Swift Testing selected-test soundness",
    .enabled(if: Acceptance.isEnabled)
)
struct SwiftPackageMacOSSwiftTestingSelectionAcceptanceTests {
    private struct Staged {
        let workspace: URL
        let adapter: SwiftPackageMacOSAdapter
        let artifact: BuildArtifact
        let discovered: [TestIdentifier]
        let perTestCoverage: PerTestCoverageMap?
    }

    /// Async setup, shared across every test in this suite: stage the
    /// calibrated `SwiftPackageMacOS` fixture once, build it once, run
    /// `measurePerTestCoverage` once. `measurePerTestCoverage` alone is
    /// enough evidence for both the round-trip contract (B1-1) and the
    /// attribution-exclusivity contract (B1-3): each of its per-test
    /// iterations filters to exactly one discovered test and immediately
    /// attributes that one coverage-enabled run's executed lines to it, so a
    /// filter that zero-matches, over-matches, or matches the wrong test
    /// shows up directly in which lines end up attributed to which
    /// `TestIdentifier`.
    private static let staged = Task { try await Self.stageAndMeasure() }

    private func staged() async throws -> Staged {
        try await Self.staged.value
    }

    private static func stageAndMeasure() async throws -> Staged {
        let workspace = try Acceptance.stageFixture("SwiftPackageMacOS")
        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)
        let discovered = await SwiftPackageMacOSAdapter.enumerateTestIdentifiers(
            in: workspace, timeoutSeconds: 60, terminationGracePeriodSeconds: 5
        )
        let perTestCoverage = await adapter.measurePerTestCoverage(
            artifact: artifact, in: workspace, timeoutSeconds: 60
        )
        return Staged(
            workspace: workspace, adapter: adapter, artifact: artifact,
            discovered: discovered, perTestCoverage: perTestCoverage
        )
    }

    private func identifier(suffix: String, in discovered: [TestIdentifier]) throws -> TestIdentifier {
        try #require(
            discovered.first { $0.target == "PricingTests" && $0.qualifiedName == "PricingTests/\(suffix)" },
            "swift test list did not discover PricingTests/\(suffix)"
        )
    }

    // MARK: B1-1 — discovery → filter round trip

    /// `qualifiesForSeniorRate(age:)`'s single line (`age >= 65`) is exercised
    /// both by `seniorRateBoundary()` directly and by `totalWithLoyalty()`
    /// via `total(...)`. Its presence in the map at all, attributed to
    /// `seniorRateBoundary`, is direct proof that an isolated `swift test
    /// --filter` invocation built from that one discovered identifier really
    /// executed that one test — a zero-match filter (today's actual
    /// behaviour) contributes no lines for it at all.
    @Test("The seniorRateBoundary() identifier's own filtered run is attributed to it")
    func seniorRateBoundaryRoundTrips() async throws {
        let staged = try await self.staged()
        let seniorRateBoundary = try identifier(suffix: "seniorRateBoundary()", in: staged.discovered)

        let map = try #require(staged.perTestCoverage, "measurePerTestCoverage produced no attribution at all")
        let coverers = map.testsCovering(file: "Sources/Pricing/Pricing.swift", line: 16)
        #expect(
            coverers?.contains(seniorRateBoundary) == true,
            "line 16 (qualifiesForSeniorRate's body) was not attributed to seniorRateBoundary()'s own filtered run"
        )
    }

    /// `bulkDiscountRate(itemCount:)`'s `return 0.15` branch (line 24) is
    /// reached by `bulkDiscountRoughly()` (`itemCount: 50`) and, separately,
    /// by `total(...)`'s own unconditional call to it (`totalWithLoyalty()`,
    /// `totalWithoutLoyalty()`), but never by `seniorRateBoundary()`, which
    /// never calls `bulkDiscountRate` at all. `.contains`, not an exact-set
    /// comparison, because line 24 legitimately has more than one covering
    /// test — the round trip this pins is only "did `bulkDiscountRoughly`'s
    /// own filtered run really execute", not "did it execute alone".
    ///
    /// (Line 26, `return 0.0` — the branch only `bulkDiscountRoughly` can
    /// reach — would be a cleaner, single-test-exclusive choice, but a
    /// separate, pre-existing quirk in `SourceCoverageReader.executedLines`
    /// drops a region's own closing line when it is not itself a region
    /// entry; confirmed by direct reproduction to be unrelated to this
    /// filter fix, and out of scope for P12-B.)
    @Test("The bulkDiscountRoughly() identifier's own filtered run is attributed to it")
    func bulkDiscountRoughlyRoundTrips() async throws {
        let staged = try await self.staged()
        let bulkDiscountRoughly = try identifier(suffix: "bulkDiscountRoughly()", in: staged.discovered)

        let map = try #require(staged.perTestCoverage, "measurePerTestCoverage produced no attribution at all")
        let coverers = map.testsCovering(file: "Sources/Pricing/Pricing.swift", line: 24)
        #expect(
            coverers?.contains(bulkDiscountRoughly) == true,
            "line 24 (bulkDiscountRate's itemCount>10 branch) was not attributed to bulkDiscountRoughly()'s own filtered run"
        )
    }

    // MARK: B1-2 — impossible filter must not be authoritative pass

    /// A selection naming a test `swift test list` never discovered can never
    /// be satisfied by any filter string, escaped correctly or not. Today,
    /// `SwiftPackageMacOSAdapter.runMutant(selectedTests:)` still reports
    /// `.passed` for this: `classify` decides purely from the process exit
    /// code, and `swift test --filter` exits 0 when it selects zero tests
    /// (confirmed live in B0 — SwiftPM emits `warning: No matching test
    /// cases were run` on stderr and still exits 0). A run that tested
    /// nothing must never be indistinguishable from one that passed.
    @Test("A selection that matches no test must not be reported as an authoritative pass")
    func impossibleSelectionIsNotAuthoritativePass() async throws {
        let staged = try await self.staged()
        let point = try makeAnchoredPoint()
        let impossible = TestIdentifier(target: "PricingTests", qualifiedName: "PricingTests/thisTestDoesNotExist()")

        let result = try await staged.adapter.runMutant(
            point, artifact: staged.artifact, in: staged.workspace, timeoutSeconds: 30, selectedTests: [impossible]
        )

        #expect(
            result.status != .passed,
            "an unsatisfiable selection was reported as passed: \(result.diagnosis)"
        )
    }

    // MARK: B1-3 — per-test coverage attribution must not cross-contaminate

    /// `qualifiesForSeniorRate(age:)`'s line (16) and `bulkDiscountRate`'s
    /// `itemCount > 10` branch (line 24) are reached by disjoint pairs of
    /// tests: `seniorRateBoundary()` never calls `bulkDiscountRate`, and
    /// `bulkDiscountRoughly()` never calls `qualifiesForSeniorRate`. A
    /// filter that ran the wrong test, or ran both when only one was
    /// requested, would show up here as one test's identifier leaking into
    /// the other's line.
    @Test("Two tests covering disjoint lines are attributed disjointly, not merged or swapped")
    func attributionDoesNotCrossContaminate() async throws {
        let staged = try await self.staged()
        let seniorRateBoundary = try identifier(suffix: "seniorRateBoundary()", in: staged.discovered)
        let bulkDiscountRoughly = try identifier(suffix: "bulkDiscountRoughly()", in: staged.discovered)

        let map = try #require(staged.perTestCoverage)

        let seniorRateLine = map.testsCovering(file: "Sources/Pricing/Pricing.swift", line: 16)
        let bulkDiscountLine = map.testsCovering(file: "Sources/Pricing/Pricing.swift", line: 24)

        #expect(seniorRateLine?.contains(seniorRateBoundary) == true)
        #expect(bulkDiscountLine?.contains(bulkDiscountRoughly) == true)
        // Neither test's own line may include the other's identifier.
        #expect(seniorRateLine?.contains(bulkDiscountRoughly) != true)
        #expect(bulkDiscountLine?.contains(seniorRateBoundary) != true)
    }

    /// Every discovered test's own `runTests` call inside
    /// `measurePerTestCoverage`'s loop now gets a unique xunit report path
    /// (an independent audit's finding: the earlier fixed-path-plus-cleanup
    /// design could leave a stale report behind on a failed delete). Left
    /// entirely uncleaned, a real project with many discovered tests would
    /// accumulate one report pair per test in this one sandbox for as long
    /// as it lives — this pins that the loop cleans up after itself once
    /// each report has been read, not just that classification itself still
    /// works.
    ///
    /// Deliberately its own, freshly-staged workspace rather than the
    /// shared `staged` fixture every other test in this suite uses: those
    /// other tests call `runMutant`/`runSchemataToken` against that same
    /// shared workspace, which legitimately (and correctly) leave *their*
    /// own xunit reports uncleaned — cleanup here is scoped to
    /// `measurePerTestCoverage`'s own loop only, never a real mutant run's
    /// result, which downstream evidence-preservation still needs intact.
    /// Sharing that workspace would make this assertion racy against
    /// whichever sibling test happens to run concurrently.
    @Test("measurePerTestCoverage does not leave per-test xunit reports behind in the workspace")
    func perTestCoverageDoesNotAccumulateXUnitReports() async throws {
        let workspace = try Acceptance.stageFixture("SwiftPackageMacOS")
        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)
        let perTestCoverage = await adapter.measurePerTestCoverage(
            artifact: artifact, in: workspace, timeoutSeconds: 60
        )
        _ = try #require(perTestCoverage, "measurePerTestCoverage produced no attribution at all")

        let leftoverReports = try FileManager.default
            .contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("mutantkit-xunit") }
        #expect(
            leftoverReports.isEmpty,
            "measurePerTestCoverage left \(leftoverReports.count) xunit report(s) behind: \(leftoverReports.map(\.lastPathComponent))"
        )
    }

    // MARK: B5 — the schemata selected-test path shares the same fix

    /// `SchemataTestable.runSchemataToken(selectedTests:)` is the third
    /// shared user of `swiftTestFilterArgument`/`reliableExpectedCount`
    /// (alongside `measurePerTestCoverage` above and
    /// `TestSelecting.runMutant` in `impossibleSelectionIsNotAuthoritativePass`).
    /// It is exercised here against a plain (non-schemata-linked) build: the
    /// schemata runtime library's linkage only affects which mutation a
    /// token activates, never how `--filter` is built or how a zero-executed
    /// run is classified, so this proves the filter/shortfall fix reaches
    /// this call site too without needing `buildSchemataChunk` or
    /// `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE`.
    @Test("The schemata token path selects exactly the requested Swift Testing test")
    func schemataTokenPathRoundTrips() async throws {
        let staged = try await self.staged()
        let seniorRateBoundary = try identifier(suffix: "seniorRateBoundary()", in: staged.discovered)

        let result = try await staged.adapter.runSchemataToken(
            staged.artifact, in: staged.workspace, timeoutSeconds: 30,
            environment: [:], selectedTests: [seniorRateBoundary]
        )

        #expect(result.status == .passed, "\(result.diagnosis)")
    }

    /// The same impossible-selection contract as
    /// `impossibleSelectionIsNotAuthoritativePass`, through the schemata
    /// token call site instead of `runMutant`.
    @Test("The schemata token path also refuses to call an impossible selection a pass")
    func schemataTokenPathRejectsImpossibleSelection() async throws {
        let staged = try await self.staged()
        let impossible = TestIdentifier(target: "PricingTests", qualifiedName: "PricingTests/thisTestDoesNotExist()")

        let result = try await staged.adapter.runSchemataToken(
            staged.artifact, in: staged.workspace, timeoutSeconds: 30,
            environment: [:], selectedTests: [impossible]
        )

        #expect(
            result.status != .passed,
            "an unsatisfiable selection was reported as passed via the schemata token path: \(result.diagnosis)"
        )
    }
}
