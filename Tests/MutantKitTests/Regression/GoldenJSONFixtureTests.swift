@testable import CLI
import Foundation
import MutationExecution
@testable import MutationModel
import Reporting
import Testing

/// v0.5 Stable Contracts, Agent B audit: "add one golden-fixture test per
/// [machine-readable `--json`/artifact] format ... the single highest-
/// leverage remaining fix; today a field rename/drop can pass the full
/// suite as long as the specific fields each existing test happens to
/// assert on are untouched."
///
/// Every existing test that touches these types asserts on a handful of
/// fields it cares about — that a score computed correctly, that a
/// violation fired, that a command printed the right exit code. None of
/// them notice a field silently renamed, dropped, or retyped elsewhere in
/// the same document, because none of them look at the whole document.
/// This suite does exactly that, for every format this tool emits as
/// `--json`/writes as an artifact: a small, hand-reviewed, checked-in
/// example of real output (`Tests/MutantKitTests/Fixtures/GoldenJSON/
/// *.json`) is decoded into the real production type (proving the type
/// still accepts historical shape) and then re-encoded through this
/// project's one canonical encoder, `MutationPlan.encoder()` (see
/// `JSONOutput.swift`'s own doc comment — every `--json` command and every
/// on-disk artifact this tool writes goes through that same encoder), with
/// the result compared byte-for-byte against the fixture (proving nothing
/// vanished, was renamed, or changed shape on the encode side either).
///
/// Each fixture is the smallest real, deterministic example that shape can
/// have — one mutation, one operator, one history record — built from this
/// tool's own real construction paths (`MutationResult.projected`,
/// `RunHistoryRecord.init(report:)`, `IntegrityChecker.check`, ...), not
/// hand-typed JSON that merely looks plausible. `history-record.json` and
/// `operator-catalog.json` are bare top-level JSON arrays, matching what
/// `mutantkit history --json`/`mutantkit operator-catalog --json` actually
/// emit — the one intentional exception to every other format's top-level
/// object shape (tracked as a documentation gap in AUDIT-FINDINGS.md, not
/// fixed here).
@Suite("Regression: golden-fixture JSON round-trips for every machine-readable output format")
struct GoldenJSONFixtureTests {
    // MARK: - Fixture I/O

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .appendingPathComponent("Fixtures/GoldenJSON")
    }

    private static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDirectory.appendingPathComponent("\(name).json"))
    }

    // MARK: - plan.json (MutationPlan)

    @Test("plan.json decodes into MutationPlan and re-encodes byte-identically")
    func planRoundTrips() throws {
        let data = try Self.fixtureData("plan")
        let plan = try MutationPlan.decode(from: data)

        #expect(plan.planID == "plan-0001")
        #expect(plan.mutations.count == 1)
        #expect(plan.operators.count == 1)
        #expect(plan.mutations[0].operatorID == "swift.core.bool-literal-inversion")

        let reencoded = try plan.encoded()
        #expect(reencoded == data)
    }

    // MARK: - report.json (RunReport, `run --report json`)

    @Test("report.json decodes into RunReport and re-encodes byte-identically")
    func reportRoundTrips() throws {
        let data = try Self.fixtureData("report")
        let report = try RunReport.decode(from: data)

        #expect(report.planID == "plan-0001")
        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .survived)
        #expect(report.score?.survived == 1)
        #expect(report.integrity.passed)

        let reencoded = try report.encoded()
        #expect(reencoded == data)
    }

    // MARK: - gate.json (QualityGateResult, `gate --json`)

    @Test("gate.json decodes into QualityGateResult and re-encodes byte-identically")
    func gateRoundTrips() throws {
        let data = try Self.fixtureData("gate")
        let result = try MutationPlan.decoder().decode(QualityGateResult.self, from: data)

        #expect(result.schemaVersion == SchemaVersion.qualityGateResult)
        #expect(result.passed == false)
        #expect(result.violations == [QualityGateViolation(kind: .survivorCount, detail: "1 mutant survived (maximum 0).")])

        let reencoded = try MutationPlan.encoder().encode(result)
        #expect(reencoded == data)
    }

    // MARK: - doctor.json (BuildDiagnosis, `doctor --json`)

    @Test("doctor.json decodes into BuildDiagnosis and re-encodes byte-identically")
    func doctorRoundTrips() throws {
        let data = try Self.fixtureData("doctor")
        let diagnosis = try MutationPlan.decoder().decode(BuildDiagnosis.self, from: data)

        #expect(diagnosis.schemaVersion == SchemaVersion.buildDiagnosis)
        #expect(diagnosis.canProceed)
        #expect(diagnosis.items.count == 1)
        #expect(diagnosis.items[0].code == .swiftToolchain)
        #expect(diagnosis.items[0].status == .ok)

        let reencoded = try MutationPlan.encoder().encode(diagnosis)
        #expect(reencoded == data)
    }

    // MARK: - history-record.json (RunHistoryRecord, `history --json` — bare array)

    @Test("history-record.json decodes into [RunHistoryRecord] (a bare array) and re-encodes byte-identically")
    func historyRecordRoundTrips() throws {
        let data = try Self.fixtureData("history-record")
        let records = try MutationPlan.decoder().decode([RunHistoryRecord].self, from: data)

        #expect(records.count == 1)
        #expect(records[0].schemaVersion == SchemaVersion.runHistoryRecord)
        #expect(records[0].planID == "plan-0001")
        #expect(records[0].integrityPassed)
        #expect(records[0].survived == 1)

        let reencoded = try MutationPlan.encoder().encode(records)
        #expect(reencoded == data)

        // The audit's flagged inconsistency: unlike every object-shaped
        // format above, this one's top level is a bare JSON array, not an
        // object carrying its own document-level `schemaVersion`.
        let topLevel = try JSONSerialization.jsonObject(with: data)
        #expect(topLevel is [Any])
    }

    // MARK: - inspect.json (AgentEvidenceReport, `inspect --json`)

    @Test("inspect.json decodes into AgentEvidenceReport and re-encodes byte-identically")
    func inspectRoundTrips() throws {
        let data = try Self.fixtureData("inspect")
        let report = try MutationPlan.decoder().decode(AgentEvidenceReport.self, from: data)

        #expect(report.schemaVersion == SchemaVersion.agentEvidenceReport)
        #expect(report.mutantId == "mut_bd2e0bb20e590e7f")
        #expect(report.mutantOperator.id == "swift.core.bool-literal-inversion")
        #expect(report.verdict == "survived")
        #expect(report.guidance.testBehaviorNotMutation)

        let reencoded = try MutationPlan.encoder().encode(report)
        #expect(reencoded == data)
    }

    // MARK: - operator-catalog.json (OperatorCatalogEntry, `operator-catalog --json` — bare array)

    @Test("operator-catalog.json decodes into [OperatorCatalogEntry] (a bare array) and re-encodes byte-identically")
    func operatorCatalogRoundTrips() throws {
        let data = try Self.fixtureData("operator-catalog")
        let entries = try MutationPlan.decoder().decode([OperatorCatalogEntry].self, from: data)

        #expect(entries.count == 1)
        #expect(entries[0].schemaVersion == SchemaVersion.operatorCatalogEntry)
        #expect(entries[0].id == "swift.core.bool-literal-inversion")
        #expect(entries[0].reachableProfile == .conservative)

        let reencoded = try MutationPlan.encoder().encode(entries)
        #expect(reencoded == data)

        // The audit's flagged inconsistency, same as `history-record.json`.
        let topLevel = try JSONSerialization.jsonObject(with: data)
        #expect(topLevel is [Any])
    }
}
