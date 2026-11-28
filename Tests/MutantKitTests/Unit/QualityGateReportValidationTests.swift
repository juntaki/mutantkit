import Foundation
import MutationModel
import Testing

/// The gate re-checks both reports against themselves before using them.
extension QualityGateTests {
    // MARK: Report-only validation of the gate's inputs

    /// Re-decodes `report` after `edit` rewrote its JSON, the only way to build a
    /// report whose stored fields disagree (the initializer derives them).
    func tampered(_ report: RunReport, _ edit: (inout [String: Any]) -> Void) throws -> RunReport {
        var object = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        edit(&object)
        return try RunReport.decode(from: JSONSerialization.data(withJSONObject: object))
    }

    var validOutcomes: [MutationOutcome] { [.killedByAssertion, .killedByAssertion, .survived] }

    @Test("a consistent report with a score passes validation")
    func consistentReportPasses() {
        #expect(QualityGate.evaluate(report: report(outcomes: validOutcomes), thresholds: QualityGateThresholds()).passed)
    }

    @Test("a stored score that differs from the re-tally fails the gate")
    func inflatedStoredScoreFails() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            $0["score"] = ["killed": 3, "survived": 0, "noCoverage": 0, "excluded": [String: Int]()]
        }
        let result = QualityGate.evaluate(report: forged, thresholds: QualityGateThresholds(minimumTested: 0.9))
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .reportInconsistent && $0.detail.contains("score.recompute") })
    }

    @Test("an inflated score fails even when no threshold is configured")
    func inflatedScoreFailsWithoutThresholds() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            $0["score"] = ["killed": 3, "survived": 0, "noCoverage": 0, "excluded": [String: Int]()]
        }
        #expect(!QualityGate.evaluate(report: forged, thresholds: QualityGateThresholds()).passed)
    }

    @Test("a stored classified count that disagrees with the results fails")
    func classifiedCountMismatchFails() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            var integrity = $0["integrity"] as? [String: Any] ?? [:]
            integrity["classified"] = 99
            $0["integrity"] = integrity
        }
        let result = QualityGate.evaluate(report: forged, thresholds: QualityGateThresholds())
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .reportInconsistent && $0.detail.contains("integrity.classified") })
    }

    @Test("a duplicated result fails the gate")
    func duplicateResultFails() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            var results = $0["results"] as? [Any] ?? []
            results.append(results[0])
            $0["results"] = results
        }
        let result = QualityGate.evaluate(report: forged, thresholds: QualityGateThresholds())
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .reportInconsistent && $0.detail.contains("report.ledger") })
    }

    @Test("the same mutation reported twice under different work units fails the gate")
    func duplicateMutationIDAcrossRefsFails() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            var results = $0["results"] as? [[String: Any]] ?? []
            var copy = results[0]
            var ref = copy["mutationRef"] as? [String: Any] ?? [:]
            ref["workUnitID"] = "another-unit"
            copy["mutationRef"] = ref
            results.append(copy)
            var integrity = $0["integrity"] as? [String: Any] ?? [:]
            integrity["classified"] = results.count
            $0["integrity"] = integrity
            $0["results"] = results
        }
        let result = QualityGate.evaluate(report: forged, thresholds: QualityGateThresholds())
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .reportInconsistent && $0.detail.contains("report.duplicates") })
    }

    @Test("passing integrity with fewer classified results than planned fails")
    func plannedClassifiedMismatchFails() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            var integrity = $0["integrity"] as? [String: Any] ?? [:]
            integrity["planned"] = 10
            $0["integrity"] = integrity
        }
        let result = QualityGate.evaluate(report: forged, thresholds: QualityGateThresholds())
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .reportInconsistent && $0.detail.contains("integrity.classified") })
    }

    @Test("an interrupted report keeps failing as scoreUnavailable, not as inconsistent")
    func interruptedReportIsNotInconsistent() {
        let result = QualityGate.evaluate(report: emptyReport(integrityPassed: false), thresholds: QualityGateThresholds())
        #expect(result.violations.map(\.kind) == [.scoreUnavailable])
    }

    @Test("an inconsistent --baseline report fails regression checks as baselineInconsistent")
    func inconsistentBaselineFails() throws {
        let forged = try tampered(report(outcomes: [.killedByAssertion, .survived])) {
            $0["score"] = ["killed": 2, "survived": 0, "noCoverage": 0, "excluded": [String: Int]()]
        }
        let result = QualityGate.evaluate(
            report: report(outcomes: [.killedByAssertion, .survived]),
            thresholds: QualityGateThresholds(regressionMaximumDrop: 0.5), baseline: forged
        )
        #expect(!result.passed)
        #expect(result.violations.contains { $0.kind == .baselineInconsistent })
    }

    @Test("an inconsistent baseline is not consulted when no regression threshold needs it")
    func unusedInconsistentBaselineIgnored() throws {
        let forged = try tampered(report(outcomes: validOutcomes)) {
            $0["score"] = ["killed": 3, "survived": 0, "noCoverage": 0, "excluded": [String: Int]()]
        }
        #expect(QualityGate.evaluate(
            report: report(outcomes: validOutcomes), thresholds: QualityGateThresholds(), baseline: forged
        ).passed)
    }

    @Test("a legacy report with no stored score is absent evidence, not a contradiction")
    func missingStoredScoreIsNotContradiction() throws {
        let legacy = try tampered(report(outcomes: validOutcomes)) { $0["score"] = nil }
        let result = QualityGate.evaluate(report: legacy, thresholds: QualityGateThresholds())
        #expect(!result.violations.contains { $0.kind == .reportInconsistent })
    }
}
