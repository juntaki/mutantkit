@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// P12-B (Phase B1), Finding D: `measurePerTestCoverage`'s per-test loop must
/// never let one test's unprovable run quietly become "this test covers
/// nothing" instead of "this test's coverage is unknown". Today it does
/// exactly that — `continue`-ing past any test whose isolated run does not
/// return `.passed`, then still returning whatever partial map the
/// *successful* tests built.
///
/// Uses a dedicated XCTest fixture (`Fixtures/PerTestProfilingPartialFailure`)
/// rather than the Swift Testing filter bug this phase is also fixing:
/// SwiftPM filters XCTest itself, so `widgetBNeverProfiles` reliably fails
/// its own isolated run today, independent of Phase B2 — this contract
/// stays meaningful, and this test keeps exercising it, before, during and
/// after that filter bug is fixed.
///
/// Expected to fail against current `main`: `measurePerTestCoverage`
/// currently returns a non-`nil` map missing `widgetB()`'s attribution
/// entirely, rather than `nil`.
@Suite(
    "Acceptance: per-test coverage fails closed when one test cannot be measured",
    .enabled(if: Acceptance.isEnabled)
)
struct PerTestProfilingFailClosedAcceptanceTests {
    @Test("An unmeasurable test invalidates the whole per-test coverage map, not just its own entry")
    func unmeasurableTestProducesNoUsableMap() async throws {
        let workspace = try Acceptance.stageFixture("PerTestProfilingPartialFailure")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)

        // Sanity check on the fixture itself: two tests really were
        // discovered, so a `nil` result below is fail-closed on a genuine
        // partial failure, not on a fixture that produced no tests at all.
        let discovered = await SwiftPackageMacOSAdapter.enumerateTestIdentifiers(
            in: workspace, timeoutSeconds: 60, terminationGracePeriodSeconds: 5
        )
        #expect(discovered.count == 2, "fixture drifted: expected exactly widgetANeverFails + widgetBNeverProfiles")

        let map = await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 60)

        #expect(
            map == nil,
            """
            widgetBNeverProfiles() can never be proven measured (it fails unconditionally), so the map must be nil \
            -- an unrestricted full-suite fallback -- rather than a map that silently omits widgetB()'s real \
            coverage while still looking complete. Got: \(String(describing: map))
            """
        )
    }
}
