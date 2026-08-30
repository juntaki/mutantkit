import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// F1-P0: parity with `PerTestProfilingFailClosedAcceptanceTests` (the
/// SwiftPM/P12-B Finding D fix) for `XcodeBuildAdapter`.
/// `measurePerTestCoverage`'s per-test loop must never let one test's
/// unprovable isolated run quietly become "this test covers nothing"
/// instead of "this test's coverage is unknown" -- a version of this
/// method that `continue`d past such a test, returning whatever the
/// *successful* tests alone had built, produces a map that still looks
/// complete and usable while silently missing the unprovable test's real
/// coverage, which can turn a mutant that test alone would have killed
/// into a false survivor.
///
/// Uses `Fixtures/XcodeProject`'s own isolated
/// `PerTestProfilingPartialFailureDemo` scheme (mirrors
/// `Fixtures/PerTestProfilingPartialFailure`, the SwiftPM fixture this test
/// suite's own name echoes) -- never the `Checkout` scheme every other
/// acceptance suite sharing this fixture uses.
@Suite(
    "Acceptance: Xcode per-test coverage fails closed when one test cannot be measured",
    .enabled(if: Acceptance.simulatorEnabled)
)
struct XcodePerTestProfilingFailClosedAcceptanceTests {
    @Test("The unavailable fast profiler falls back to the serial reference profiler")
    func unavailableFastProfilerFallsBackToSerialReferenceProfiler() async throws {
        let workspace = try Acceptance.stageFixture("XcodeProject")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let destination = try Acceptance.iPhoneDestination()
        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "Checkout", destination: destination)
        )
        let adapter = XcodeBuildAdapter(
            configuration: configuration,
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: workspace
        )

        let artifact = try await adapter.buildBaseline(in: workspace)
        let baseline = try await adapter.runBaseline(artifact, in: workspace, timeoutSeconds: 120)
        #expect(baseline.status == .passed, "the Checkout baseline must produce the serial profiler's test bundle")
        let profile = try #require(
            await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120),
            "the serial reference profiler produced no attribution"
        )
        #expect(
            profile.source == "xcodebuild-xccov-per-test",
            "the public profiler did not return the serial reference profiler's result"
        )
    }

    @Test("An unmeasurable test invalidates the whole per-test coverage map, not just its own entry")
    func unmeasurableTestProducesNoUsableMap() async throws {
        let workspace = try Acceptance.stageFixture("XcodeProject")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let destination = try Acceptance.iPhoneDestination()
        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "PerTestProfilingPartialFailureDemo", destination: destination)
        )
        let adapter = XcodeBuildAdapter(configuration: configuration, kind: .xcodeProject, projectFile: nil, projectRoot: workspace)

        let artifact = try await adapter.buildBaseline(in: workspace)
        let baseline = try await adapter.runBaseline(artifact, in: workspace, timeoutSeconds: 120)
        #expect(baseline.status == .failed, "the fixture's own testWidgetBNeverProfiles must fail the baseline run unconditionally")

        let map = await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120)

        #expect(
            map == nil,
            """
            testWidgetBNeverProfiles() can never be proven measured (it fails unconditionally), so the map must be nil \
            -- an unrestricted full-suite fallback -- rather than a map that silently omits widgetB()'s real \
            coverage while still looking complete. Got: \(String(describing: map))
            """
        )
    }
}
