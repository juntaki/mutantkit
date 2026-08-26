import Foundation

/// Renders `AggregateBenchmarkResult` to the three artifacts `Benchmarks/results`
/// keeps: raw per-run JSON (written by the orchestrator directly, not by
/// this type), `aggregate.json`, `report.md`, `report.html`. Every axis is
/// shown independently — never collapsed into one ranking score, per the
/// benchmark's own stated purpose.
public enum ReportGenerator {
    public static func aggregateJSON(_ measurements: [MutationBenchmarkMeasurement]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(measurements)
    }

    public static func markdownReport(_ aggregate: AggregateBenchmarkResult, gate: [BenchmarkViolation]) -> String {
        var lines: [String] = []
        lines.append("# MutantBench-Swift report")
        lines.append("")
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date())). \(aggregate.projects.count) project(s).")
        lines.append("")

        lines.append("## Correctness gate")
        lines.append("")
        if gate.isEmpty {
            lines.append(
                "All correctness gates passed (0 phantoms, 0 false-scored, 0 backend disagreements, compile rate above threshold)."
            )
        } else {
            lines.append("**\(gate.count) violation(s):**")
            for violation in gate { lines.append("- \(violation.description)") }
        }
        lines.append("")

        for project in aggregate.projects {
            lines.append("## \(project.projectID)")
            lines.append("")
            lines.append("MutantKit correctness: \(project.mutantKitCorrectnessPassed ? "passed" : "**FAILED**")")
            lines.append("")
            lines.append(measurementsTable(project.mutantKitMeasurements, toolLabel: "MutantKit"))
            lines.append("")
            lines.append(measurementsTable(project.muterMeasurements, toolLabel: "Muter"))
            lines.append("")
            lines.append(comparisonSection(
                title: "Cross-tool mutant comparison (vs. Muter)", comparison: project.comparison,
                otherOnlyLabel: "Muter-only"
            ))
            lines.append("")
            // Phase C13: `ericodx/swift-mutation-testing` — only rendered
            // when it actually ran for this project, so a report from a
            // sweep that never configured this optional third tool looks
            // exactly as it did before this section existed.
            if !project.swiftMutationTestingMeasurements.isEmpty {
                lines.append(measurementsTable(project.swiftMutationTestingMeasurements, toolLabel: "swift-mutation-testing"))
                lines.append("")
                lines.append(comparisonSection(
                    title: "Cross-tool mutant comparison (vs. swift-mutation-testing)",
                    comparison: project.comparisonWithSwiftMutationTesting, otherOnlyLabel: "swift-mutation-testing-only"
                ))
                lines.append("")
            }
        }

        lines.append("## Known limitations")
        lines.append("")
        lines.append("- Neither Muter nor swift-mutation-testing has an equivalent of `provenActive`/`provenExecuted` —")
        lines.append("  reported as `nil` (not observable), never `0`.")
        lines.append("- Cross-tool mutant matching relies on relative file path + line + column + a coarse operator")
        lines.append("  family (Phase C13) — not original/replacement text hashes, since a real Muter report never")
        lines.append("  carries the mutated text at all (see `CrossToolMutationIdentity`'s own doc comment).")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Factored out of `markdownReport` (Phase C13) so the same rendering
    /// serves both the Muter comparison (always shown) and the optional
    /// swift-mutation-testing one (shown only when that tool actually ran)
    /// identically — one comparison section was never meant to look
    /// structurally different from another just because of which second
    /// tool it is against.
    private static func comparisonSection(title: String, comparison: CrossToolComparison?, otherOnlyLabel: String) -> String {
        var lines: [String] = []
        lines.append("### \(title)")
        lines.append("")
        if let comparison {
            lines.append("- exactly comparable: \(comparison.exactlyComparable.count)")
            lines.append("- approximately comparable: \(comparison.approximatelyComparable.count)")
            lines.append("- MutantKit-only: \(comparison.mutantKitOnly.count)")
            lines.append("- \(otherOnlyLabel): \(comparison.muterOnly.count)")
        } else {
            lines.append("Not available (one or both tools produced no usable report for this project).")
        }
        return lines.joined(separator: "\n")
    }

    private static func measurementsTable(_ byMode: [BenchmarkMode: MutationBenchmarkMeasurement], toolLabel: String) -> String {
        var lines: [String] = []
        lines.append("### \(toolLabel)")
        lines.append("")
        lines.append("| mode | discovered | killed | survived | noCoverage | unviable | infra failure | wall (s) | peak RSS |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for mode in BenchmarkMode.allCases {
            guard let measurement = byMode[mode] else {
                lines.append("| \(mode.rawValue) | — | — | — | — | — | — | — | — |")
                continue
            }
            let rss = measurement.peakResidentBytes.map { "\($0 / 1_048_576) MiB" } ?? "n/a"
            lines.append(
                "| \(mode.rawValue) | \(measurement.discovered) | \(measurement.killed) | \(measurement.survived) | "
                    + "\(measurement.noCoverage) | \(measurement.unviable) | \(measurement.infrastructureFailure) | "
                    + "\(String(format: "%.1f", measurement.wallSeconds)) | \(rss) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// The report's own two-lane discipline (per `BenchmarkOrchestrator`'s
    /// own doc comment): Part A (current-toolchain usability — install/
    /// build/run success, zero-config success, failure classification) and
    /// Part B (pinned-toolchain performance — cold/warm/incremental,
    /// resources, mutation comparability) are rendered as two clearly
    /// separated sections, never merged into one conclusion. A Part B
    /// section is only ever rendered from a `compatibility`-lane aggregate;
    /// a `nil` `compatibility` here means the lane never ran (e.g.
    /// `blockedMissingToolchain`), rendered honestly as "not available,"
    /// never silently backfilled from Part A's own numbers.
    public static func twoPartMarkdownReport(
        current: AggregateBenchmarkResult, currentGate: [BenchmarkViolation],
        compatibility: AggregateBenchmarkResult?, compatibilityGate: [BenchmarkViolation]
    ) -> String {
        var lines: [String] = []
        lines.append("# MutantBench-Swift report")
        lines.append("")
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date())).")
        lines.append("")
        lines.append("## Part A — Current Toolchain Usability")
        lines.append("")
        lines.append(markdownReport(current, gate: currentGate))
        lines.append("## Part B — Pinned Toolchain Performance")
        lines.append("")
        if let compatibility {
            lines.append(markdownReport(compatibility, gate: compatibilityGate))
        } else {
            lines.append("Not available this run — no compatible pinned toolchain was found or exercised.")
            lines.append("")
        }
        lines.append("## Conclusions kept separate, on purpose")
        lines.append("")
        lines.append("Part A and Part B never combine into one statement. A tool failing to compile under Part A's")
        lines.append("current toolchain is a usability finding, never itself evidence about Part B's performance —")
        lines.append("those numbers exist only when both tools actually completed a run under the same pinned toolchain.")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func twoPartHTMLReport(
        current: AggregateBenchmarkResult, currentGate: [BenchmarkViolation],
        compatibility: AggregateBenchmarkResult?, compatibilityGate: [BenchmarkViolation]
    ) -> String {
        let markdown = twoPartMarkdownReport(
            current: current, currentGate: currentGate, compatibility: compatibility, compatibilityGate: compatibilityGate
        )
        return htmlWrapping(markdown)
    }

    public static func htmlReport(_ aggregate: AggregateBenchmarkResult, gate: [BenchmarkViolation]) -> String {
        htmlWrapping(markdownReport(aggregate, gate: gate))
    }

    private static func htmlWrapping(_ markdown: String) -> String {
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>MutantBench-Swift report</title>
        <style>
        body { font-family: -apple-system, sans-serif; max-width: 960px; margin: 2rem auto; padding: 0 1rem; }
        pre { white-space: pre-wrap; }
        </style>
        </head>
        <body>
        <pre>\(escaped)</pre>
        </body>
        </html>
        """
    }
}
