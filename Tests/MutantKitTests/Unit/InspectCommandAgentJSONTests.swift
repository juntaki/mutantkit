@testable import CLI
import Foundation
import MutationModel
import Reporting
import Testing

/// P5: `mutantkit inspect --json`'s `AgentEvidenceReport` — every field must
/// be either real data already computed elsewhere, or `nil`, never
/// fabricated. See `AgentEvidenceReport`'s own doc comment for the full
/// rationale.
@Suite("InspectCommand: --json agent evidence report")
struct InspectCommandAgentJSONTests {
    private func makeDescriptor() -> OperatorDescriptor {
        OperatorDescriptor(
            id: "swift.core.bool-literal-inversion", version: 1, category: "literal",
            summary: "Replaces a boolean literal with its opposite (true ↔ false).",
            defaultEnabled: true, confidence: .high
        )
    }

    @Test("A mutant with no loaded result reports verdict nil and an explicit unavailable reason, never a guessed verdict")
    func noResultReportsNoResultYet() throws {
        let point = try makeAnchoredPoint()
        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: nil, toolchain: nil, projectRoot: FileManager.default.temporaryDirectory
        )

        #expect(report.verdict == nil)
        #expect(report.verdictUnavailableReason == "noResultYet")
        #expect(report.execution?.buildCommand == nil)
        #expect(report.execution?.testCommand == nil)
        #expect(report.tests == nil)
        #expect(report.evidence == nil)
        #expect(report.reproduceCommand == "mutantkit reproduce \(point.id)")
    }

    @Test("A survived result's own real evidence — build/test commands, activation proof, diff, test counts — passes through verbatim")
    func survivedResultPopulatesRealEvidence() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .survived, testSummary: makeTestSummary(total: 4, passed: 4, failed: 0))

        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: result, toolchain: nil, projectRoot: FileManager.default.temporaryDirectory
        )

        #expect(report.verdict == "survived")
        #expect(report.verdictUnavailableReason == nil)
        #expect(report.diagnosis == result.diagnosis)
        #expect(report.origin == "fresh")
        #expect(report.tests?.total == 4)
        #expect(report.tests?.passed == 4)
        #expect(report.tests?.caughtBy.isEmpty == true, "a survivor is never caught by anything")
        #expect(report.evidence?.kind == "isolated")
        #expect(report.evidence?.activationProven == true, "makeResult's default evidence proves activation")
        #expect(report.evidence?.diff == result.evidence?.sourceDiff)
        #expect(report.execution?.buildCommand?.first == result.evidence?.buildCommand?.executable)
    }

    @Test("A killed-by-assertion result reports the real failing test names, not an inferred kill hint")
    func killedResultReportsRealFailingTests() throws {
        let point = try makeAnchoredPoint()
        let summary = TestOutcomeSummary(total: 3, passed: 2, failed: 1, failingTests: ["ExampleTests/testIsReady"], durationSeconds: 1)
        let result = makeResult(point: point, outcome: .killedByAssertion, testSummary: summary)

        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: result, toolchain: nil, projectRoot: FileManager.default.temporaryDirectory
        )

        #expect(report.verdict == "killedByAssertion")
        #expect(report.tests?.caughtBy == ["ExampleTests/testIsReady"])
    }

    @Test("Source context is populated, real lines, only when the current file still matches the mutant's own anchored hash")
    func sourceContextPopulatedWhenFileMatches() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        struct Example {
            func isReady() -> Bool { return true }
        }
        """
        let relativePath = "Sources/Example.swift"
        try write(source, to: root.appendingPathComponent(relativePath))

        let point = try #require(try discover(source, path: relativePath, using: Operators.boolLiteral).first)

        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: nil, toolchain: nil, projectRoot: root
        )

        let context = try #require(report.source.context, "the file on disk is byte-identical to what discovery hashed")
        #expect(context.contains { $0.contains("func isReady") })
    }

    @Test("Source context is nil, not a stale or wrong-line guess, once the file on disk no longer matches the anchored hash")
    func sourceContextNilWhenFileHasChanged() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalSource = """
        struct Example {
            func isReady() -> Bool { return true }
        }
        """
        let relativePath = "Sources/Example.swift"
        let point = try #require(try discover(originalSource, path: relativePath, using: Operators.boolLiteral).first)

        // The file on disk has moved on since discovery — an inserted line
        // shifts every line number below it, the exact hazard this guard
        // exists to catch.
        try write(
            """
            // a comment added after this mutant was discovered
            struct Example {
                func isReady() -> Bool { return true }
            }
            """,
            to: root.appendingPathComponent(relativePath)
        )

        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: nil, toolchain: nil, projectRoot: root
        )

        #expect(report.source.context == nil, "a changed file must never produce a possibly-mislabeled excerpt")
    }

    @Test("Source context is nil, not a crash, when the file no longer exists at all")
    func sourceContextNilWhenFileIsMissing() throws {
        let point = try makeAnchoredPoint(file: "Sources/DoesNotExist.swift")

        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: nil, toolchain: nil, projectRoot: FileManager.default.temporaryDirectory
        )

        #expect(report.source.context == nil)
    }

    @Test("The JSON key is literally \"operator\", not the Swift property name \"mutantOperator\"")
    func jsonUsesTheOperatorKeyName() throws {
        let point = try makeAnchoredPoint()
        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: nil, toolchain: nil, projectRoot: FileManager.default.temporaryDirectory
        )

        let data = try MutationPlan.encoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["operator"] != nil, "the CodingKeys remap must actually take effect")
        #expect(json["mutantOperator"] == nil)
    }

    @Test("The guidance hint is always present and always true — a static fact, not a per-mutant inference")
    func guidanceIsAlwaysPresent() throws {
        let point = try makeAnchoredPoint()
        let report = InspectCommand.agentEvidenceReport(
            point: point, descriptor: makeDescriptor(), result: nil, toolchain: nil, projectRoot: FileManager.default.temporaryDirectory
        )

        #expect(report.guidance.testBehaviorNotMutation == true)
    }

    @Test("ErrorJSON and SkippedMutationJSON both round-trip through encode/decode")
    func errorAndSkippedJSONRoundTrip() throws {
        let error = InspectCommand.ErrorJSON(error: "No mutation mut_x in plan.json.")
        let errorData = try MutationPlan.encoder().encode(error)
        let decodedError = try MutationPlan.decoder().decode(InspectCommand.ErrorJSON.self, from: errorData)
        #expect(decodedError.error == error.error)

        let skipped = InspectCommand.SkippedMutationJSON(mutantId: "mut_x", skipped: true, reason: "budgetExceeded", detail: "not selected")
        let skippedData = try MutationPlan.encoder().encode(skipped)
        let decodedSkipped = try MutationPlan.decoder().decode(InspectCommand.SkippedMutationJSON.self, from: skippedData)
        #expect(decodedSkipped.mutantId == "mut_x")
        #expect(decodedSkipped.reason == "budgetExceeded")
    }

    // MARK: - Helpers

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inspect-json-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
