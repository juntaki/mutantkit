import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Parity with `PerTestProfilingFailClosedAcceptanceTests` for `XcodeBuildAdapter`.
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
    .enabled(if: Acceptance.simulatorEnabled),
    // Both tests lease simulators for the same device. Run side by side, the
    // failing-test baseline reliably came back as a killed test runner
    // ("Test crashed with signal kill") instead of an ordinary test failure.
    .serialized
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

    @Test("An unmeasurable test stays in every selection instead of becoming \"covers nothing\"")
    func unmeasurableTestIsCarriedAsUnattributed() async throws {
        let workspace = try Acceptance.stageFixture("XcodeProject")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let destination = try Acceptance.iPhoneDestination()
        let configuration = Configuration(
            project: ProjectSettings(kind: .xcodeProject, scheme: "PerTestProfilingPartialFailureDemo", destination: destination)
        )
        let adapter = XcodeBuildAdapter(configuration: configuration, kind: .xcodeProject, projectFile: nil, projectRoot: workspace)

        let artifact = try await adapter.buildBaseline(in: workspace)
        let baseline = try await adapter.runBaseline(artifact, in: workspace, timeoutSeconds: 120)
        #expect(baseline.status == .failed, "testWidgetBNeverProfiles must fail the baseline run unconditionally; got \(baseline)")

        let map = try #require(
            await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120),
            "the per-test pass should keep the measurable test's attribution and carry the unmeasurable one explicitly"
        )

        // testWidgetBNeverProfiles() fails unconditionally, so its coverage can never be proven. It must be
        // carried as unattributed -- never silently dropped, which would read as "this test covers nothing".
        let unmeasurable = map.unattributedTests.filter { $0.qualifiedName.hasSuffix("testWidgetBNeverProfiles") }
        #expect(unmeasurable.count == 1, "unattributed: \(map.unattributedTests)")
        #expect(!map.isComplete)

        // The measurable test stays attributed, so the map still narrows.
        let attributed = Set(map.coveringTests.values.flatMap(\.values).flatMap { $0 })
        #expect(attributed.contains { $0.qualifiedName.hasSuffix("testWidgetANeverFails") })
        #expect(attributed.isDisjoint(with: map.unattributedTests))

        // Fail-closed: every selection includes the unattributed test, for covered and uncovered lines alike.
        for (file, lines) in map.coveringTests {
            for line in lines.keys {
                let selection = try #require(map.testsCovering(file: file, line: line))
                #expect(selection.isSuperset(of: unmeasurable), "\(file):\(line) selection omits the unmeasurable test")
            }
        }
        let unseen = try #require(map.testsCovering(file: "PerTestWidgets/NoSuchFile.swift", line: 1))
        #expect(unseen.isSuperset(of: unmeasurable), "a line no test was attributed must still select the unmeasurable test")
    }
}
