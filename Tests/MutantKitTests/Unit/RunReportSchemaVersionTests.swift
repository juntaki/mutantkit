import Foundation
@testable import MutationModel
import Testing

/// v0.5 Stable Contracts: `MutationPlan.decode(from:)` already refused an
/// unrecognized `schemaVersion` (`MutationPlanTests
/// .unsupportedSchemaVersionIsRejected`); `RunReport` carries the identical
/// `schemaVersion` field but, until `RunReport.decode(from:)` was added,
/// nothing checked it — every caller (`gate`, `trust`, `next`, `fix-plan`,
/// `survivors`, `perf`, `inspect`) decoded a `report.json` directly and
/// trusted it regardless of its declared schema version. Pins the same
/// fail-closed discipline for the other artifact type.
@Suite("RunReport schema version")
struct RunReportSchemaVersionTests {
    @Test("A report at the current schema version decodes")
    func currentSchemaVersionDecodes() throws {
        let point = try makeAnchoredPoint()
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .survived)])
        let decoded = try RunReport.decode(from: report.encoded())
        #expect(decoded.planID == report.planID)
    }

    /// A reader that does not recognise a report's schema version must
    /// refuse it rather than guess at its shape — the same property
    /// `MutationPlan.decode` already pins.
    @Test("An unsupported schema version is rejected")
    func unsupportedSchemaVersionIsRejected() throws {
        let point = try makeAnchoredPoint()
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .survived)])
        var object = try #require(
            try JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any]
        )
        object["schemaVersion"] = SchemaVersion.result + 1
        let future = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ReportError.self) {
            try RunReport.decode(from: future)
        }

        do {
            _ = try RunReport.decode(from: future)
            Issue.record("expected the report to be refused")
        } catch let error as ReportError {
            guard case let .unsupportedSchemaVersion(found, expected) = error else {
                Issue.record("expected an unsupportedSchemaVersion error, got \(error)")
                return
            }
            #expect(found == SchemaVersion.result + 1)
            #expect(expected == SchemaVersion.result)
        }
    }
}
