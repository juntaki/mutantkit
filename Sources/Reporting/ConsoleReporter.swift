import Foundation
import MutationModel

#if canImport(Darwin)
    import Darwin
#endif

/// Human-readable terminal output. The default report, and the one most people
/// will ever read.
public struct ConsoleReporter: Reporter {
    private let palette: Palette

    /// - Parameter colorEnabled: defaults to a TTY probe on stdout. Colour codes
    ///   in a redirected stream end up in log files and CI artifacts as mojibake,
    ///   and tests need a stable byte sequence to compare against.
    public init(colorEnabled: Bool = isatty(1) != 0) {
        palette = Palette(enabled: colorEnabled)
    }

    public func render(_ report: RunReport) throws -> String {
        var out: [String] = []

        out.append(header(report))
        out.append(baselineSection(report))
        out.append(integritySection(report))
        out.append(scoreSection(report))
        out.append(outcomeSection(report))
        out.append(excludedSection(report))
        out.append(survivorSection(report))

        return out.joined(separator: "\n\n") + "\n"
    }

    // MARK: Sections

    private func header(_ report: RunReport) -> String {
        """
        \(palette.bold("MutantKit mutation run"))  \(report.planID)
          project    \(report.projectRoot)
          started    \(Format.timestamp(report.startedAt))
          finished   \(Format.timestamp(report.finishedAt))
          toolchain  MutantKit \(report.toolchain.toolVersion), Swift \(report.toolchain.swiftVersion)
        """
    }

    private func baselineSection(_ report: RunReport) -> String {
        let baseline = report.baseline
        let status = baseline.passed
            ? palette.green("PASSED")
            : palette.red("FAILED")

        var lines = [palette.bold("Baseline")]
        lines.append("  status   \(status) in \(Format.seconds(baseline.durationSeconds))")
        // "0/0 passing" would be a fabricated measurement: the runner not
        // reporting counts is a different fact from a suite of no tests, and the
        // second one reads as far more alarming than the truth.
        if let summary = baseline.testSummary {
            lines.append("  tests    \(summary.passed)/\(summary.total) passing, \(summary.failed) failing")
        } else {
            lines.append("  tests    counts unavailable — the runner reported no per-test breakdown")
        }

        if !baseline.passed {
            // Without a green baseline a "survived" mutant means nothing, so say
            // so next to the status rather than leaving the reader to infer it.
            lines.append("  \(palette.red("A red baseline invalidates every mutant outcome in this run."))")
        }
        return lines.joined(separator: "\n")
    }

