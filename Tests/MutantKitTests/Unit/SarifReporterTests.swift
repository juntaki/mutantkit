import Foundation
import MutationModel
@testable import Reporting
import Testing

/// Mirrors `SonarReporterTests`' own reasoning almost exactly — the two
/// reporters share the same survivors-only, fail-closed policy (see
/// `SarifReporter`'s doc comment) — plus a check against SARIF 2.1.0's own
/// required top-level structure, the bar the task asked for absent a real
/// external SARIF validator.
@Suite("SARIF reporter")
struct SarifReporterTests {
    @Test("A survived mutant produces exactly one result at its source location")
    func survivedMutantProducesResult() throws {
        let point = try makeAnchoredPoint(file: "Sources/Widget.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived, diagnosis: "no test covered this mutant")]
        )

        let log = try Self.renderAndDecode(report)
        let run = try #require(log.runs.first)

        #expect(run.results.count == 1)
        let result = try #require(run.results.first)
        let location = try #require(result.locations.first)
        #expect(location.physicalLocation.artifactLocation.uri == point.file)
        // SARIF region line/column are 1-based, same as ours — no
        // translation, unlike Sonar's 0-based columns.
        #expect(location.physicalLocation.region.startLine == point.line)
        #expect(location.physicalLocation.region.startColumn == point.column)
        // `originalText` here is ASCII-only, so UTF-8 byte count and
        // `Character` count coincide; `endColumnCountsUTF8BytesNotCharacters`
        // below is the test that tells them apart.
        #expect(location.physicalLocation.region.endColumn == point.column + point.originalText.utf8.count)
        // `byteOffset`/`byteLength` are columnKind-independent and come
        // straight from the point's own exact whole-file byte range — see
        // `SarifRegion`'s doc comment for why these exist alongside the
        // line/column pair above.
        #expect(location.physicalLocation.region.byteOffset == point.utf8Range.start)
        #expect(location.physicalLocation.region.byteLength == point.utf8Range.length)

        #expect(result.message.text.contains(point.operatorID))
        #expect(result.message.text.contains(point.originalText))
        #expect(result.message.text.contains(point.replacementText))
        #expect(result.message.text.contains("no test covered this mutant"))
        #expect(result.level == .warning)

        // The result references a rule that actually exists in the run, and
        // that rule is scoped to the operator that produced the mutant.
        #expect(result.ruleId == "mutantkit/\(point.operatorID)")
        let rule = try #require(run.tool.driver.rules.first)
        #expect(run.tool.driver.rules.count == 1)
        #expect(rule.id == result.ruleId)
        #expect(rule.shortDescription.text.contains(point.operatorID))
    }

