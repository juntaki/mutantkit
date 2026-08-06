import Foundation
import MutationModel
import Testing

/// `MutationResult.buildDurationSeconds`/`testDurationSeconds`/
/// `confirmationDurationSeconds`, `BaselineRecord.buildDurationSeconds`/
/// `testDurationSeconds`/`profilingDurationSeconds`, and
/// `RunReport.batchExecution` all postdate the shape these types used to
/// have. The contract that matters for an on-disk checkpoint or archived
/// report is: a value written by this build round-trips, and a value written
/// by an older build — with no key for any of these fields at all — decodes
/// without throwing, yielding `nil` rather than a fabricated default.
@Suite("Timing instrumentation Codable")
struct TimingInstrumentationCodableTests {
    // MARK: - MutationResult

    @Test("MutationResult round-trips its new timing fields")
    func mutationResultRoundTrip() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(
            point: point,
            outcome: .killedByAssertion,
            durationSeconds: 5,
            buildDurationSeconds: 1.5,
            testDurationSeconds: 2.5,
            confirmationDurationSeconds: 0.75
        )

        let data = try MutationPlan.encoder().encode(result)
        let decoded = try MutationPlan.decoder().decode(MutationResult.self, from: data)

        #expect(decoded.buildDurationSeconds == 1.5)
        #expect(decoded.testDurationSeconds == 2.5)
        #expect(decoded.confirmationDurationSeconds == 0.75)
    }

    @Test("MutationResult decodes JSON missing the new timing keys as nil, without throwing")
    func mutationResultBackwardCompatible() throws {
        let point = try makeAnchoredPoint()
        // Written with every new field populated, so removing the keys below
        // is a deliberate simulation of an older file — not just "these
        // happened to be nil already".
        let result = makeResult(
            point: point,
            outcome: .survived,
            evidence: nil,
            testSummary: nil,
            durationSeconds: 1,
            buildDurationSeconds: 1,
            testDurationSeconds: 1,
            confirmationDurationSeconds: 1
        )

        let data = try MutationPlan.encoder().encode(result)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "buildDurationSeconds")
        object.removeValue(forKey: "testDurationSeconds")
        object.removeValue(forKey: "confirmationDurationSeconds")
        let oldStyleData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try MutationPlan.decoder().decode(MutationResult.self, from: oldStyleData)

        #expect(decoded.buildDurationSeconds == nil)
        #expect(decoded.testDurationSeconds == nil)
        #expect(decoded.confirmationDurationSeconds == nil)
        // The rest of the record still reads back correctly — this isn't
        // just swallowing a decode failure.
        #expect(decoded.outcome == .survived)
        #expect(decoded.durationSeconds == 1)
    }

    // MARK: - BaselineRecord

    @Test("BaselineRecord round-trips its new timing fields")
    func baselineRecordRoundTrip() throws {
        let record = BaselineRecord(
            passed: true,
            testSummary: makeTestSummary(),
            durationSeconds: 20,
            buildProductHash: "hash",
            buildCommand: nil,
            testCommand: nil,
            buildDurationSeconds: 8,
            testDurationSeconds: 12,
            profilingDurationSeconds: 3.5
        )

        let data = try MutationPlan.encoder().encode(record)
        let decoded = try MutationPlan.decoder().decode(BaselineRecord.self, from: data)

        #expect(decoded.buildDurationSeconds == 8)
        #expect(decoded.testDurationSeconds == 12)
        #expect(decoded.profilingDurationSeconds == 3.5)
    }

    @Test("BaselineRecord decodes JSON missing the new timing keys as nil, without throwing")
    func baselineRecordBackwardCompatible() throws {
        let record = BaselineRecord(
            passed: true,
            testSummary: nil,
            durationSeconds: 20,
            buildProductHash: nil,
            buildCommand: nil,
            testCommand: nil,
            buildDurationSeconds: 8,
            testDurationSeconds: 12,
            profilingDurationSeconds: 3.5
        )

        let data = try MutationPlan.encoder().encode(record)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "buildDurationSeconds")
        object.removeValue(forKey: "testDurationSeconds")
        object.removeValue(forKey: "profilingDurationSeconds")
        let oldStyleData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try MutationPlan.decoder().decode(BaselineRecord.self, from: oldStyleData)

        #expect(decoded.buildDurationSeconds == nil)
        #expect(decoded.testDurationSeconds == nil)
        #expect(decoded.profilingDurationSeconds == nil)
        #expect(decoded.passed == true)
        #expect(decoded.durationSeconds == 20)
    }

    // MARK: - RunReport.batchExecution

    private func makeMinimalReport(batchExecution: BatchExecutionSummary?) throws -> RunReport {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let result = makeResult(point: point, outcome: .survived)

        return RunReport(
            planID: plan.planID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_100),
            projectRoot: plan.projectRoot,
            toolchain: makeToolchain(),
            baseline: makeBaseline(),
            ledger: makeLedger([result]),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger([result]), baselinePassed: true),
            batchExecution: batchExecution
        )
    }

    @Test("RunReport round-trips a non-nil batchExecution summary")
    func runReportRoundTripsBatchExecution() throws {
        let summary = BatchExecutionSummary(batchCount: 3, totalConfigurations: 5)
        let report = try makeMinimalReport(batchExecution: summary)

        let data = try MutationPlan.encoder().encode(report)
        let decoded = try MutationPlan.decoder().decode(RunReport.self, from: data)

        let decodedSummary = try #require(decoded.batchExecution)
        #expect(decodedSummary.batchCount == 3)
        #expect(decodedSummary.totalConfigurations == 5)
        #expect(decodedSummary.averageConfigurationsPerBatch == 5.0 / 3.0)
    }

    @Test("RunReport decodes JSON missing batchExecution as nil, without throwing")
    func runReportBackwardCompatible() throws {
        let report = try makeMinimalReport(batchExecution: BatchExecutionSummary(batchCount: 1, totalConfigurations: 1))

        let data = try MutationPlan.encoder().encode(report)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "batchExecution")
        let oldStyleData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try MutationPlan.decoder().decode(RunReport.self, from: oldStyleData)

        #expect(decoded.batchExecution == nil)
        #expect(decoded.planID == report.planID)
    }

    @Test("RunReport's batchExecution is nil when never set")
    func runReportBatchExecutionDefaultsNil() throws {
        let report = try makeMinimalReport(batchExecution: nil)
        #expect(report.batchExecution == nil)
    }
}
