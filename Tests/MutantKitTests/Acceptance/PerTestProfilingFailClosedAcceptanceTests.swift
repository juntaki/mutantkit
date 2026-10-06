@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `measurePerTestCoverage`'s per-test loop must never let one test's
/// unprovable run quietly become "this test covers nothing" instead of "this
/// test's coverage is unknown". A test whose isolated run does not return
/// `.passed` (or whose coverage cannot be read) is carried in the map's
/// `unattributedTests`, which every selection includes, rather than being
/// dropped from a map that still looks complete.
///
/// Uses a dedicated XCTest fixture (`Fixtures/PerTestProfilingPartialFailure`)
/// rather than a Swift Testing one: SwiftPM filters
/// XCTest itself, so `widgetBNeverProfiles` reliably fails its own isolated
/// run independent of that filter's own correctness — this contract stays
/// meaningful regardless of which framework's filter path is under test.
@Suite(
    "Acceptance: per-test coverage fails closed when one test cannot be measured",
    .enabled(if: Acceptance.isEnabled)
)
struct PerTestProfilingFailClosedAcceptanceTests {
    @Test("The unavailable fast profiler falls back to the serial reference profiler")
    func unavailableFastProfilerFallsBackToSerialReferenceProfiler() async throws {
        let workspace = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)

        let map = await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 60)

        let profile = try #require(map, "the serial reference profiler produced no attribution")
        #expect(
            profile.source == "swiftpm-codecov-per-test",
            "the public profiler did not return the serial reference profiler's result"
        )
    }

    @Test("An unmeasurable test stays in every selection instead of becoming \"covers nothing\"")
    func unmeasurableTestIsCarriedAsUnattributed() async throws {
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

        let map = try #require(
            await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 60),
            "the per-test pass should keep the measurable test's attribution and carry the unmeasurable one explicitly"
        )

        // widgetBNeverProfiles() fails unconditionally, so its coverage can never be proven. It must be carried as
        // unattributed -- never silently dropped, which would read as "this test covers nothing".
        let unmeasurable = map.unattributedTests.filter { $0.qualifiedName.contains("testWidgetBNeverProfiles") }
        #expect(unmeasurable.count == 1, "unattributed: \(map.unattributedTests)")
        #expect(!map.isComplete)

        // The measurable test stays attributed, so the map still narrows.
        let attributed = Set(map.coveringTests.values.flatMap(\.values).flatMap { $0 })
        #expect(attributed.contains { $0.qualifiedName.contains("testWidgetANeverFails") })
        #expect(attributed.isDisjoint(with: map.unattributedTests))

        // Fail-closed: every selection includes the unattributed test, for covered and uncovered lines alike.
        for (file, lines) in map.coveringTests {
            for line in lines.keys {
                let selection = try #require(map.testsCovering(file: file, line: line))
                #expect(selection.isSuperset(of: unmeasurable), "\(file):\(line) selection omits the unmeasurable test")
            }
        }
        let unseen = try #require(map.testsCovering(file: "Sources/NoSuchFile.swift", line: 1))
        #expect(unseen.isSuperset(of: unmeasurable), "a line no test was attributed must still select the unmeasurable test")
    }
}
