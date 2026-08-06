import Foundation
import MutationModel
import Reporting
import Testing

/// `ResultOrigin` replaces the old `wasResumedFromCheckpoint` boolean so a
/// checkpoint resume and a cross-run cache hit are no longer recorded as the
/// same thing. These tests pin: the field round-trips, old JSON still decodes,
/// the two marking methods produce the right origin, and `PerformanceSummary`
/// counts them separately.
@Suite("Result origin")
struct ResultOriginTests {
    @Test("markedAsCheckpointResume and markedAsCrossRunCacheHit set the right origin")
    func markingSetsOrigin() throws {
        let result = makeResult(point: try makeAnchoredPoint(), outcome: .survived)

        #expect(result.origin == .fresh)
        #expect(result.markedAsCheckpointResume().origin == .checkpoint)
        #expect(result.markedAsCrossRunCacheHit().origin == .crossRunCache)

        // Marking is non-mutating: the original stays fresh.
        #expect(result.origin == .fresh)
    }

    @Test("origin round-trips through JSON")
    func originRoundTrips() throws {
        let point = try makeAnchoredPoint()
        let checkpoint = makeResult(point: point, outcome: .survived).markedAsCheckpointResume()
        let cached = makeResult(point: point, outcome: .survived).markedAsCrossRunCacheHit()

        let decodedCheckpoint = try MutationPlan.decoder().decode(
            MutationResult.self, from: try MutationPlan.encoder().encode(checkpoint)
        )
        let decodedCached = try MutationPlan.decoder().decode(
            MutationResult.self, from: try MutationPlan.encoder().encode(cached)
        )

        #expect(decodedCheckpoint.origin == .checkpoint)
        #expect(decodedCached.origin == .crossRunCache)
    }

    @Test("A record without an origin key decodes as fresh, without throwing")
    func missingOriginDecodesFresh() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .survived)

        var object = try #require(
            try JSONSerialization.jsonObject(with: try MutationPlan.encoder().encode(result)) as? [String: Any]
        )
        object.removeValue(forKey: "origin")
        // Also no legacy boolean — a brand-new field absent from a brand-new
        // record that simply never wrote it.
        let decoded = try MutationPlan.decoder().decode(
            MutationResult.self, from: try JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.origin == .fresh)
        #expect(decoded.outcome == .survived)
    }

    @Test("A legacy wasResumedFromCheckpoint=true maps to checkpoint; false/absent to fresh")
    func legacyBooleanMapsToOrigin() throws {
        let point = try makeAnchoredPoint()
        let base = makeResult(point: point, outcome: .survived)
        let encoded = try MutationPlan.encoder().encode(base)

        func decodeLegacy(_ value: Any?) throws -> MutationResult {
            var object = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object.removeValue(forKey: "origin")
            if let value { object["wasResumedFromCheckpoint"] = value }
            return try MutationPlan.decoder().decode(
                MutationResult.self, from: try JSONSerialization.data(withJSONObject: object)
            )
        }

        #expect(try decodeLegacy(true).origin == .checkpoint)
        #expect(try decodeLegacy(false).origin == .fresh)
        #expect(try decodeLegacy(nil).origin == .fresh)
    }

    @Test("PerformanceSummary counts checkpoint resumes and cache reuses separately")
    func performanceSummarySeparatesOrigins() throws {
        // Three distinct mutations, one per origin — a real report never
        // carries the same mutation more than once (`ResultLedger.insert`
        // refuses a duplicate `PlannedMutationRef` now — ADR-0006 Stage 1),
        // so `markedAsCheckpointResume`/`markedAsCrossRunCacheHit` are
        // applied to their own separate fixtures, not restamped copies of
        // one shared result.
        let freshPoint = try makeAnchoredPoint(file: "Sources/Fresh.swift")
        let resumedPoint = try makeAnchoredPoint(file: "Sources/Resumed.swift")
        let cachedPoint = try makeAnchoredPoint(file: "Sources/Cached.swift")
        let plan = makePlan(mutations: [freshPoint, resumedPoint, cachedPoint])

        let fresh = makeResult(point: freshPoint, outcome: .survived)
        let resumed = makeResult(point: resumedPoint, outcome: .survived).markedAsCheckpointResume()
        let cached = makeResult(point: cachedPoint, outcome: .survived).markedAsCrossRunCacheHit()

        let report = RunReport(
            planID: plan.planID,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            projectRoot: plan.projectRoot,
            toolchain: makeToolchain(),
            baseline: makeBaseline(),
            ledger: makeLedger([fresh, resumed, cached]),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger([fresh, resumed, cached]), baselinePassed: true)
        )

        let summary = PerformanceSummary(report: report)

        #expect(summary.resumedMutants == 1)
        #expect(summary.cachedMutants == 1)
    }
}
