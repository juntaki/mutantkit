import Foundation
import MutationModel

// MARK: - Reporter

/// Renders a finished run into one concrete output format.
///
/// Reporters are pure functions from `RunReport` to text: they never read the
/// filesystem, never spawn a process, and never mutate the report. That is what
/// lets every format be golden-tested against a fixture, and what keeps a
/// reporting bug from being able to corrupt a run.
public protocol Reporter: Sendable {
    func render(_ report: RunReport) throws -> String
}

/// Maps a configured `ReportKind` onto the reporter that produces it.
public enum ReporterRegistry {
    /// - Note: `ConsoleReporter` is built with its default colour policy, which
    ///   probes the terminal. Callers that need colour forced off should build
    ///   the reporter directly instead of going through the registry.
    public static func reporter(for kind: ReportKind) -> any Reporter {
        switch kind {
        case .console: ConsoleReporter()
        case .xcode: XcodeReporter()
        case .json: JSONReporter()
        case .strykerJSON: StrykerReporter()
        case .html: HTMLReporter()
        case .ciSummary: CISummaryReporter()
        case .sonar: SonarReporter()
        case .githubActions: GitHubActionsReporter()
        }
    }

    /// Renders one report in every requested format, keyed by kind.
    public static func renderAll(
        _ report: RunReport,
        kinds: [ReportKind]
    ) throws -> [ReportKind: String] {
        var rendered: [ReportKind: String] = [:]
        for kind in kinds {
            rendered[kind] = try reporter(for: kind).render(report)
        }
        return rendered
    }
}

// MARK: - Fail-closed vocabulary

/// The wording every reporter uses when `RunReport.score` is nil.
///
/// A score is a claim about a test suite. When integrity failed we cannot back
/// that claim, so no format is permitted to print a number — not a score, not a
/// zero, not a dash that a spreadsheet will coerce into a zero. Every reporter
/// routes through here so the refusal reads the same everywhere and so that
/// softening it means editing one obvious place.
enum FailClosed {
    static let headline = "NO MUTATION SCORE — INTEGRITY CHECK FAILED"

    static let explanation = """
    This run broke an invariant that the score depends on, so no mutation score \
    is reported. The outcomes below are shown for diagnosis only and must not be \
    treated as a measurement of the test suite. Fix the violations and re-run.
    """
}

// MARK: - Derived views over a report

extension RunReport {
    /// Surviving mutants in reading order: a developer works through them file
    /// by file, not by hash.
    var survivors: [MutationResult] {
        results
            .filter { $0.outcome == .survived }
            .sorted {
                ($0.point.file, $0.point.line, $0.point.column, $0.id.rawValue)
                    < ($1.point.file, $1.point.line, $1.point.column, $1.id.rawValue)
            }
    }

    /// Every outcome with its count, including zeros. Reporting only the
    /// non-zero cases hides the difference between "no mutants timed out" and
    /// "we stopped tracking timeouts".
    var outcomeCounts: [(outcome: MutationOutcome, count: Int)] {
        var counts: [MutationOutcome: Int] = [:]
        for result in results {
            counts[result.outcome, default: 0] += 1
        }
        return MutationOutcome.allCases.map { ($0, counts[$0] ?? 0) }
    }

    /// Outcomes that are facts about the tool run rather than about the suite.
    /// `MutationOutcome.isScorable` is the single definition of the boundary, so
    /// a new outcome case cannot quietly leak into a denominator.
    var excludedCounts: [(outcome: MutationOutcome, count: Int)] {
        outcomeCounts.filter { !$0.outcome.isScorable && $0.count > 0 }
    }

    var excludedTotal: Int {
        excludedCounts.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Formatting

enum Format {
    /// Two decimals, never rounded up to a friendlier number.
    static func percent(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.2f%%", value * 100)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// "killed / (killed + survived) = 12/15 = 80.00%", or an explicit "n/a"
    /// when the denominator is empty — an empty denominator is missing data, not
    /// a score of zero.
    static func ratio(numerator: Int, denominator: Int, value: Double?) -> String {
        guard denominator > 0, let percent = percent(value) else {
            return "n/a (no scorable mutants)"
        }
        return "\(numerator)/\(denominator) = \(percent)"
    }
}
