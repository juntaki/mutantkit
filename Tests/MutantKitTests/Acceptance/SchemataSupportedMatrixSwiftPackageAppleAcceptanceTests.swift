import Foundation
import MutationModel
import Testing

/// `.swiftPackageApple` (a SwiftPM package for a non-host Apple
/// platform, built via `xcodebuild`) + iOS Simulator is UNSUPPORTED for
/// schemata mode today — a real, measured finding, not an assumption.
///
/// `SchemataRunOrchestration.swift` resolves this project kind's schemata
/// targets via `SwiftPMTargetResolver` (the same resolver `.swiftPackageMacOS`
/// uses) while the actual build still runs through `XcodeBuildAdapter`
/// (`xcodebuild`, since `swift build` cannot build a package with no macOS
/// slice at all). That hybrid pairing's own `resolveSchemataBuildReceipt`
/// fails for every chunk: `could not parse build settings for target
/// <name>: expected exactly one buildSettings entry named <name>, found 0`
/// — `xcodebuild -showBuildSettings`'s own output shape does not match what
/// the SwiftPM-resolved receipt path expects. Every mutation forfeits
/// schemata and re-runs through isolated mode instead
/// (`.buildReceiptUnavailable`, P2's own fail-closed fallback), so the
/// final report is still fully correct — just never actually schemata.
///
/// This is a real infrastructure gap, not a coverage gap: fixing the
/// receipt resolver for this specific hybrid pairing is new production
/// work, out of scope for this verification/documentation pass (not a
/// new-capability PR). This test pins the current, honest behavior down
/// with root-cause evidence so a future change has a real regression test
/// to work against, rather than silently drifting further.
@Suite("Schemata supported matrix: Swift package Apple (pinned unsupported)", .enabled(if: Acceptance.simulatorEnabled))
struct SchemataSupportedMatrixSwiftPackageAppleAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: swiftPackageApple
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        operators:
          profile: default
        execution:
          strategy: schemata
          workers: 1
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SwiftPackageIOS", configuration: try configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("swiftPackageApple + iOS Simulator: falls back via buildReceiptUnavailable for every candidate, correctly, never silently")
    func requestingSchemataFallsBackViaReceiptUnavailableButCorrectly() throws {
        let run = try self.run()
        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "the baseline must still reflect a genuinely passing suite")

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.effectiveCount == 0, "the build-receipt resolver never succeeds for this hybrid pairing today")

        let reasons = try #require(strategy.fallbackReasonCounts)
        #expect(reasons["buildReceiptUnavailable"] != nil && reasons["buildReceiptUnavailable"]! > 0, "\(reasons)")

        let operationalIssueKinds = Set(run.report.operationalIssues.map(\.kind))
        #expect(
            operationalIssueKinds.contains(.schemataChunkReceiptUnavailable),
            "the operator must see a real diagnosis, never a silent degradation"
        )

        // The report's own final answer is still fully correct — only the
        // execution *path* changed, never the score.
        #expect(run.report.score != nil)
    }
}
