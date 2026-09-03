import Foundation
import MutationModel
import Testing

/// `.xcodeWorkspace` is UNSUPPORTED for schemata mode today — not a
/// coverage gap in this suite, but a real, deliberate gap in
/// `SchemataRunOrchestration.swift`'s own target-resolution switch, which
/// has no case for `.xcodeWorkspace` at all: it prints "Schemata target
/// resolution is not yet implemented for xcodeWorkspace; every mutation
/// will run in isolated mode this run" and returns an empty target map,
/// before a single chunk is ever planned. This is intentional, existing,
/// fail-safe (never fail-open) behavior — this suite's job is to pin it
/// down with a real E2E run, not to implement the missing resolver (out of
/// scope; a new target-resolution mechanism is new capability, not
/// verification).
///
/// A request for `strategy: schemata` against a real `Fixtures/XcodeWorkspace`
/// run must still produce a fully correct, 100%-isolated report — silent
/// fallback is allowed to be the *whole* story here (this is the one
/// matrix row where 100% fallback is the expected, correct, pinned
/// outcome, not a defect), but the run itself must still succeed and
/// score correctly.
@Suite("Schemata supported matrix: Xcode workspace (pinned unsupported)", .enabled(if: Acceptance.simulatorEnabled))
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

    @Test("Xcode workspace: a schemata request falls back to isolated for every mutation, correctly, as a whole-run degradation")
    func requestingSchemataFallsBackEntirelyButCorrectly() throws {
        let run = try self.run()
        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "the baseline must still reflect a genuinely passing suite")

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.effectiveCount == 0, "xcodeWorkspace has no schemata target resolution today")
        #expect(strategy.fallbackCount == integrity.planned, "every planned mutation must fall back, none silently dropped")
        #expect(
            strategy.degradationReason != nil,
            "this must be reported as a whole-run degradation (target resolution never ran), not per-mutation SchemataChunkPlanner routing"
        )
        #expect(
            run.runOutput.contains("Schemata target resolution is not yet implemented for xcodeWorkspace"),
            "the operator must see an explicit, honest reason, never a silent no-op"
        )
    }
}
