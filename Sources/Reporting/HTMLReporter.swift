import Foundation
import MutationModel

/// A single self-contained HTML file: the report you can email, attach to a CI
/// build, or open on a plane.
///
/// No CDN, no external stylesheet, no font, no script. Two reasons, both hard
/// requirements rather than preferences: the report must render with no network,
/// and a report full of a customer's proprietary source must not make the source
/// reachable by any third party the moment someone opens it in a browser.
public struct HTMLReporter: Reporter {
    public init() {}

    public func render(_ report: RunReport) throws -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>MutantKit report — \(report.planID.htmlEscaped)</title>
        <style>
        \(Self.stylesheet)
        </style>
        </head>
        <body>
        <main>
        \(headerHTML(report))
        \(scoreHTML(report))
        \(baselineHTML(report))
        \(integrityHTML(report))
        \(outcomesHTML(report))
        \(excludedHTML(report))
        \(survivorsHTML(report))
        </main>
        </body>
        </html>
        """
    }

    // MARK: Sections

    private func headerHTML(_ report: RunReport) -> String {
        """
        <header>
          <h1>MutantKit mutation report</h1>
          <dl class="meta">
            <dt>Plan</dt><dd><code>\(report.planID.htmlEscaped)</code></dd>
            <dt>Project</dt><dd><code>\(report.projectRoot.htmlEscaped)</code></dd>
            <dt>Started</dt><dd>\(Format.timestamp(report.startedAt).htmlEscaped)</dd>
            <dt>Finished</dt><dd>\(Format.timestamp(report.finishedAt).htmlEscaped)</dd>
            <dt>Toolchain</dt><dd>MutantKit \(report.toolchain.toolVersion.htmlEscaped), Swift \(report.toolchain.swiftVersion.htmlEscaped)</dd>
          </dl>
        </header>
        """
    }

    private func scoreHTML(_ report: RunReport) -> String {
        // Fail-closed: the score card is replaced outright rather than filled
        // with a dash or a zero. A zero in this position is a specific, false
        // claim about the test suite.
        guard let score = report.score else {
            return """
            <section class="card fail-closed">
              <h2>\(FailClosed.headline.htmlEscaped)</h2>
              <p>\(FailClosed.explanation.htmlEscaped)</p>
            </section>
            """
        }

        return """
        <section class="scores">
          <div class="card score">
            <h2>Tested Mutation Score</h2>
            <p class="value">\(Format.percent(score.tested)?.htmlEscaped ?? "n/a")</p>
            <p class="formula"><code>killed / (killed + survived)</code></p>
            <p class="detail">\(score.killed) / \(score.killed + score.survived)</p>
            <p class="detail">Of the code your tests actually run, how much do they check?</p>
          </div>
          <div class="card score">
            <h2>Effective Mutation Score</h2>
            <p class="value">\(Format.percent(score.effective)?.htmlEscaped ?? "n/a")</p>
            <p class="formula"><code>killed / (killed + survived + noCoverage)</code></p>
            <p class="detail">\(score.killed) / \(score.killed + score.survived + score.noCoverage)</p>
            <p class="detail">Of the code you asked to be mutated, how much is checked?</p>
          </div>
        </section>
        """
    }

    private func baselineHTML(_ report: RunReport) -> String {
        let baseline = report.baseline
        let badge = baseline.passed
            ? #"<span class="badge ok">passed</span>"#
            : #"<span class="badge bad">failed</span>"#

        // See ConsoleReporter: absent counts are reported as absent, never as zero.
        let counts = baseline.testSummary.map { summary in
            "\(summary.passed) of \(summary.total) tests passing, \(summary.failed) failing"
        } ?? "test counts unavailable — the runner reported no per-test breakdown"

        return """
        <section class="card">
          <h2>Baseline \(badge)</h2>
          <p>\(counts.htmlEscaped), in \(Format.seconds(baseline.durationSeconds).htmlEscaped).</p>
        </section>
        """
    }

    private func integrityHTML(_ report: RunReport) -> String {
        let integrity = report.integrity
        let badge = integrity.passed
            ? #"<span class="badge ok">passed</span>"#
            : #"<span class="badge bad">failed</span>"#

        var html = """
        <section class="card">
          <h2>Integrity \(badge)</h2>
          <table>
            <tr><th>discovered</th><td>\(integrity.discovered)</td><th>planned</th><td>\(integrity.planned)</td></tr>
            <tr><th>source applied</th><td>\(integrity.sourceApplied)</td><th>build observed</th><td>\(integrity.buildObserved)</td></tr>
            <tr><th>build failures</th><td>\(integrity.buildFailures)</td><th>executed</th><td>\(integrity.executed)</td></tr>
            <tr><th>classified</th><td>\(integrity.classified)</td><th>reported</th><td>\(integrity.reported)</td></tr>
            <tr><th>skipped</th><td>\(integrity.explicitlySkipped)</td><th></th><td></td></tr>
          </table>
        """

        if !integrity.violations.isEmpty {
            html += "\n  <h3>Violations</h3>\n  <ul class=\"violations\">"
            for violation in integrity.violations {
                let id = violation.mutationID.map { " <code>\($0.rawValue.htmlEscaped)</code>" } ?? ""
                html += """

