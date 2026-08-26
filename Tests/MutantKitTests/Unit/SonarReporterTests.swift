import Foundation
import MutationModel
@testable import Reporting
import Testing

/// SonarQube's quality gate cares about what still needs fixing, not what
/// already passed — so the load-bearing invariant here is the same one
/// `StrykerReporterTests` guards for its own schema: a killed mutant, or an
/// integrity-broken run, must never be laundered into something that reads
/// as an actionable finding.
@Suite("Sonar reporter")
struct SonarReporterTests {
    @Test("A survived mutant produces exactly one issue at its source location")
    func survivedMutantProducesIssue() throws {
        let point = try makeAnchoredPoint(file: "Sources/Widget.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived, diagnosis: "no test covered this mutant")]
        )

        let payload = try Self.renderAndDecode(report)

        #expect(payload.issues.count == 1)
        let issue = try #require(payload.issues.first)
        #expect(issue.primaryLocation.filePath == point.file)
        #expect(issue.primaryLocation.textRange.startLine == point.line)
        // Sonar columns are 0-based; ours are 1-based.
        #expect(issue.primaryLocation.textRange.startColumn == point.column - 1)
        #expect(issue.primaryLocation.textRange.endColumn == point.column - 1 + point.originalText.count)

        #expect(issue.primaryLocation.message.contains(point.operatorID))
        #expect(issue.primaryLocation.message.contains(point.originalText))
        #expect(issue.primaryLocation.message.contains(point.replacementText))
        #expect(issue.primaryLocation.message.contains("no test covered this mutant"))

        // The issue references a rule that actually exists in the payload,
        // and that rule is scoped to the operator that produced the mutant —
        // not a single undifferentiated "mutantkit found something" rule.
        #expect(issue.ruleId == "mutantkit:\(point.operatorID)")
        let rule = try #require(payload.rules.first)
        #expect(payload.rules.count == 1)
        #expect(rule.id == issue.ruleId)
        #expect(rule.engineId == "mutantkit")
        #expect(rule.type == .codeSmell)
        #expect(rule.severity == .major)

        // SonarQube Server 10.4+ and SonarQube Cloud require
        // `cleanCodeAttribute`/`impacts` alongside (or instead of) the
        // classic `type`/`severity` pair — see `SonarRule`'s doc comment.
        #expect(rule.cleanCodeAttribute == .tested)
        #expect(rule.impacts.count == 1)
        let impact = try #require(rule.impacts.first)
        #expect(impact.softwareQuality == .maintainability)
        #expect(impact.severity == .medium)
    }

    @Test("A killed mutant produces no issue")
    func killedMutantProducesNoIssue() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .killedByAssertion)]
        )

        let payload = try Self.renderAndDecode(report)

        #expect(payload.issues.isEmpty)
        #expect(payload.rules.isEmpty)
    }

    /// Every non-`.survived` outcome — not just the killed ones above — stays
    /// out of the export. This is the same "allow-list, not a deny-list"
    /// posture `MutationOutcome.isCacheableResult` documents: a new outcome
    /// case added later defaults to producing no issue, rather than silently
    /// becoming one because a switch happened to fall through.
    @Test("Only .survived becomes an issue; every other outcome is excluded")
    func onlySurvivedBecomesAnIssue() throws {
        let outcomes: [MutationOutcome] = [
            .killedByAssertion, .killedByCrash, .verifiedTimeout,
            .noCoverage, .unviable, .timedOut, .flaky,
            .notApplied, .baselineMismatch, .infrastructureFailure, .skipped
        ]

        for outcome in outcomes {
            let point = try makeAnchoredPoint()
            let plan = makePlan(mutations: [point])
            let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: outcome)])

            let payload = try Self.renderAndDecode(report)
            #expect(payload.issues.isEmpty, "\(outcome) produced an issue")
        }
    }

    @Test("Mutants sharing an operator share one rule")
    func mutantsSharingAnOperatorShareOneRule() throws {
        let a = try makeAnchoredPoint(file: "Sources/A.swift")
        let b = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [a, b])
        let report = makeReport(
            plan: plan,
            results: [
                makeResult(point: a, outcome: .survived),
                makeResult(point: b, outcome: .survived)
            ]
        )

        let payload = try Self.renderAndDecode(report)

        #expect(payload.issues.count == 2)
        #expect(payload.rules.count == 1, "both mutants came from the same operator and should share a rule")
    }

    /// A run whose integrity failed carries no trustworthy claim about the
    /// test suite — the same reasoning `FailClosed` documents in
    /// `Reporter.swift`. A `.survived` verdict recorded during that run is
    /// not exempt: it must not surface as a Sonar issue either.
    @Test("An integrity-failed run produces an empty payload, even with a survivor")
    func integrityFailureProducesNoIssues() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        // A failed baseline is what drives `report.score` to `nil` — see
        // `IntegrityChecker.check` / `RunReport.init`.
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived)],
            baselinePassed: false
        )

        #expect(report.score == nil)

        let payload = try Self.renderAndDecode(report)
        #expect(payload.issues.isEmpty)
        #expect(payload.rules.isEmpty)
    }

    @Test("Output is valid JSON in the generic-issue-import shape")
    func outputIsValidGenericIssueImportJSON() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .survived)])

        let json = try SonarReporter().render(report)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        // The two top-level arrays SonarQube 10.8+'s generic issue import
        // format requires (see `SonarReporter`'s doc comment for why this,
        // and not the pre-10.3 flat shape).
        let rules = try #require(object["rules"] as? [[String: Any]])
        let issues = try #require(object["issues"] as? [[String: Any]])
        #expect(rules.count == 1)
        #expect(issues.count == 1)

        let rule = try #require(rules.first)
        for key in ["id", "name", "description", "engineId", "type", "severity", "cleanCodeAttribute", "impacts"] {
            #expect(rule[key] != nil, "rule missing required-shaped field '\(key)'")
        }
        #expect(rule["cleanCodeAttribute"] as? String == "TESTED")
        let impacts = try #require(rule["impacts"] as? [[String: Any]])
        #expect(impacts.count == 1)
        let impact = try #require(impacts.first)
        #expect(impact["softwareQuality"] as? String == "MAINTAINABILITY")
        #expect(impact["severity"] as? String == "MEDIUM")

        let issue = try #require(issues.first)
        #expect(issue["ruleId"] as? String == rule["id"] as? String)
        let location = try #require(issue["primaryLocation"] as? [String: Any])
        #expect(location["message"] is String)
        #expect(location["filePath"] is String)
        let textRange = try #require(location["textRange"] as? [String: Any])
        for key in ["startLine", "endLine", "startColumn", "endColumn"] {
            #expect(textRange[key] is Int, "textRange missing required-shaped field '\(key)'")
        }
    }

    // MARK: - Helpers

    private static func renderAndDecode(_ report: RunReport) throws -> SonarPayload {
        let json = try SonarReporter().render(report)
        return try MutationPlan.decoder().decode(SonarPayload.self, from: Data(json.utf8))
    }
}
