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

    @Test("regression/newSurvivors thresholds fail closed when no baseline is given")
    func regressionThresholdsRequireBaseline() {
        let result = QualityGate.evaluate(
            report: report(outcomes: [.killedByAssertion]),
            thresholds: QualityGateThresholds(regressionMaximumDrop: 0.02),
            baseline: nil
        )
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .baselineUnavailable })
    }

    @Test("a score drop within the configured tolerance passes")
    func regressionWithinToleranceIsFine() {
        let baseline = report(outcomes: [.killedByAssertion, .killedByAssertion, .killedByAssertion, .killedByAssertion])
        let current = report(outcomes: [.killedByAssertion, .killedByAssertion, .killedByAssertion, .survived])
        let result = QualityGate.evaluate(
            report: current,
            thresholds: QualityGateThresholds(regressionMaximumDrop: 0.30),
            baseline: baseline
        )
        #expect(result.passed)
    }

    @Test("a score drop past the configured tolerance fails with the actual numbers reported")
    func regressionPastToleranceFails() {
        let baseline = report(outcomes: [.killedByAssertion, .killedByAssertion, .killedByAssertion, .killedByAssertion])
        let current = report(outcomes: [.killedByAssertion, .killedByAssertion, .killedByAssertion, .survived])
        let result = QualityGate.evaluate(
            report: current,
            thresholds: QualityGateThresholds(regressionMaximumDrop: 0.10),
            baseline: baseline
        )
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .scoreRegression && $0.detail.contains("Tested") })
        #expect(result.violations.contains { $0.kind == .scoreRegression && $0.detail.contains("Effective") })
    }

    @Test("a stable backlog of pre-existing survivors does not fail newSurvivorsMaximum")
    func preExistingSurvivorsAreNotNew() {
        let survivorA = point("A.swift", 1)
        let baseline = reportFromPoints([(survivorA, .survived)])
        let current = reportFromPoints([(survivorA, .survived)])
        let result = QualityGate.evaluate(
            report: current,
            thresholds: QualityGateThresholds(newSurvivorsMaximum: 0),
            baseline: baseline
        )
        #expect(result.passed)
    }

    @Test("a genuinely new survivor fails newSurvivorsMaximum and names it")
    func newSurvivorFailsGate() {
        let survivorA = point("A.swift", 1)
        let survivorB = point("B.swift", 1)
        let baseline = reportFromPoints([(survivorA, .survived)])
        let current = reportFromPoints([(survivorA, .survived), (survivorB, .survived)])
        let result = QualityGate.evaluate(
            report: current,
            thresholds: QualityGateThresholds(newSurvivorsMaximum: 0),
            baseline: baseline
        )
        #expect(!result.passed)
        let violation = result.violations.first { $0.kind == .newSurvivors }
        #expect(violation != nil)
        #expect(violation?.detail.contains(survivorB.id.rawValue) == true)
        #expect(violation?.detail.contains(survivorA.id.rawValue) == false)
    }

    private func point(_ file: String, _ line: Int) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: "mut_\(file)_\(line)"),
            file: file,
            enclosingDeclaration: DeclarationIdentity(path: ["Test/test"]),
            operatorID: "op",
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(0 ..< 1),
            originalText: "x",
            replacementText: "y",
            prefixTokenFingerprint: "pre",
            suffixTokenFingerprint: "post",
            sourceFileHash: "hash",
            expectedSyntaxKind: "kind",
            confidence: .high,
            executionMode: .isolated,
            line: line,
            column: 1
        )
    }

    private func report(outcomes: [MutationOutcome]) -> RunReport {
        reportFromPoints(outcomes.enumerated().map { (point("F.swift", $0.offset), $0.element) })
    }

    private func reportFromPoints(_ pointsAndOutcomes: [(MutationPoint, MutationOutcome)]) -> RunReport {
        var ledger = ResultLedger<MutationResult>()
        for (index, entry) in pointsAndOutcomes.enumerated() {
            let result = makeResult(point: entry.0, outcome: entry.1, planID: "plan_gate_fixture\(index)")
            try! ledger.insert(result) // swiftlint:disable:this force_try
        }
        let violations: [IntegrityViolation] = []
        return RunReport(
            planID: "plan_gate_fixture",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            projectRoot: "/tmp/fixture",
            toolchain: makeToolchain(),
            baseline: makeBaseline(),
            ledger: ledger,
            integrity: IntegrityReport(
                discovered: pointsAndOutcomes.count,
                planned: pointsAndOutcomes.count,
                sourceApplied: pointsAndOutcomes.count,
                buildObserved: pointsAndOutcomes.count,
                buildFailures: 0,
                executed: pointsAndOutcomes.count,
                classified: pointsAndOutcomes.count,
                reported: pointsAndOutcomes.count,
                explicitlySkipped: 0,
                violations: violations
            )
        )
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
