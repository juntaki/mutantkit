import Foundation
import MutationModel
import Testing

/// `.xcodeWorkspace` is SUPPORTED for schemata mode (the multi-image build receipt): target resolution reads the
/// workspace's member `.xcodeproj` files from `contents.xcworkspacedata`, resolves each like a lone
/// project, and re-roots source paths at the workspace directory. Before that, the target-resolution
/// switch had no `.xcodeWorkspace` case and every run degraded to isolated; this suite used to pin
/// that. It now pins the opposite, on the same `Fixtures/XcodeWorkspace` run: schemata really executes
/// (schemata-verified results exist, nothing degrades the whole run) and the only fallbacks are
/// mutations this fixture's tests never reach.
@Suite("Schemata supported matrix: Xcode workspace", .enabled(if: Acceptance.simulatorEnabled))
struct SchemataSupportedMatrixXcodeWorkspaceAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeWorkspace
          scheme: Billing
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [BillingTests]
        operators:
          profile: default
        execution:
          strategy: schemata
          workers: 2
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeWorkspace", configuration: try configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Xcode workspace: schemata really executes; the only fallbacks are mutations the fixture's tests never reach")
    func requestingSchemataExecutesAndOnlyUncoveredMutationsFallBack() throws {
        let run = try self.run()
        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "the baseline must still reflect a genuinely passing suite")

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.degradationReason == nil, "\(String(describing: strategy.degradationReason))")
        #expect(strategy.effectiveCount > 0, "no mutation went through the schemata backend")
        #expect(strategy.effectiveCount + strategy.fallbackCount == integrity.planned)
        #expect((strategy.plannerFallbackReasonCounts ?? [:]).isEmpty)

        // Unlike the xcodeProject fixture, this one is not fully covered by its tests, so some mutations legitimately
        // never start up or hit (`activation.noStartup` / `.noHit`) and run isolated. Receipt or chunk-build failures
        // never are legitimate.
        let reasons = Set((strategy.fallbackReasonCounts ?? [:]).keys)
        #expect(reasons.isSubset(of: ["activation.noHit", "activation.noStartup"]), "\(reasons)")

        // The check that would have caught the earlier silent version of this run: an effective count alone passed while
        // every result was an infrastructure failure. Schemata-verified evidence has to exist.
        let qualification = SchemataQualification(maximumUnexpectedFallbacks: strategy.fallbackCount)
        #expect(qualification.violations(in: run.report).isEmpty, "\(qualification.violations(in: run.report))")
    }
}