    @Test("A killed mutant produces no result")
    func killedMutantProducesNoResult() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])

        let log = try Self.renderAndDecode(report)

        #expect(log.runs[0].results.isEmpty)
        #expect(log.runs[0].tool.driver.rules.isEmpty)
    }

    /// Same allow-list posture as `SonarReporterTests
    /// .onlySurvivedBecomesAnIssue`: every non-`.survived` outcome stays out
    /// of the export, a new outcome case included by construction.
    @Test("Only .survived becomes a result; every other outcome is excluded")
    func onlySurvivedBecomesAResult() throws {
        let outcomes: [MutationOutcome] = [
            .killedByAssertion, .killedByCrash, .verifiedTimeout,
            .noCoverage, .unviable, .timedOut, .flaky,
            .notApplied, .baselineMismatch, .infrastructureFailure, .skipped
        ]

        for outcome in outcomes {
            let point = try makeAnchoredPoint()
            let plan = makePlan(mutations: [point])
            let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: outcome)])

            let log = try Self.renderAndDecode(report)
            #expect(log.runs[0].results.isEmpty, "\(outcome) produced a result")
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

        let log = try Self.renderAndDecode(report)

        #expect(log.runs[0].results.count == 2)
        #expect(log.runs[0].tool.driver.rules.count == 1, "both mutants came from the same operator and should share a rule")
    }

    /// Same fail-closed reasoning as `SonarReporterTests
    /// .integrityFailureProducesNoIssues`: a `.survived` verdict from a run
    /// whose integrity failed is not a trustworthy claim and must not
    /// surface as a SARIF result either.
    ///
    /// But an empty `results` array alone is exactly what a fully clean,
    /// integrity-passing run with zero survivors would also produce (see
    /// `killedMutantProducesNoResult` above) — so this test's real job is
    /// checking that the *invocation* carries the distinguishing signal a
    /// results-only reading would miss entirely.
    @Test("An integrity-failed run produces an empty, still-valid SARIF log distinguishable from a clean one")
    func integrityFailureProducesNoResults() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived)],
            baselinePassed: false
        )

        #expect(report.score == nil)

        let log = try Self.renderAndDecode(report)
        #expect(log.runs[0].results.isEmpty)
        #expect(log.runs[0].tool.driver.rules.isEmpty)
        // Still a structurally complete run — a consumer reads this as "the
        // tool ran and found nothing", not as a malformed file.
        #expect(!log.runs[0].tool.driver.name.isEmpty)

        // The signal an empty `results` array cannot carry on its own: SARIF's
        // own mechanism for "this run's findings cannot be trusted", present
        // inside the file itself rather than only in an external channel.
        let invocation = try #require(log.runs[0].invocations.first)
        #expect(invocation.executionSuccessful == false)
        let notification = try #require(invocation.toolExecutionNotifications?.first)
        #expect(notification.level == .error)
        #expect(notification.message.text.contains(FailClosed.headline))
    }

    /// The mirror of the test above: a genuinely clean run — integrity
    /// passed, nothing survived — must set `executionSuccessful == true` and
    /// carry no notifications, or the failure-path signal just added would
    /// itself be meaningless noise a consumer could not use to tell the two
    /// runs apart.
    @Test("A clean run's invocation records executionSuccessful == true with no notifications")
    func cleanRunInvocationRecordsSuccess() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])

        #expect(report.score != nil)

        let log = try Self.renderAndDecode(report)
        let invocation = try #require(log.runs[0].invocations.first)
        #expect(invocation.executionSuccessful == true)
        #expect(invocation.toolExecutionNotifications == nil)
    }

    /// The bar the task set absent a real external SARIF validator: this
    /// checks the rendered JSON, parsed independently of `SarifLog`'s own
    /// `Decodable` conformance (which would silently tolerate a missing
    /// optional key the way `StrykerReporterTests` warns about for
    /// `StrykerReport`), against SARIF 2.1.0's own required top-level shape.
    /// The exact `required` fields checked below were read straight out of
    /// the real, official schema (oasis-tcs/sarif-spec's
    /// `sarif-schema-2.1.0.json`), not recalled from the prose spec: the
    /// root requires `version`/`runs`; `run` requires `tool`; `tool`
    /// requires `driver`; `toolComponent` (`driver`) requires only `name`;
    /// `result` requires `message`. This test's hand-built sample shape was
    /// separately round-tripped through that same real schema with Python's
    /// `jsonschema` validator (a real, general-purpose one, independent of
    /// anything in this codebase) — zero violations.
    @Test("Output matches SARIF 2.1.0's own required top-level structure")
    func outputMatchesRealSarifRequiredStructure() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .survived, diagnosis: "diag")])

        let json = try SarifReporter().render(report)
        let document = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(document["version"] as? String == "2.1.0")
        #expect((document["$schema"] as? String)?.isEmpty == false)

        let runs = try #require(document["runs"] as? [[String: Any]])
        #expect(!runs.isEmpty)
        let run = try #require(runs.first)

        let tool = try #require(run["tool"] as? [String: Any])
        let driver = try #require(tool["driver"] as? [String: Any])
        #expect((driver["name"] as? String)?.isEmpty == false, "tool.driver.name is SARIF's one required toolComponent field")

        let results = try #require(run["results"] as? [[String: Any]])
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result["ruleId"] is String)
        #expect(result["level"] as? String == "warning")
        let message = try #require(result["message"] as? [String: Any])
        #expect((message["text"] as? String)?.isEmpty == false, "message.text is required on every SARIF result")

        let locations = try #require(result["locations"] as? [[String: Any]])
        #expect(locations.count == 1)
        let physicalLocation = try #require(locations.first?["physicalLocation"] as? [String: Any])
        let artifactLocation = try #require(physicalLocation["artifactLocation"] as? [String: Any])
        #expect(artifactLocation["uri"] as? String == point.file)
        let region = try #require(physicalLocation["region"] as? [String: Any])
        for key in ["startLine", "startColumn", "endLine", "endColumn"] {
            #expect(region[key] is Int, "region missing required-shaped field '\(key)'")
        }

        let rules = try #require(driver["rules"] as? [[String: Any]])
        #expect(rules.count == 1)
        #expect(
            rules.first?["id"] as? String == result["ruleId"] as? String,
            "SARIF requires a result's ruleId to resolve to a rule in tool.driver.rules"
        )
    }

    // MARK: - Helpers

    private static func renderAndDecode(_ report: RunReport) throws -> SarifLog {
        let json = try SarifReporter().render(report)
        return try MutationPlan.decoder().decode(SarifLog.self, from: Data(json.utf8))
    }
}
