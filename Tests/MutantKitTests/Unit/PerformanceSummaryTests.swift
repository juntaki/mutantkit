import Foundation
import MutationModel
import Reporting
import Testing

/// `PerformanceSummary`'s central job is answering "where did the time go"
/// without lying about it. The one subtle way to lie by accident is summing
/// `MutationResult.testDurationSeconds` naively: every mutant that shared a
/// batch's `xcodebuild` invocation records that batch's *whole* duration, so
/// a plain sum multiplies one real measurement by however many mutants
/// happened to share it. These tests pin down the corrected aggregation —
/// see `PerformanceSummary`'s doc comment for the reasoning — plus the
/// baseline/build/confirmation breakdown and the "other" bucket it enables.
@Suite("Performance summary aggregation")
struct PerformanceSummaryTests {
    // MARK: - Batched test-time de-duplication

    /// The core regression this feature exists to prevent: N mutants sharing
    /// one batch's `testDurationSeconds` must contribute that ONE duration to
    /// the total, not N copies of it.
    @Test("A batch shared by several mutants is counted once, not once per mutant")
    func batchedDurationIsNotMultiplied() throws {
        let points = try (0 ..< 4).map { try makeAnchoredPoint(file: "Sources/Batch\($0).swift") }
        let plan = makePlan(mutations: points)

        // All four mutants tested together in one real ~60s batch invocation:
        // every one of them records 60.0, since that is genuinely what
        // `MutationResult.testDurationSeconds` means for a batched mutant.
        let results = points.map { point in
            makeResult(
                point: point, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
                diagnosis: "batched", durationSeconds: 60, buildDurationSeconds: 3, testDurationSeconds: 60
            )
        }
        let batchExecution = BatchExecutionSummary(batchCount: 1, totalConfigurations: 4, batchDurations: [60])
        let report = RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: makeBaseline(), ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true),
            batchExecution: batchExecution
        )

        let summary = PerformanceSummary(report: report)

        // A naive per-mutant sum would read 240 (4 x 60). The real total is
        // one batch invocation's worth of wall clock: 60.
        #expect(summary.mutantTestSeconds == 60)
        // Build time IS genuinely per-mutant even under batching, so this one
        // sums normally: 4 x 3 = 12.
        #expect(summary.mutantBuildSeconds == 12)
        #expect(summary.batchCount == 1)
        #expect(summary.totalConfigurations == 4)
    }

    /// Without any batching, each mutant's `testDurationSeconds` is already
    /// its own real, unshared measurement, so summing them directly is exact
    /// — this pins that the corrected logic doesn't also break the ordinary
    /// unbatched case.
    @Test("With no batching, test durations sum normally per mutant")
    func unbatchedDurationsSumDirectly() throws {
        let points = try (0 ..< 3).map { try makeAnchoredPoint(file: "Sources/Solo\($0).swift") }
        let plan = makePlan(mutations: points)
        let results = zip(points, [10.0, 20.0, 30.0]).map { point, testDuration in
            makeResult(
                point: point, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
                diagnosis: "solo", durationSeconds: testDuration, buildDurationSeconds: 2, testDurationSeconds: testDuration
            )
        }
        let report = makeReport(plan: plan, results: results)

        let summary = PerformanceSummary(report: report)

        #expect(summary.mutantTestSeconds == 60) // 10 + 20 + 30
        #expect(summary.mutantBuildSeconds == 6) // 2 x 3
        #expect(summary.batchCount == nil)
    }

    /// Found by an independent codex review: a report from before
    /// `batchDurations` existed decodes with an empty array even though
    /// `batchExecution.batchCount` is nonzero (a real batch ran). The old
    /// logic read "no batch durations recorded" as "no batch ran at all" and
    /// fell back to summing the still-duplicated per-mutant values —
    /// silently reintroducing the exact over-count this feature exists to
    /// prevent. `mutantTestSeconds` must report unavailable instead.
    @Test("A batch that ran but recorded no per-batch durations reports test time as unavailable, not duplicated")
    func batchWithoutRecordedDurationsIsUnavailable() throws {
        let points = try (0 ..< 4).map { try makeAnchoredPoint(file: "Sources/Legacy\($0).swift") }
        let plan = makePlan(mutations: points)
        let results = points.map { point in
            makeResult(
                point: point, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
                diagnosis: "batched", durationSeconds: 60, buildDurationSeconds: 3, testDurationSeconds: 60
            )
        }
        // batchCount > 0 (a real batch ran) but batchDurations is empty —
        // exactly what decoding a pre-batchDurations archived report produces.
        let batchExecution = BatchExecutionSummary(batchCount: 1, totalConfigurations: 4, batchDurations: [])
        let report = RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: makeBaseline(), ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true),
            batchExecution: batchExecution
        )

        let summary = PerformanceSummary(report: report)

        #expect(summary.mutantTestSeconds == nil, "the per-mutant values are duplicates of an unrecoverable batch total")
        #expect(summary.otherSeconds == nil, "accounting is incomplete, not merely small, when test time is unavailable")
    }

    // MARK: - Concurrent workers

    /// Found by the same independent review: with `workers > 1`, several
    /// mutants build (and occasionally confirm) concurrently, so their
    /// individual durations genuinely overlap in wall time and can legitimately
    /// sum to more than the run's total elapsed time. A raw subtraction would
    /// go negative, which contradicts what "unaccounted time remaining" means.
    @Test("Overlapping concurrent phase durations clamp otherSeconds to zero, never negative")
    func overlappingConcurrentDurationsClampToZero() throws {
        let points = try (0 ..< 3).map { try makeAnchoredPoint(file: "Sources/Concurrent\($0).swift") }
        let plan = makePlan(mutations: points)
        // Three mutants built concurrently, 40s of build time each — 120s
        // summed, even though the whole run's wall clock is only 50s, because
        // all three genuinely overlapped on different workers.
        let results = points.map { point in
            makeResult(
                point: point, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
                diagnosis: "concurrent", durationSeconds: 40, buildDurationSeconds: 40, testDurationSeconds: 5
            )
        }
        let report = RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 50), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: makeBaseline(), ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)
        )

        let summary = PerformanceSummary(report: report)

        let other = try #require(summary.otherSeconds)
        #expect(other == 0, "the accounted sum exceeds wall clock via legitimate overlap, not an error")
    }

    // MARK: - Mixed origins

    /// A checkpoint-resumed or cross-run-cache-hit mutant did no building or
    /// testing in *this* run — its stage timings are historical, possibly
    /// from a different batch shape entirely. They must not be folded into
    /// this run's phase totals, only into the existing resumed/cached counts.
    @Test("Resumed and cached mutants contribute to counts, not to phase-time sums")
    func resumedAndCachedMutantsAreExcludedFromPhaseSums() throws {
        let batchedPoints = try (0 ..< 2).map { try makeAnchoredPoint(file: "Sources/Mix\($0).swift") }
        let plan = makePlan(mutations: batchedPoints + [
            try makeAnchoredPoint(file: "Sources/MixResumed.swift"),
            try makeAnchoredPoint(file: "Sources/MixCached.swift")
        ])

        let freshBatched = batchedPoints.map { point in
            makeResult(
                point: point, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
                diagnosis: "batched", durationSeconds: 30, buildDurationSeconds: 4, testDurationSeconds: 30
            )
        }
        let resumedPoint = try makeAnchoredPoint(file: "Sources/MixResumed.swift")
        let resumed = makeResult(
            point: resumedPoint, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
            diagnosis: "resumed", durationSeconds: 99, buildDurationSeconds: 99, testDurationSeconds: 99
        ).markedAsCheckpointResume()
        let cachedPoint = try makeAnchoredPoint(file: "Sources/MixCached.swift")
        let cached = makeResult(
            point: cachedPoint, outcome: .survived, evidence: makeEvidence(), testSummary: makeTestSummary(),
            diagnosis: "cached", durationSeconds: 77, buildDurationSeconds: 77, testDurationSeconds: 77
        ).markedAsCrossRunCacheHit()

        let results = freshBatched + [resumed, cached]
        let batchExecution = BatchExecutionSummary(batchCount: 1, totalConfigurations: 2, batchDurations: [30])
        let report = RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: makeBaseline(), ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true),
            batchExecution: batchExecution
        )

        let summary = PerformanceSummary(report: report)

        // Only the one real batch duration and the two fresh mutants' build
        // times count — the resumed/cached mutants' 99s/77s never entered
        // this run's wall clock at all.
        #expect(summary.mutantTestSeconds == 30)
        #expect(summary.mutantBuildSeconds == 8) // 4 x 2 fresh mutants
        #expect(summary.resumedMutants == 1)
        #expect(summary.cachedMutants == 1)
    }

    // MARK: - Baseline breakdown

    @Test("Baseline build/test/profiling surface directly from BaselineRecord")
    func baselineBreakdownSurfaces() throws {
        let point = try makeAnchoredPoint(file: "Sources/Baseline.swift")
        let plan = makePlan(mutations: [point])
        let result = makeResult(point: point, outcome: .survived)
        let baseline = BaselineRecord(
            passed: true, testSummary: makeTestSummary(), durationSeconds: 25,
            buildProductHash: "hash", buildCommand: nil, testCommand: nil,
            buildDurationSeconds: 8, testDurationSeconds: 12, profilingDurationSeconds: 3.5
        )
        let report = RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: baseline, ledger: makeLedger([result]),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger([result]), baselinePassed: true)
        )

        let summary = PerformanceSummary(report: report)

        #expect(summary.baselineSeconds == 25)
        #expect(summary.baselineBuildSeconds == 8)
        #expect(summary.baselineTestSeconds == 12)
        #expect(summary.baselineProfilingSeconds == 3.5)
    }

    /// Older reports never measured baseline build/test/profiling at all —
    /// `nil` has to mean "not measured", not get coerced into 0 and silently
    /// misreported as a real, instantaneous baseline stage.
    @Test("Baseline breakdown is nil, not zero, when never measured")
    func baselineBreakdownNilWhenUnmeasured() throws {
        let point = try makeAnchoredPoint(file: "Sources/BaselineUnmeasured.swift")
        let plan = makePlan(mutations: [point])
        let result = makeResult(point: point, outcome: .survived)
        let report = makeReport(plan: plan, results: [result]) // makeBaseline() sets no stage timings

        let summary = PerformanceSummary(report: report)

        #expect(summary.baselineBuildSeconds == nil)
        #expect(summary.baselineTestSeconds == nil)
        #expect(summary.baselineProfilingSeconds == nil)
    }

    // MARK: - Other/unaccounted bucket

    /// In a realistic, fully-instrumented run, every phase should account
    /// for almost all of the wall clock, leaving a small, non-negative
    /// remainder for the uninstrumented sandbox/workspace overhead.
    @Test("The other bucket is non-negative and reflects genuinely uninstrumented time")
    func otherBucketIsNonNegativeAndReasonable() throws {
        let points = try (0 ..< 2).map { try makeAnchoredPoint(file: "Sources/Other\($0).swift") }
        let plan = makePlan(mutations: points)
        let results = points.map { point in
            makeResult(
                point: point, outcome: .killedByAssertion, evidence: makeEvidence(), testSummary: makeTestSummary(),
                diagnosis: "confirmed", durationSeconds: 20, buildDurationSeconds: 10, testDurationSeconds: 15,
                confirmationDurationSeconds: 2.5
            )
        }
        let baseline = BaselineRecord(
            passed: true, testSummary: makeTestSummary(), durationSeconds: 35,
            buildProductHash: "hash", buildCommand: nil, testCommand: nil,
            buildDurationSeconds: 10, testDurationSeconds: 20, profilingDurationSeconds: 5
        )
        // Total wall clock 100s. Accounted: baseline 35 + mutant build 20
        // (10x2) + mutant test 30 (15x2, no batching here) + confirmation 5
        // (2.5x2) = 90. Ten seconds of real, uninstrumented overhead remain.
        let report = RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: baseline, ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)
        )

        let summary = PerformanceSummary(report: report)

        let other = try #require(summary.otherSeconds)
        #expect(other >= 0)
        #expect(other == 10)
    }
}
