@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("ReportGenerator")
struct ReportGeneratorTests {
    private func sampleAggregate() -> AggregateBenchmarkResult {
        let mk = MutationBenchmarkMeasurement(
            runID: UUID(), tool: BenchmarkToolIdentity(name: "mutantkit", version: "0"), projectID: "p", projectCommit: "c",
            mode: .cold, toolchainProfileID: "test", discovered: 4, applied: 4, built: 4, provenActive: 4, provenExecuted: 4,
            killed: 3, survived: 1, noCoverage: 0, unviable: 0, infrastructureFailure: 0,
            phantom: 0, falseScored: 0, backendDisagreements: 0,
            wallSeconds: 12.5, peakResidentBytes: 100 * 1_048_576, workingDirectoryGrowthBytes: nil, exitCode: 0
        )
        return AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [.cold: mk], muterMeasurements: [:],
                comparison: nil, mutantKitCorrectnessPassed: true
            )
        ])
    }

    @Test("aggregate.json round-trips through JSONEncoder without error")
    func aggregateJSONEncodes() throws {
        let mk = MutationBenchmarkMeasurement(
            runID: UUID(), tool: BenchmarkToolIdentity(name: "mutantkit", version: "0"), projectID: "p", projectCommit: "c",
            mode: .cold, toolchainProfileID: "test", discovered: 1, applied: 1, built: 1, provenActive: 1, provenExecuted: 1,
            killed: 1, survived: 0, noCoverage: 0, unviable: 0, infrastructureFailure: 0,
            phantom: 0, falseScored: 0, backendDisagreements: 0,
            wallSeconds: 1.0, peakResidentBytes: nil, workingDirectoryGrowthBytes: nil, exitCode: 0
        )
        let data = try ReportGenerator.aggregateJSON([mk])
        let decoded = try JSONDecoder().decode([MutationBenchmarkMeasurement].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded[0].projectID == "p")
    }

    @Test("Markdown report mentions every project and shows each axis independently, not one combined score")
    func markdownReportMentionsProjectsAndAxes() {
        let markdown = ReportGenerator.markdownReport(sampleAggregate(), gate: [])
        #expect(markdown.contains("p"))
        #expect(markdown.contains("MutantKit"))
        #expect(markdown.contains("killed"))
        #expect(markdown.contains("survived"))
        #expect(!markdown.lowercased().contains("overall score"), "no single combined ranking score")
    }

    @Test("Markdown report surfaces gate violations when present")
    func markdownReportShowsViolations() {
        let markdown = ReportGenerator.markdownReport(sampleAggregate(), gate: [BenchmarkViolation("p: 1 phantom mutant(s)")])
        #expect(markdown.contains("1 violation"))
        #expect(markdown.contains("phantom mutant"))
    }

    @Test("HTML report embeds the markdown content, escaped")
    func htmlReportEmbedsContent() {
        let html = ReportGenerator.htmlReport(sampleAggregate(), gate: [])
        #expect(html.contains("<html>"))
        #expect(html.contains("MutantBench-Swift report"))
        #expect(html.contains("p"))
    }

    // MARK: - Two-part (current vs compatibility) report

    @Test("The two-part report keeps Part A and Part B as separate sections, never one merged conclusion")
    func twoPartReportKeepsSectionsSeparate() {
        let report = ReportGenerator.twoPartMarkdownReport(
            current: sampleAggregate(), currentGate: [], compatibility: sampleAggregate(), compatibilityGate: []
        )
        #expect(report.contains("Part A — Current Toolchain Usability"))
        #expect(report.contains("Part B — Pinned Toolchain Performance"))
        let partAIndex = report.range(of: "Part A")!.lowerBound
        let partBIndex = report.range(of: "Part B")!.lowerBound
        #expect(partAIndex < partBIndex, "Part A must be rendered before Part B")
    }

    @Test("A missing compatibility lane renders as not-available, never silently backfilled from Part A")
    func missingCompatibilityLaneIsHonest() {
        let report = ReportGenerator.twoPartMarkdownReport(
            current: sampleAggregate(), currentGate: [], compatibility: nil, compatibilityGate: []
        )
        #expect(report.contains("Not available this run"))
    }

    @Test("The two-part HTML report embeds both parts")
    func twoPartHTMLReportEmbedsBothParts() {
        let html = ReportGenerator.twoPartHTMLReport(
            current: sampleAggregate(), currentGate: [], compatibility: nil, compatibilityGate: []
        )
        #expect(html.contains("Part A"))
        #expect(html.contains("Part B"))
    }
}
