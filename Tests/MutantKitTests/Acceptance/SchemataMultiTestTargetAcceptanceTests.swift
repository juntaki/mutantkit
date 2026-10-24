import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// With Xcode 27 each SwiftPM test target links into its own `.xctest` bundle, so a library only one
/// target tests sits in exactly one bundle and a unit with two dependent test targets sits in two. The
/// build receipt names every image holding a unit's code (receipt v3), so a package with several test
/// targets must still run on the shared schemata build instead of forfeiting every chunk.
///
/// Requires `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE`, like every schemata acceptance suite.
@Suite("Schemata: SwiftPM package with several test targets", .enabled(if: Acceptance.isEnabled))
struct SchemataMultiTestTargetAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: schemata
    reports: [console, json]
    """

    @Test("Candidates in libraries tested by different test targets all run on the schemata build")
    func disjointTestTargetsActivateSchemata() throws {
        let run = try Acceptance.planAndRun(fixture: "DisjointTestTargets", configuration: Self.configuration)

        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "\(run.baselineEvidence)")
        #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.degradationReason == nil, "\(run.baselineEvidence)")
        #expect(strategy.effectiveCount > 0, "no mutation ran on the shared build\n\(run.schemataFallbackEvidence)")
        let kinds = Set(run.report.operationalIssues.map(\.kind))
        #expect(!kinds.contains(.schemataChunkReceiptUnavailable), "\(run.schemataFallbackEvidence)")
        #expect(!kinds.contains(.schemataChunkBuildFailed), "\(run.schemataFallbackEvidence)")
        #expect((strategy.fallbackReasonCounts ?? [:])["buildReceiptUnavailable"] == nil, "\(run.schemataFallbackEvidence)")
    }
}
