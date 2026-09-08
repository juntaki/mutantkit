import Foundation
import MutationModel
import Testing

/// Task requirement (point 9 of the `apple.swiftui.hit-area-shape-removal`
/// task briefing): prove the fault contract flows end to end through a real
/// *operator-generated* mutant against `Fixtures/AccessibilityUISubstrate` —
/// not a hand-applied edit, which Phase 5A itself already validated manually
/// (`Research/phase5a-ui-test-substrate-2026-09/README.md`).
///
/// `apple.swiftui.hit-area-shape-removal` is `defaultEnabled: false`,
/// `confidence: .experimental`, so it is explicitly enabled here;
/// `swift.core.relational-operator-replacement` (the fixture's other real
/// mutant source, on `isRowTapRegistered`) and
/// `apple.accessibility.explicit-label-removal` (the fixture's close-button
/// candidate) are disabled so this suite's own campaign produces exactly the
/// one candidate this task is about.
///
/// This proves pipeline correctness only, per the task briefing's own point
/// 9 — it is explicitly NOT counted as promotion evidence. See
/// `Research/corpus-validation/hit-area-shape-removal-2026-09/README.md` for
/// the real, external-project evidence that decides promotion.
@Suite(
    "Acceptance: hit-area-shape-removal on Phase 5A UI-test substrate",
    .enabled(if: Acceptance.simulatorEnabled)
)
struct HitAreaShapeRemovalUISubstrateAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: AccessibilityUISubstrate
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [AccessibilityUITests]
        operators:
          profile: default
          enable: [apple.swiftui.hit-area-shape-removal]
          disable: [swift.core.relational-operator-replacement, apple.accessibility.explicit-label-removal]
        execution:
          strategy: isolated
          workers: 1
        timeouts:
          baseline: 3m
          mutant:
            strategy: fixed
            maximum: 5m
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "AccessibilityUISubstrate", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Discovery finds exactly the one .contentShape(Rectangle()) candidate, on the real fixture source")
    func discoversExactlyTheOneCandidate() throws {
        let run = try self.run()
        let candidates = run.report.results.filter {
            $0.point.originalText.contains("contentShape")
        }
        #expect(candidates.count == 1, "\(run.report.results.map { ($0.point.originalText, $0.point.replacementText) })")
        let candidate = try #require(candidates.first)
        #expect(candidate.point.originalText.contains(".contentShape(Rectangle())"))
        #expect(!candidate.point.replacementText.contains("contentShape"))
    }

    /// The required result path from the task briefing: candidate discovered
    /// -> mutant applied -> app compiles -> UI test runs (non-zero count) ->
    /// coordinate tap in the transparent middle of `itemRow` -> the button's
    /// action does not fire -> `killedByAssertion`. This is the
    /// operator-generated analogue of Phase 5A's own hand-applied RED
    /// reproduction ("3 — RED: `.contentShape(Rectangle())` removed") — same
    /// fixture, same fault, same real XCUITest coordinate-tap mechanism, now
    /// driven entirely by `apple.swiftui.hit-area-shape-removal`'s own
    /// discovery and replacement text, through a real `mutantkit plan` +
    /// `mutantkit run` campaign.
    @Test("The operator-generated mutant is killed by the real XCUITest coordinate-tap assertion")
    func operatorGeneratedMutantIsKilledByRealXCUITest() throws {
        let run = try self.run()

        #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")

        let baseline = run.report.baseline
        #expect(baseline.passed)
        let baselineSummary = try #require(baseline.testSummary)
        #expect(baselineSummary.total == 3, "a real, non-zero baseline test count")
        #expect(baselineSummary.failed == 0)

        let result = try #require(
            run.report.results.first { $0.point.originalText.contains("contentShape(Rectangle())") }
        )
        #expect(result.outcome == .killedByAssertion)
        let summary = try #require(result.testSummary)
        #expect(summary.total == 3, "the mutant's own run uses the real, full UI-test suite")
        #expect(summary.failed >= 1)
        // Geometry evidence (task point 13): `testTappingFarFromTextStillTriggersAction`
        // taps `row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy:
        // 0.5))` -- the row's dead center, between the left-pinned "Item"
        // text and the right-pinned "$9.99" text (via the HStack's
        // `Spacer`), where no glyph is drawn. This is exactly the mechanism
        // this operator's mutation is meant to break, and no other test in
        // this fixture's 3-test suite observes it -- see
        // `Fixtures/AccessibilityUISubstrate/UITests/AccessibilityUITests.swift`.
        #expect(summary.failingTests.contains(
            "AccessibilityUITests/AccessibilityUITests/testTappingFarFromTextStillTriggersAction()"
        ))
    }
}
