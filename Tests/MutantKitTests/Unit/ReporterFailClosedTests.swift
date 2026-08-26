import Foundation
import MutationModel
import Reporting
import Testing

/// A score is a claim about a test suite. When integrity failed we cannot back
/// that claim, so every reporter has to refuse — no percentage, no zero, no
/// dash that a spreadsheet will coerce into a zero. The refusal has to read the
/// same way everywhere, and the positive case has to be visibly different from
/// it.
@Suite("Reporter fail-closed")
struct ReporterFailClosedTests {
    /// A passing run carries two anchored points — one killed, one survived —
    /// so the score is 50% and visibly so. The fail-closed variant uses the
    /// same plan and results but a red baseline, which forces integrity to
    /// fail and the score to be withheld.
    private let passing: (report: RunReport, plan: MutationPlan, results: [MutationResult]) = {
        let killed = anchoredPoint(file: "Sources/Killed.swift", source: killedSource)
        let survived = anchoredPoint(file: "Sources/Survived.swift", source: survivedSource)
        let plan = makePlan(mutations: [killed, survived])
        let results = [
            makeResult(point: killed, outcome: .killedByAssertion),
            makeResult(point: survived, outcome: .survived)
        ]
        let report = makeReport(plan: plan, results: results)
        return (report, plan, results)
    }()

    private func failingReport() -> RunReport {
        makeReport(plan: passing.plan, results: passing.results, baselinePassed: false)
    }

    private func passingReport() -> RunReport { passing.report }

    // MARK: - Per-reporter refusal

    @Test("Console emits no percentage and shows the fail-closed banner")
    func consoleWithholdsPercentages() throws {
        let output = try ConsoleReporter(colorEnabled: false).render(failingReport())

        #expect(!output.contains("%"))
        #expect(output.contains("NO MUTATION SCORE"))
    }

