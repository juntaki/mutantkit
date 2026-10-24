@testable import CLI
import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The planner's own answer in the `execution-profile` report, which the operator-level count cannot give.
@Suite("ExecutionProfileCommand schemata planner preview")
struct ExecutionProfileSchemataPreviewTests {
    private func preview(
        total: Int, embedded: Int, chunks: Int, reasons: [String: Int] = [:], failure: String? = nil
    ) -> SchemataRunOrchestration.Preview {
        SchemataRunOrchestration.Preview(
            total: total, embedded: embedded, chunks: chunks, fallbackReasons: reasons, failure: failure
        )
    }

    @Test("It names how many mutations embed, in how many builds, and the biggest reasons for the rest")
    func rendersShareChunksAndReasons() {
        let lines = ExecutionProfileCommand.schemataPreviewLines(preview(
            total: 100, embedded: 97, chunks: 4,
            reasons: ["a": 1, "unsupportedOperand(\"subscript operand\")": 2]
        ))
        #expect(lines.first == "Schemata planner: 97/100 (97.0%) embed into 4 shared build(s); 3 would run isolated, one build each.")
        #expect(lines.dropFirst().first == "  2 × unsupportedOperand(\"subscript operand\")")
        #expect(lines.count == 3)
    }

    @Test("Only the five largest reasons are listed")
    func listsFiveReasons() {
        let reasons = Dictionary(uniqueKeysWithValues: (1 ... 8).map { ("r\($0)", $0) })
        let lines = ExecutionProfileCommand.schemataPreviewLines(preview(total: 50, embedded: 14, chunks: 1, reasons: reasons))
        #expect(lines.count == 6)
        #expect(lines.last == "  4 × r4")
    }

    @Test("A planner that could not be set up says nothing would embed, with its own reason")
    func rendersFailure() {
        let lines = ExecutionProfileCommand.schemataPreviewLines(
            preview(
                total: 10, embedded: 0, chunks: 0,
                failure: "! Schemata target resolution failed (boom); every mutation will run in isolated mode this run."
            )
        )
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("Schemata planner: nothing would embed — ! Schemata target resolution failed (boom)"))
    }

    @Test("An empty plan renders no planner line")
    func emptyPlanRendersNothing() {
        #expect(ExecutionProfileCommand.schemataPreviewLines(preview(total: 0, embedded: 0, chunks: 0)).isEmpty)
    }

    @Test("The preview line is part of the report when one is given")
    func renderIncludesPreview() {
        let characteristics = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 6, totalMutationCount: 6,
            schemataEligibleOperatorIDs: ["swift.core.bool-literal-inversion"],
            sharedModuleCacheSupported: false, perTestCoverageAdapterCapable: false
        )
        let rendered = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: ExecutionSettings(), characteristics: characteristics,
            schemataPreview: preview(total: 6, embedded: 5, chunks: 1)
        )
        #expect(rendered.contains("Schemata planner: 5/6 (83.3%) embed into 1 shared build(s)"))
    }

    // MARK: - sampling

    private func points(_ count: Int) throws -> [MutationPoint] {
        let source = (0 ..< count).map { "let flag\($0) = true" }.joined(separator: "\n")
        return try discover(source, path: "Sources/Flags.swift", using: Operators.boolLiteral)
    }

    @Test("A plan within the limit is planned whole")
    func smallPlanIsNotSampled() throws {
        let all = try points(12)
        #expect(SchemataRunOrchestration.evenlySpaced(all, limit: 12).map(\.id) == all.map(\.id))
        #expect(SchemataRunOrchestration.evenlySpaced(all, limit: 500).map(\.id) == all.map(\.id))
    }

    @Test("A larger plan is cut to the limit at an even stride, the same way every time")
    func largePlanIsSampledDeterministically() throws {
        let all = try points(40)
        let first = SchemataRunOrchestration.evenlySpaced(all, limit: 8)
        #expect(first.count == 8)
        #expect(first.map(\.id) == (0 ..< 8).map { all[$0 * 5].id })
        #expect(first.map(\.id) == SchemataRunOrchestration.evenlySpaced(all, limit: 8).map(\.id))
        #expect(Set(first.map(\.id)).count == 8)
    }

    @Test("A sampled report says so, and calls its shares estimates")
    func sampledReportIsLabelled() {
        let lines = ExecutionProfileCommand.schemataPreviewLines(
            SchemataRunOrchestration.Preview(
                total: 4000, sampled: 500, embedded: 485, chunks: 6, fallbackReasons: ["a": 15], failure: nil
            )
        )
        #expect(lines[0].hasPrefix(
            "Schemata planner (sample of 500 of 4000 mutations; the shares are estimates): 485/500 (97.0%) "
                + "embed (the sample alone needs 6 shared build(s))"
        ))
    }

    @Test("A whole-plan report keeps the plain label")
    func wholePlanReportIsNotLabelledSample() {
        let lines = ExecutionProfileCommand.schemataPreviewLines(
            SchemataRunOrchestration.Preview(total: 400, embedded: 380, chunks: 3, fallbackReasons: [:], failure: nil)
        )
        #expect(lines[0].hasPrefix("Schemata planner: 380/400 (95.0%)"))
    }

    @Test("A planner that timed out on a sample says which sample")
    func timeoutNamesTheSample() {
        let lines = ExecutionProfileCommand.schemataPreviewLines(
            SchemataRunOrchestration.Preview(
                total: 4000, sampled: 500, embedded: 0, chunks: 0, fallbackReasons: [:],
                failure: "planning 500 mutation(s) did not finish within 60 s"
            )
        )
        #expect(lines == [
            "Schemata planner (sample of 500 of 4000 mutations): nothing would embed — "
                + "planning 500 mutation(s) did not finish within 60 s"
        ])
    }
}
