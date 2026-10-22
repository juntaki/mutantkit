@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// With more than one test target (each its own `.xctest` bundle on Xcode 27) SwiftPM's own
/// `codecov/<package>.json` is exported against a single bundle, so the coverage of the other
/// target's tests never reached the per-test map. Every target's tests must show up.
@Suite("Acceptance: per-test coverage sees every test target", .enabled(if: Acceptance.isEnabled))
struct MultiTestTargetCoverageAcceptanceTests {
    @Test("Each target's tests are attributed to the library only that target's bundle links")
    func eachTargetsLibraryIsAttributed() async throws {
        let workspace = try Acceptance.stageFixture("DisjointTestTargets")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let artifact = try await adapter.buildBaseline(in: workspace)
        let map = try #require(await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120))

        func targets(covering file: String) -> Set<String> {
            Set((map.coveringTests[file] ?? [:]).values.flatMap { $0 }.map(\.target))
        }
        #expect(map.unattributedTests.isEmpty, "a skipped test must be attributed as covering nothing: \(map.unattributedTests)")
        let alphaTests = Set((map.coveringTests["Sources/Alpha/Alpha.swift"] ?? [:]).values.flatMap { $0 }.map(\.qualifiedName))
        #expect(!alphaTests.contains { $0.contains("DisabledAlphaTests") }, "the skipped test covers nothing")
        #expect(targets(covering: "Sources/Alpha/Alpha.swift") == ["AlphaTests"])
        #expect(targets(covering: "Sources/Beta/Beta.swift") == ["BetaTests"], "the other target's coverage was lost")
    }
}
