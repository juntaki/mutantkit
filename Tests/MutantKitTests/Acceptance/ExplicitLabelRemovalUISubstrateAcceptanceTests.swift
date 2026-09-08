import Foundation
import MutationModel
import Testing

/// Task requirement (point 9 of the `apple.accessibility.explicit-label-removal`
/// task briefing): prove the fault contract flows end to end through a real
/// *operator-generated* mutant against `Fixtures/AccessibilityUISubstrate` —
/// not a hand-applied edit, which Phase 5A itself already validated
/// manually (`Research/phase5a-ui-test-substrate-2026-09/README.md`, "2 —
/// RED: `.accessibilityLabel("Close")` removed").
///
/// `apple.accessibility.explicit-label-removal` is `defaultEnabled: false`,
/// `confidence: .experimental`, so it is explicitly enabled here;
/// `swift.core.relational-operator-replacement` (the fixture's other real
/// mutant source, on `isRowTapRegistered`) is disabled so this suite's own
/// campaign produces exactly the one candidate this task is about, with no
/// need to also assert on the already-covered relational mutants (see
/// `AccessibilityUISubstrateAcceptanceTests` for those).
@Suite(
    "Acceptance: explicit-label-removal on Phase 5A UI-test substrate",
    .enabled(if: Acceptance.simulatorEnabled)
)
struct ExplicitLabelRemovalUISubstrateAcceptanceTests {
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
          enable: [apple.accessibility.explicit-label-removal]
          disable: [swift.core.relational-operator-replacement]
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

    @Test("Discovery finds exactly the one .accessibilityLabel(\"Close\") candidate, on the real fixture source")
    func discoversExactlyTheOneCandidate() throws {
        let run = try self.run()
        let candidates = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last?.contains("body") == true
                || $0.point.originalText.contains("accessibilityLabel")
        }
        #expect(candidates.count == 1, "\(run.report.results.map { ($0.point.originalText, $0.point.replacementText) })")
        let candidate = try #require(candidates.first)
        #expect(candidate.point.originalText.contains(".accessibilityLabel(\"Close\")"))
        #expect(!candidate.point.replacementText.contains("accessibilityLabel"))
    }

    /// The required result path from the task briefing: candidate discovered
    /// -> mutant applied -> app compiles -> UI test runs (non-zero count) ->
    /// AX-tree assertion fails -> `killedByAssertion`. This is the operator-
    /// generated analogue of Phase 5A's own hand-applied RED reproduction —
    /// same fixture, same fault, same real XCUITest/AX-tree mechanism, now
    /// driven entirely by `apple.accessibility.explicit-label-removal`'s
    /// own discovery and replacement text, through a real `mutantkit plan` +
    /// `mutantkit run` campaign.
    @Test("The operator-generated mutant is killed by the real XCUITest AX-tree assertion")
    func operatorGeneratedMutantIsKilledByRealXCUITest() throws {
        let run = try self.run()

        #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")

        let baseline = run.report.baseline
        #expect(baseline.passed)
        let baselineSummary = try #require(baseline.testSummary)
        #expect(baselineSummary.total == 3, "a real, non-zero baseline test count")
        #expect(baselineSummary.failed == 0)

        let result = try #require(
            run.report.results.first { $0.point.originalText.contains("accessibilityLabel(\"Close\")") }
        )
        #expect(result.outcome == .killedByAssertion)
        let summary = try #require(result.testSummary)
        #expect(summary.total == 3, "the mutant's own run uses the real, full UI-test suite")
        #expect(summary.failed >= 1)
        // Both AX-observing tests are expected to fail once the explicit
        // label is gone: the exact-label lookup (`app.buttons["Close"]`)
        // and, independently, `performAccessibilityAudit()` (an unnamed
        // interactive control is a real audit issue). See the task
        // briefing's point 11: recording *which* mechanism kills the
        // mutant is mandatory, not merely that something did.
        #expect(summary.failingTests.contains(
            "AccessibilityUITests/AccessibilityUITests/testCloseButtonHasAccessibilityLabel()"
        ))
    }
}
