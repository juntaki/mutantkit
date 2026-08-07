import Foundation
import MutationModel
import Testing

@Suite("Quality gate")
struct QualityGateTests {
    @Test("empty trusted report passes when no thresholds are configured")
    func noThresholdsPass() {
        let result = QualityGate.evaluate(
            report: emptyReport(integrityPassed: true),
            thresholds: QualityGateThresholds()
        )
        #expect(result.passed)
        #expect(result.violations.isEmpty)
    }

    @Test("threshold fails closed when score denominator is unavailable")
    func unavailableScoreFailsThreshold() {
        let result = QualityGate.evaluate(
            report: emptyReport(integrityPassed: true),
            thresholds: QualityGateThresholds(minimumTested: 0.8)
        )
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .scoreUnavailable })
    }

    @Test("integrity failure always fails the gate")
    func integrityFailureFailsGate() {
        let result = QualityGate.evaluate(
            report: emptyReport(integrityPassed: false),
            thresholds: QualityGateThresholds()
        )
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .scoreUnavailable })
    }

    private func emptyReport(integrityPassed: Bool) -> RunReport {
        let violations = integrityPassed
            ? []
            : [IntegrityViolation(kind: .countMismatch, detail: "fixture")]
        return RunReport(
            planID: "plan_gate_fixture",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            projectRoot: "/tmp/fixture",
            toolchain: ToolchainFingerprint(
                toolVersion: "test",
                toolCommitSHA: nil,
                swiftVersion: "test",
                swiftSyntaxVersion: "test",
                xcodeVersion: nil
            ),
            baseline: BaselineRecord(
                passed: true,
                testSummary: nil,
                durationSeconds: 1,
                buildProductHash: nil,
                buildCommand: nil,
                testCommand: nil
            ),
            ledger: ResultLedger<MutationResult>(),
            integrity: IntegrityReport(
                discovered: 0,
                planned: 0,
                sourceApplied: 0,
                buildObserved: 0,
                buildFailures: 0,
                executed: 0,
                classified: 0,
                reported: 0,
                explicitlySkipped: 0,
                violations: violations
            )
        )
    }
}
