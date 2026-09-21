@testable import CLI
import Foundation
@testable import MutationExecution
import MutationModel
import Testing

/// What the merged report says about the baseline when the schemata portion
/// could not run against one.
///
/// A wrong answer here is invisible rather than loud: the run still produces
/// a report, and the only sign that a baseline was never green is the record
/// attached to it. That record used to be synthesized — `passed: false` and
/// every other field `nil`, `durationSeconds: 0` — discarding the one the
/// runner had actually observed, so a reader could not tell a project that
/// failed to build from a suite that ran and was red.
@Suite("SchemataRunOrchestration: the degraded report carries the baseline that was observed")
struct SchemataDegradedBaselineTests {
    private static func record(passed: Bool, hash: String?) -> BaselineRecord {
        BaselineRecord(
            passed: passed,
            testSummary: TestOutcomeSummary(total: 4, passed: passed ? 4 : 3, failed: passed ? 0 : 1, failingTests: [], durationSeconds: 2),
            durationSeconds: 9, buildProductHash: hash,
            buildCommand: CommandRecord(executable: "xcodebuild", arguments: ["build-for-testing"], workingDirectory: "."),
            testCommand: nil
        )
    }

    @Test("A failed schemata baseline attaches the observed record, not a synthesized one")
    func baselineFailedKeepsTheObservedRecord() {
        let observed = Self.record(passed: false, hash: "product-hash")

        let resolved = SchemataRunOrchestration.resolveBaseline(
            .baselineFailed(record: observed, diagnosis: "the suite did not pass (crashed)"),
            schemataBaseline: nil, fallbackBaseline: nil, embeddedCount: 0, fallbackCount: 0
        )

        #expect(resolved.passed == false)
        #expect(resolved.record.buildProductHash == "product-hash", "an all-nil stand-in cannot say whether the project built")
        #expect(resolved.record.buildCommand?.executable == "xcodebuild")
        #expect(resolved.record.durationSeconds == 9)
        #expect(resolved.degradationReason == "the schemata baseline did not pass: the suite did not pass (crashed)")
    }

    /// Nothing was embeddable, so the schemata portion never ran a baseline
    /// at all — the isolated fallback pass's own is the only one that exists.
    @Test("Nothing embeddable: the fallback pass's baseline is the report's, and only an all-fallback run is degraded")
    func notApplicableUsesTheFallbackBaseline() {
        let fallback = Self.record(passed: true, hash: "fallback-hash")

        let resolved = SchemataRunOrchestration.resolveBaseline(
            .notApplicable, schemataBaseline: nil, fallbackBaseline: fallback, embeddedCount: 0, fallbackCount: 3
        )
        #expect(resolved.passed)
        #expect(resolved.record.buildProductHash == "fallback-hash")
        #expect(resolved.degradationReason?.contains("no mutation in this plan was embeddable") == true)

        let partly = SchemataRunOrchestration.resolveBaseline(
            .notApplicable, schemataBaseline: nil, fallbackBaseline: fallback, embeddedCount: 2, fallbackCount: 3
        )
        #expect(partly.degradationReason == nil, "a run with real embedded mutants is not degraded by having fallbacks too")
    }

    /// Both portions ran. A failed baseline on either side must make the
    /// whole run fail closed, so `IntegrityChecker` raises its
    /// `baselineMismatch` rather than the report looking merely incomplete.
    @Test("Succeeded: either portion's failed baseline fails the run closed")
    func succeededRequiresBothBaselines() {
        let green = Self.record(passed: true, hash: "green")
        let red = Self.record(passed: false, hash: "red")
        // The payload is not what this decision reads — the two records
        // passed alongside it are — so any outcome value does here.
        let succeeded = SchemataRunOrchestration.SchemataPortionResult.succeeded(
            SchemataMutationRunner.Outcome(
                baseline: green, results: [], multiTargetVerdicts: [], isolatedFallbacks: [],
                sharedChunkBuildFailureEvents: [], infrastructureFallbackEvents: []
            )
        )

        #expect(SchemataRunOrchestration.resolveBaseline(
            succeeded, schemataBaseline: green, fallbackBaseline: green, embeddedCount: 5, fallbackCount: 0
        ).passed)
        #expect(!SchemataRunOrchestration.resolveBaseline(
            succeeded, schemataBaseline: red, fallbackBaseline: green, embeddedCount: 5, fallbackCount: 1
        ).passed)
        #expect(!SchemataRunOrchestration.resolveBaseline(
            succeeded, schemataBaseline: green, fallbackBaseline: red, embeddedCount: 5, fallbackCount: 1
        ).passed)
    }

    /// The guard that makes a failed baseline reach `IntegrityChecker` as a
    /// `baselineMismatch`: with no report to read a baseline from at all,
    /// "not applicable" means the schemata portion asserts nothing, so the
    /// run is not declared failed on its behalf — but nothing may be
    /// reported as a passing baseline either.
    @Test("With no fallback report, the unknown baseline is never presented as a real one")
    func notApplicableWithoutFallbackReportsNothingKnown() {
        let resolved = SchemataRunOrchestration.resolveBaseline(
            .notApplicable, schemataBaseline: nil, fallbackBaseline: nil, embeddedCount: 0, fallbackCount: 0
        )
        #expect(resolved.record.passed == false)
        #expect(resolved.record.testSummary == nil)
        #expect(resolved.record.buildCommand == nil)
    }
}
