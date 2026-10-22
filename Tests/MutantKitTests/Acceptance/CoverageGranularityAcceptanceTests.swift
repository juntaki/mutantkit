@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Per-suite coverage attribution must be sound: for every line, the tests it
/// names are a superset of what per-test attribution names. Anything narrower
/// would let a mutant skip a test that could have killed it.
@Suite("Acceptance: per-suite coverage attribution is a superset of per-test", .enabled(if: Acceptance.isEnabled))
struct CoverageGranularityAcceptanceTests {
    @Test("Every line's covering tests under suite granularity include those under test granularity")
    func suiteMapIsASupersetOfTheTestMap() async throws {
        let workspace = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: workspace) }

        func measure(_ granularity: CoverageGranularity) async throws -> PerTestCoverageMap {
            var configuration = Configuration()
            configuration.execution.coverageGranularity = granularity
            let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
            let artifact = try await adapter.buildBaseline(in: workspace)
            return try #require(
                await adapter.measurePerTestCoverage(artifact: artifact, in: workspace, timeoutSeconds: 120),
                "no attribution under \(granularity)"
            )
        }

        let perTest = try await measure(.test)
        let perSuite = try await measure(.suite)

        #expect(perTest.unattributedTests.isEmpty)
        #expect(perSuite.unattributedTests.isEmpty)
        #expect(!perTest.coveringTests.isEmpty)

        for (file, lines) in perTest.coveringTests {
            for (line, tests) in lines {
                let suiteTests = try #require(perSuite.coveringTests[file]?[line], "\(file):\(line) lost under suite granularity")
                #expect(tests.isSubset(of: suiteTests), "\(file):\(line): \(tests) not within \(suiteTests)")
            }
        }
    }
}