                    <li><strong>\(violation.kind.rawValue.htmlEscaped)</strong>\(id)<br>\(violation.detail.htmlEscaped)</li>
                """
            }
            html += "\n  </ul>"
        }

        return html + "\n</section>"
    }

    private func outcomesHTML(_ report: RunReport) -> String {
        var rows = ""
        for (outcome, count) in report.outcomeCounts {
            let cssClass = outcome.isKilled ? "ok" : (outcome == .survived ? "bad" : "neutral")
            rows += """

                <tr class="\(cssClass)">
                  <td>\(outcome.displayName.htmlEscaped)</td>
                  <td class="num">\(count)</td>
                  <td>\(outcome.isScorable ? "in denominator" : "excluded")</td>
                </tr>
            """
        }

        return """
        <section class="card">
          <h2>Outcomes</h2>
          <table class="outcomes">
            <thead><tr><th>Outcome</th><th class="num">Count</th><th>Scoring</th></tr></thead>
            <tbody>\(rows)
            </tbody>
          </table>
        </section>
        """
    }

    private func excludedHTML(_ report: RunReport) -> String {
        guard !report.excludedCounts.isEmpty else { return "" }

        var items = ""
        for (outcome, count) in report.excludedCounts {
            items += "\n    <li>\(outcome.displayName.htmlEscaped): <strong>\(count)</strong></li>"
        }

        return """
        <section class="card excluded">
          <h2>Excluded from every denominator (\(report.excludedTotal))</h2>
          <p>These outcomes are facts about the tool run, not about the test suite.
          They appear in neither the Tested nor the Effective score.</p>
          <ul>\(items)
          </ul>
        </section>
        """
    }

    /// Grouped via the shared `SurvivorPresentation` model — the identical
    /// rows `CISummaryReporter` and `ConsoleReporter` render from, so all
    /// three agree on cluster identity, membership, and counts for the same
    /// run. Unlike `CISummaryReporter`'s compact PR-comment scope, this is a
    /// full local report: both actionable reasons are shown, in their own
    /// sections, and every clustered mutant's own diff stays reachable —
    /// grouping only avoids repeating the declaration header, it never hides
    /// a member's own change behind a single representative.
    private func survivorsHTML(_ report: RunReport) -> String {
        let presentation = SurvivorPresentationBuilder.build(from: report)
        let rows = presentation.rows
        guard !rows.isEmpty else {
            return """
            <section class="card">
              <h2>Actionable test gaps (0)</h2>
              <p>\(noActionableGapsMessage(report))</p>
            </section>
            """
        }

        let notCovered = rows.filter { $0.reason == .mutationSiteNotCovered }
        let survived = rows.filter { $0.reason != .mutationSiteNotCovered }
        let aggregate = rows.aggregate

        var html = """
        <section>
          <h2>Actionable test gaps (\(aggregate.totalMutants), \(aggregate.distinctIssues) distinct issue(s))</h2>
        """

        if !notCovered.isEmpty {
            html += "\n  <h3>Not covered — \(notCovered.aggregate.totalMutants) mutant(s)</h3>"
            for row in notCovered { html += rowHTML(row) }
        }
        if !survived.isEmpty {
            html += "\n  <h3>\(presentation.survivedHeading(mutants: survived.aggregate.totalMutants))</h3>"
            if !presentation.coverageMeasured { html += "\n  <p>\(SurvivorPresentation.coverageNotMeasuredNote)</p>" }
            for row in survived { html += rowHTML(row) }
        }

        return html + "\n</section>"
    }

    private func rowHTML(_ row: SurvivorPresentation.Row) -> String {
        let countTag = row.count > 1 ? "<span class=\"tag\">×\(row.count)</span>" : ""
        var html = """