    @Test("HTML replaces the score card with the fail-closed card")
    func htmlReplacesScoreCard() throws {
        let output = try HTMLReporter().render(failingReport())

        // The CSS uses `width: 100%`, so a naive "no %" check would pass for
        // the wrong reason. Instead, assert the score-card labels and the
        // percent-formatted values are absent, and that the fail-closed card
        // is present.
        #expect(output.contains("NO MUTATION SCORE"))
        #expect(output.contains("fail-closed"))
        #expect(!output.contains("Tested Mutation Score"))
        #expect(!output.contains("Effective Mutation Score"))
        // No `XX.XX%` value (CSS widths are bare `100%` and don't match).
        #expect(try Self.percentPattern.numberOfMatches(
            in: output, range: NSRange(output.startIndex..., in: output)
        ) == 0)
    }

    @Test("CISummary leads with the CAUTION callout and emits no percentage")
    func ciSummaryWithholdsPercentages() throws {
        let output = try CISummaryReporter().render(failingReport())

        #expect(!output.contains("%"))
        #expect(output.contains("NO MUTATION SCORE"))
        #expect(output.contains("[!CAUTION]"))
    }

    @Test("Xcode emits integrity violations rather than survivor warnings")
    func xcodeEmitsViolationsNotSurvivors() throws {
        let report = failingReport()
        let output = try XcodeReporter().render(report)

        // No survivor line — the fail-closed path must not emit any "Mutant
        // survived:" line even when the run has survivors, because the run
        // cannot back that claim.
        #expect(!output.contains("Mutant survived:"))
        #expect(output.contains("NO MUTATION SCORE"))
    }

    /// Phase C6 (competitive-parity program): an integrity violation is a
    /// strictly more severe class of problem than "no test caught this
    /// mutant" — the run's own proof that a mutant was applied and observed
    /// is broken, so every verdict this run produced is untrustworthy, not
    /// just this one line. Xcode's issue navigator distinguishes exactly
    /// this severity band, so this reporter must say `error:`, never
    /// `warning:`, for every integrity-violation line it emits.
    @Test("Xcode reports every integrity violation as error, never warning")
    func xcodeIntegrityViolationsAreErrorsNotWarnings() throws {
        let report = failingReport()
        let output = try XcodeReporter().render(report)

        let lines = output.split(separator: "\n")
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(line.contains(": error: "), "expected every integrity line to be `error:`, got: \(line)")
            #expect(!line.contains(": warning: "), "an integrity violation must never render as `warning:`, got: \(line)")
        }
    }

    /// Phase C6: a survivor diagnostic must name the exact `mutantkit
    /// inspect <id>` invocation a developer runs to see the full diff and
    /// evidence — not just the bare `MutationID` in brackets, which names
    /// the mutant but not the command that unlocks its detail.
    @Test("Xcode survivor diagnostics include the mutantkit inspect command hint")
    func xcodeSurvivorDiagnosticsIncludeInspectHint() throws {
        let output = try XcodeReporter().render(passingReport())

        #expect(output.contains("Mutant survived:"))
        #expect(output.contains("mutantkit inspect "), "expected an explicit `mutantkit inspect <id>` hint: \(output)")
    }

    @Test("JSON encodes a nil score as an absent key")
    func jsonEncodesNilScoreAsAbsentKey() throws {
        let data = try JSONReporter().render(failingReport()).data(using: .utf8)!
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // The score key must be absent. JSONSerialization turns `null` into
        // NSNull, so the key being absent is what "nil" actually means here —
        // a `null` value would still be a key, and would read as "no score"
        // even when the run was clean.
        #expect(object["score"] == nil)

        // Decoding the report back preserves the nil score.
        let decoded = try MutationPlan.decoder().decode(RunReport.self, from: data)
        #expect(decoded.score == nil)
    }

    // MARK: - Stryker: every mutant ignored

    /// Stryker's schema has no concept of an untrustworthy run. The closest
    /// honest status is `Ignored`, applied to *every* mutant, with the real
    /// outcome preserved in `statusReason`. Mapping anything to `Survived`
    /// would be the exact laundering the score-side fail-closed exists to
    /// prevent.
    @Test("Stryker marks every mutant ignored when integrity fails")
    func strykerMarksAllIgnoredWhenFailing() throws {
        let report = failingReport()
        let rendered = try StrykerReporter().render(report)

        let parsed = try Self.decodeStryker(rendered)

        for (_, file) in parsed.files {
            for mutant in file.mutants {
                #expect(mutant.status == .ignored, "got \(mutant.status) for \(mutant.id)")
                #expect(mutant.statusReason?.contains("NO MUTATION SCORE") == true)
            }
        }
    }

    /// The passing case has to be visibly different: real outcomes map to real
    /// statuses, not the blanket `.ignored`.
    @Test("Stryker reports real statuses when integrity passes")
    func strykerReportsRealStatusesWhenPassing() throws {
        let report = passingReport()
        let rendered = try StrykerReporter().render(report)
        let parsed = try Self.decodeStryker(rendered)

        var statuses: [StrykerReporter.MutantStatus] = []
        for (_, file) in parsed.files {
            statuses += file.mutants.map(\.status)
        }

        // One Killed (killedByAssertion) and one Survived — the real verdicts,
        // not Ignored.
        #expect(statuses.contains(.killed))
        #expect(statuses.contains(.survived))
        #expect(!statuses.contains(.ignored))
    }

    // MARK: - Positive case visible

    /// A passing run has to carry a percentage visibly. This is the control for
    /// every "no percentage" assertion above: if a passing run also withheld
    /// its number, those assertions would be vacuous.
    @Test("A passing run visibly carries a percentage")
    func passingRunCarriesPercentage() throws {
        let report = passingReport()

        let console = try ConsoleReporter(colorEnabled: false).render(report)
        let html = try HTMLReporter().render(report)
        let ci = try CISummaryReporter().render(report)

        #expect(console.contains("%"))
        #expect(html.contains("%"))
        #expect(ci.contains("%"))
        #expect(report.score != nil)
    }

    // MARK: - Helpers

    // The pattern is a hardcoded literal, so construction cannot fail.
    // swiftlint:disable:next force_try
    private static let percentPattern = try! NSRegularExpression(
        pattern: #"\d+\.\d+%"#
    )

    private static func decodeStryker(_ json: String) throws -> StrykerReporter.StrykerReport {
        try MutationPlan.decoder().decode(
            StrykerReporter.StrykerReport.self,
            from: Data(json.utf8)
        )
    }
}

// MARK: - Anchored point fixtures

//
// The reporters only read the model, but the integrity checker (which feeds
// `score == nil`) recomputes each point's ID from its components. A hand-built
// point with a stable-looking ID is unstable, which forces integrity to fail
// for the wrong reason in the *passing* report. Going through real discovery
// produces IDs that recompute identically.

private let killedSource = """
struct Killed {
    var enabled = true
}
"""

private let survivedSource = """
struct Survived {
    var enabled = true
}
"""

private func anchoredPoint(file: String, source: String) -> MutationPoint {
    // The fixture source above is hardcoded and known to contain exactly
    // one discoverable bool-literal mutation point.
    // swiftlint:disable:next force_try
    try! discover(source, path: file, using: Operators.boolLiteral)[0]
}