    private func integritySection(_ report: RunReport) -> String {
        let integrity = report.integrity
        var lines = [palette.bold("Integrity")]

        lines.append("  status     " + (integrity.passed ? palette.green("passed") : palette.red("FAILED (\(integrity.violations.count) violation(s))")))
        lines.append("  discovered \(integrity.discovered)   planned \(integrity.planned)   skipped \(integrity.explicitlySkipped)")
        if integrity.skippedByReason.count > 1
            || integrity.skippedByReason.first?.reason != .budgetExceeded {
            // A single, all-budget skip list is what a sampled run always
            // looks like and would just repeat the line above; the breakdown
            // earns its place once more than one reason is in play, or the
            // one reason present is not the expected one.
            let breakdown = integrity.skippedByReason
                .map { "\($0.reason.rawValue): \($0.count)" }
                .joined(separator: ", ")
            lines.append("             \(breakdown)")
        }
        lines.append("  applied    \(integrity.sourceApplied)   built \(integrity.buildObserved)   build failures \(integrity.buildFailures)")
        lines.append("  executed   \(integrity.executed)   classified \(integrity.classified)   reported \(integrity.reported)")

        for violation in integrity.violations {
            let location = violation.mutationID.map { " [\($0)]" } ?? ""
            lines.append("  \(palette.red("•")) \(violation.kind.rawValue)\(location)")
            for line in violation.detail.wrapped(at: 88) {
                lines.append("    \(line)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func scoreSection(_ report: RunReport) -> String {
        guard let score = report.score else {
            return failClosedBanner(report)
        }

        return """
        \(palette.bold("Score"))
          Tested Mutation Score     = killed / (killed + survived)
                                    = \(Format.ratio(
                                        numerator: score.killed,
                                        denominator: score.killed + score.survived,
                                        value: score.tested
                                    ))
          Effective Mutation Score  = killed / (killed + survived + noCoverage)
                                    = \(Format.ratio(
                                        numerator: score.killed,
                                        denominator: score.killed + score.survived + score.noCoverage,
                                        value: score.effective
                                    ))
        """
    }

    private func failClosedBanner(_ report: RunReport) -> String {
        let rule = String(repeating: "━", count: 72)
        var lines = [
            palette.red(rule),
            palette.red(palette.bold(FailClosed.headline)),
            palette.red(rule)
        ]
        for line in FailClosed.explanation.wrapped(at: 72) {
            lines.append(line)
        }
        lines.append("")
        lines.append(palette.bold("Violations to fix before this run can produce a score:"))
        for violation in report.integrity.violations {
            lines.append("  \(palette.red("•")) \(violation.kind.rawValue): \(violation.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private func outcomeSection(_ report: RunReport) -> String {
        var lines = [palette.bold("Outcomes")]
        let width = MutationOutcome.allCases.map(\.displayName.count).max() ?? 0

        for (outcome, count) in report.outcomeCounts {
            let name = outcome.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
            let value = String(count).leftPadded(to: 5)
            lines.append("  \(colored(name, for: outcome, zero: count == 0))\(value)")
        }
        return lines.joined(separator: "\n")
    }

    private func excludedSection(_ report: RunReport) -> String {
        var lines = [palette.bold("Excluded — counted, never in a denominator")]

        guard !report.excludedCounts.isEmpty else {
            lines.append("  (none)")
            return lines.joined(separator: "\n")
        }

        let width = report.excludedCounts.map { $0.outcome.displayName.count }.max() ?? 0
        for (outcome, count) in report.excludedCounts {
            let name = outcome.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(name)\(String(count).leftPadded(to: 5))")
        }
        lines.append("  \("total".padding(toLength: width, withPad: " ", startingAt: 0))\(String(report.excludedTotal).leftPadded(to: 5))")
        lines.append("  These outcomes describe the tool run, not the test suite. They are in")
        lines.append("  neither the Tested nor the Effective denominator.")
        return lines.joined(separator: "\n")
    }

    /// Grouped via the shared `SurvivorPresentation` model — the identical
    /// rows `CISummaryReporter` and `HTMLReporter` render from, so all three
    /// agree on cluster identity, membership, and counts for the same run.
    /// Unlike `CISummaryReporter`'s compact PR-comment scope, this is a full
    /// local report: both actionable reasons are shown, split into their own
    /// subsections, and every clustered mutant's own diff stays printed —
    /// grouping only avoids repeating the declaration/location header, it
    /// never hides a member's own change the way an earlier version's
    /// single-representative-per-row design did.
    private func survivorSection(_ report: RunReport) -> String {
        let rows = SurvivorPresentationBuilder.build(from: report).rows

        guard !rows.isEmpty else {
            return [
                palette.bold("Actionable test gaps (0)"),
                "  none — every mutant that ran was killed"
            ].joined(separator: "\n")
        }

        let notCovered = rows.filter { $0.reason == .mutationSiteNotCovered }
        let survived = rows.filter { $0.reason != .mutationSiteNotCovered }
        let aggregate = rows.aggregate

        var lines = [
            palette.bold("Actionable test gaps (\(aggregate.totalMutants), \(aggregate.distinctIssues) distinct issue(s))")
        ]

        if !notCovered.isEmpty {
            lines.append("")
            lines.append(palette.bold("Not covered — \(notCovered.aggregate.totalMutants) mutant(s)"))
            for row in notCovered { lines.append(contentsOf: renderRow(row)) }
        }
        if !survived.isEmpty {
            lines.append("")
            lines.append(palette.bold("Covered but survived — \(survived.aggregate.totalMutants) mutant(s)"))
            for row in survived { lines.append(contentsOf: renderRow(row)) }
        }
        return lines.joined(separator: "\n")
    }

    private func renderRow(_ row: SurvivorPresentation.Row) -> [String] {
        let countSuffix = row.count > 1 ? "  \(palette.dim("(×\(row.count))"))" : ""
        var lines: [String] = [
            "", "  \(palette.dim("in \(row.declaration) (\(row.operatorIDs.joined(separator: ", ")))"))\(countSuffix)"
        ]

        switch row.reason {
        case .mutationSiteNotCovered:
            lines.append("  Fix: add or extend a test that reaches this exact path.")
        case .coveredButNotCaught:
            switch row.testScope {
            case .none, .unknown:
                lines.append("  Tests run: unknown — the run's own evidence does not record which tests ran here.")
            case .fullSuite:
                lines.append("  Tests run: full configured suite.")
            case let .narrowed(tests):
                lines.append("  Tests run: \(tests.joined(separator: ", "))")
            }
        }

        // Every clustered mutant keeps its own header line, diagnosis, and
        // diff — clustering means "these share one root-cause story," not
        // "these are the same mutation," so no member's own change is ever
        // dropped to make room for another's.
        for member in row.members {
            lines.append("  \(palette.yellow(member.displayLocation))  [\(member.mutantID)]")
            lines.append("    \(member.diagnosis)")
            if let diff = member.sourceDiff, !diff.isEmpty {
                for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(diffColored(String(line)))")
                }
            } else {
                lines.append("    \(palette.dim("(no diff recorded)"))")
            }
        }
        return lines
    }

    // MARK: Colour

    private func colored(_ text: String, for outcome: MutationOutcome, zero: Bool) -> String {
        guard !zero else { return palette.dim(text) }
        if outcome.isKilled { return palette.green(text) }
        if outcome == .survived { return palette.red(text) }
        if outcome == .noCoverage { return palette.yellow(text) }
        if outcome.isIntegrityViolation { return palette.red(text) }
        return text
    }

    private func diffColored(_ line: String) -> String {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return palette.dim(line)
        }
        if line.hasPrefix("+") { return palette.green(line) }
        if line.hasPrefix("-") { return palette.red(line) }
        return line
    }
}

// MARK: - Palette

/// ANSI escapes, inlined. A colour dependency would be a build-time cost for
/// eight escape sequences.
private struct Palette {
    let enabled: Bool

    private func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    func bold(_ text: String) -> String { wrap(text, "1") }
    func dim(_ text: String) -> String { wrap(text, "2") }
    func red(_ text: String) -> String { wrap(text, "31") }
    func green(_ text: String) -> String { wrap(text, "32") }
    func yellow(_ text: String) -> String { wrap(text, "33") }
}

// MARK: - Text helpers

extension String {
    /// Greedy word wrap. Diagnoses are written as sentences and a terminal is
    /// the one place they have to fit.
    func wrapped(at width: Int) -> [String] {
        var lines: [String] = []
        var current = ""

        for word in split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