        <article class="card survivor">
          <h3><code>\(row.declaration.htmlEscaped)</code></h3>
          <p class="meta-line">
            \(row.operatorIDs.map { "<span class=\"tag\">\($0.htmlEscaped)</span>" }.joined())
            \(countTag)
          </p>
        \(testScopeHTML(row))
        """

        // Every clustered mutant keeps its own sub-card — clustering means
        // "these share one root-cause story," not "these are the same
        // mutation," so no member's own location/diagnosis/diff is ever
        // dropped to make room for another's.
        for member in row.members {
            html += """

              <div class="survivor-member">
                <p class="meta-line"><code>\(member.displayLocation.htmlEscaped)</code> \
            <span class="tag">\(member.mutantID.htmlEscaped)</span></p>
                <p>\(member.diagnosis.htmlEscaped)</p>
            \(diffHTML(member))
              </div>
            """
        }

        return html + "\n</article>"
    }

    /// Distinguishes "no test executed this exact mutation site" from
    /// "these specific tests are known to have run and passed anyway" (or,
    /// honestly, "the run's own evidence does not say which tests ran")
    /// whenever the reason is `.coveredButNotCaught`.
    private func testScopeHTML(_ row: SurvivorPresentation.Row) -> String {
        switch row.reason {
        case .mutationSiteNotCovered:
            return "  <p class=\"detail\">No test executed this mutation site.</p>"
        case .coveredButNotCaught:
            switch row.testScope {
            case .none, .unknown:
                return "  <p class=\"detail\">Tests run: unknown — the run's own evidence does not record which tests ran here.</p>"
            case .fullSuite:
                return "  <p class=\"detail\">Tests run: full configured suite.</p>"
            case let .narrowed(tests):
                let items = tests.map { "<code>\($0.htmlEscaped)</code>" }.joined(separator: ", ")
                return "  <p class=\"detail\">Tests run: \(items)</p>"
            }
        }
    }

    /// Every byte here originates in the user's source, which may contain
    /// `</script>`, `<img onerror=…>`, or anything else. It is escaped
    /// unconditionally — there is no path through this reporter that emits
    /// unescaped source.
    private func diffHTML(_ member: SurvivorActionabilityReport.Member) -> String {
        guard let diff = member.sourceDiff, !diff.isEmpty else {
            return "  <p class=\"detail\">(no diff recorded)</p>"
        }

        var lines = ""
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let cssClass: String
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                cssClass = "diff-meta"
            } else if line.hasPrefix("+") {
                cssClass = "diff-add"
            } else if line.hasPrefix("-") {
                cssClass = "diff-del"
            } else {
                cssClass = "diff-ctx"
            }
            lines += "<span class=\"\(cssClass)\">\(line.htmlEscaped)</span>\n"
        }
        return "  <pre class=\"diff\">\(lines)</pre>"
    }
}

// MARK: - Escaping

extension String {
    /// Escapes the five characters that can break out of text or an attribute.
    /// `&` must be replaced first or it would double-escape the entities the
    /// later replacements introduce.
    var htmlEscaped: String {
        var out = replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}

/// "Every mutant that ran was killed" is vacuous when none ran (a red
/// baseline, a baseline mismatch), so say what happened instead.
private func noActionableGapsMessage(_ report: RunReport) -> String {
    report.integrity.executed == 0 ? "No mutants were executed." : "Every mutant that ran was killed."
}
