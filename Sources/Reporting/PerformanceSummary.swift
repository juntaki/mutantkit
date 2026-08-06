import Foundation
import MutationModel

/// Performance view derived from a completed report without changing the
/// stable result schema. Surfaces per-stage wall clock (baseline build/test/
/// profiling, mutant build/test/confirmation) alongside the existing
/// mutant-execution distribution stats, so "where did the time go" can be
/// answered without re-deriving it from the raw report every time.
///
/// ## The batched test-time problem
///
/// `MutationResult.testDurationSeconds` records the *same* value on every
/// mutant that shared one batch's `xcodebuild` invocation (see that
/// property's doc comment) — correct for "how long did this mutant's batch
/// take", but naively summing it across all mutants would multiply one real
/// invocation's duration by however many mutants happened to share it. A
/// batch of 10 mutants sharing a real 60s test run would be counted as 600s
/// of test time, ten times over.
///
/// Three ways to fix this were considered:
///
/// 1. **Group by exact `testDurationSeconds` value equality** and count each
///    distinct value once. Rejected: two genuinely different batches could
///    coincidentally clock the same wall-clock duration (unlikely, but this
///    number exists so a user can *trust* it — "usually right" is not good
///    enough for a measurement whose whole point is catching surprises).
/// 2. **Add a per-mutant back-reference** ("which batch was I in") to
///    `MutationResult`. Rejected: it would permanently grow the stable result
///    schema for a fact `BatchExecutionSummary` can already express in
///    aggregate, and every existing/archived report would need to fabricate
///    a value for it on decode.
/// 3. **Record each batch's own duration once, at the source.** `MutationRunner
///    .testAndFinish` already measures one real `batchTestDuration` per chunk
///    before fanning it out to every mutant in that chunk — it now also
///    appends that one number to `BatchExecutionSummary.batchDurations`. This
///    view sums `batchDurations` directly instead of any per-mutant field,
///    so it is an exact count of real invocations, not an inference.
///
/// Option 3 was chosen. It also resolves a related problem for free: a run's
/// `evaluate(_:baseline:)` picks exactly one test-execution strategy for the
/// whole pending set (see that method), and `testAndFinish` — the only
/// producer of `batchExecution` — either batches all of `readyToTest` or
/// falls back to testing all of it individually; it never does both in the
/// same run. So whenever `batchExecution` reports at least one real batch
/// (`batchDurations` non-empty), every fresh, tested mutant in the report
/// belongs to that batched accounting, and summing `batchDurations` alone is
/// the complete, exact test-phase total — no per-mutant sum needs to be
/// added alongside it. When no batch ever ran (batching not configured, or
/// every ready mutant fell back to individual testing), each fresh mutant's
/// `testDurationSeconds` is already its own real, unshared measurement, and
/// summing those directly is exact too.
///
/// ## Resumed and cached mutants
///
/// A checkpoint-resumed or cross-run-cache-hit mutant (`origin != .fresh`)
/// did no building or testing in *this* run at all — its stage timings are
/// whatever a *previous* run measured, possibly against a different batch
/// shape. Including them here would both misattribute historical time to
/// this run's wall clock and reintroduce the same double-counting risk this
/// type exists to fix. Every phase sum below is therefore scoped to
/// `origin == .fresh`; `resumedMutants`/`cachedMutants` still report their
/// counts, just not their historical durations.
public struct PerformanceSummary: Codable, Sendable, Hashable {
    public let totalWallClockSeconds: Double
    public let baselineSeconds: Double
    /// Wall time of `BaselineRecord.buildDurationSeconds`; `nil` when the
    /// baseline never reached a completed build (see that property).
    public let baselineBuildSeconds: Double?
    /// Wall time of `BaselineRecord.testDurationSeconds`; same absence rule.
    public let baselineTestSeconds: Double?
    /// Wall time of `BaselineRecord.profilingDurationSeconds`; `nil` when
    /// coverage profiling was never attempted.
    public let baselineProfilingSeconds: Double?
    public let totalMutantSeconds: Double
    public let averageMutantSeconds: Double?
    public let medianMutantSeconds: Double?
    public let p95MutantSeconds: Double?
    /// Sum of `buildDurationSeconds` across this run's freshly-built
    /// mutants. Unambiguous: a build is always genuinely per-mutant, even
    /// when batching shares the *test* phase afterward.
    public let mutantBuildSeconds: Double
    /// The corrected, de-duplicated total test-phase wall clock — see this
    /// type's doc comment for how batched durations are counted once rather
    /// than once per mutant. `nil` when a real batch ran but the report
    /// predates `BatchExecutionSummary.batchDurations` (an archived report
    /// decoded against an older schema) — there the per-mutant fields are
    /// each a duplicate of an unrecoverable batch total, and reporting
    /// "unavailable" is the fail-closed choice over silently multiplying one
    /// real invocation's duration by however many mutants shared it.
    public let mutantTestSeconds: Double?
    /// Sum of `confirmationDurationSeconds` across this run's fresh mutants.
    /// Unambiguous: a confirmation retest is always its own independent,
    /// unbatched sandbox, never shared across mutants.
    public let confirmationSeconds: Double
    /// `totalWallClockSeconds` minus every accounted phase above (baseline
    /// build/test/profiling, mutant build/test, confirmation). Positive time
    /// here is real and honest, not an error: sandbox creation/teardown,
    /// workspace prep, and plan/report assembly are not separately
    /// instrumented today, so they land here rather than being silently
    /// folded into a phase that didn't cause them.
    ///
    /// Clamped to zero rather than allowed to go negative. With
    /// `workers > 1`, several mutants build (and occasionally confirm)
    /// concurrently, so their individual durations genuinely overlap in wall
    /// time — their sum can legitimately exceed the run's total elapsed time.
    /// A raw subtraction would then go negative, which contradicts "unaccounted
    /// time remaining" outright; zero here means "every measured phase's sum
    /// already covers (or exceeds, via overlap) the wall clock," not "nothing
    /// unaccounted for." `nil` when `mutantTestSeconds` itself is unavailable
    /// (see that property) — the accounting is incomplete, not merely small.
    public let otherSeconds: Double?
    public let batchCount: Int?
    public let totalConfigurations: Int?
    public let averageConfigurationsPerBatch: Double?
    public let executedMutants: Int
    /// Mutants loaded from this run's own checkpoint — an interrupted attempt
    /// resumed against an identical context. Distinct from `cachedMutants`,
    /// which counts cross-run cache reuses; conflating the two hid how much
    /// of a run was a cheap reuse versus a half-finished resume.
    public let resumedMutants: Int
    /// Mutants reused from the cross-run result cache without rebuilding or
    /// retesting — a prior run's stored verdict. See `ResultOrigin`.
    public let cachedMutants: Int
    public let crashConfirmations: Int
    public let timeoutConfirmations: Int

    public init(report: RunReport) {
        totalWallClockSeconds = max(0, report.finishedAt.timeIntervalSince(report.startedAt))
        baselineSeconds = report.baseline.durationSeconds
        baselineBuildSeconds = report.baseline.buildDurationSeconds
        baselineTestSeconds = report.baseline.testDurationSeconds
        baselineProfilingSeconds = report.baseline.profilingDurationSeconds

        let durations = report.results
            .filter { $0.outcome != .skipped && $0.outcome != .noCoverage }
            .map(\.durationSeconds)
            .sorted()
        totalMutantSeconds = durations.reduce(0, +)
        executedMutants = durations.count
        averageMutantSeconds = durations.isEmpty ? nil : totalMutantSeconds / Double(durations.count)
        medianMutantSeconds = Self.percentile(0.50, values: durations)
        p95MutantSeconds = Self.percentile(0.95, values: durations)
        resumedMutants = report.results.filter { $0.origin == .checkpoint }.count
        cachedMutants = report.results.filter { $0.origin == .crossRunCache }.count
        crashConfirmations = report.results.filter { $0.evidence?.crashConfirmation != nil }.count
        timeoutConfirmations = report.results.filter { $0.evidence?.timeoutConfirmation != nil }.count

        let freshResults = report.results.filter { $0.origin == .fresh }
        mutantBuildSeconds = freshResults.compactMap(\.buildDurationSeconds).reduce(0, +)
        confirmationSeconds = freshResults.compactMap(\.confirmationDurationSeconds).reduce(0, +)

        let batchDurations = report.batchExecution?.batchDurations ?? []
        let batchCountRan = report.batchExecution?.batchCount ?? 0
        if !batchDurations.isEmpty {
            // A real batch ran this run: `testAndFinish` fanned every
            // ready-to-test mutant through the batched path, so every fresh
            // mutant's `testDurationSeconds` is a duplicate of one of these
            // per-chunk measurements already. Summing both would double
            // count; `batchDurations` alone is the complete, exact total.
            mutantTestSeconds = batchDurations.reduce(0, +)
        } else if batchCountRan > 0 {
            // A real batch ran (per `batchExecution.batchCount`), but this
            // report predates `batchDurations` — an archived report decoded
            // against an older schema. Every fresh mutant's own
            // `testDurationSeconds` is a duplicate of a batch total we no
            // longer have; summing them (the old behavior) would silently
            // reintroduce the exact over-count this type exists to prevent.
            // Report unavailable rather than fabricate a number.
            mutantTestSeconds = nil
        } else {
            // No batch ran: batching wasn't configured, or every mutant fell
            // back to individual testing (a real, zero-batch outcome — see
            // `BatchExecutionSummary`'s doc comment). Either way each fresh
            // mutant's `testDurationSeconds` is its own unshared measurement.
            mutantTestSeconds = freshResults.compactMap(\.testDurationSeconds).reduce(0, +)
        }

        batchCount = report.batchExecution?.batchCount
        totalConfigurations = report.batchExecution?.totalConfigurations
        averageConfigurationsPerBatch = report.batchExecution?.averageConfigurationsPerBatch

        if let mutantTestSeconds {
            let accountedSeconds = (baselineBuildSeconds ?? 0) + (baselineTestSeconds ?? 0) + (baselineProfilingSeconds ?? 0)
                + mutantBuildSeconds + mutantTestSeconds + confirmationSeconds
            // Clamped, not raw: overlapping concurrent workers can make the
            // accounted sum legitimately exceed wall clock — see this
            // property's doc comment.
            otherSeconds = max(0, totalWallClockSeconds - accountedSeconds)
        } else {
            otherSeconds = nil
        }
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let raw = percentile * Double(values.count - 1)
        let lower = Int(floor(raw))
        let upper = Int(ceil(raw))
        if lower == upper { return values[lower] }
        let weight = raw - Double(lower)
        return values[lower] * (1 - weight) + values[upper] * weight
    }
}

public struct PerformanceReporter: Reporter {
    public init() {}

    public func render(_ report: RunReport) throws -> String {
        let summary = PerformanceSummary(report: report)
        func seconds(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.2fs", value)
        }

        func count(_ value: Int?) -> String {
            guard let value else { return "n/a" }
            return "\(value)"
        }

        return """
        MutantKit performance summary
          total wall clock:      \(seconds(summary.totalWallClockSeconds))
          baseline (total):      \(seconds(summary.baselineSeconds))
            baseline build:      \(seconds(summary.baselineBuildSeconds))
            baseline test:       \(seconds(summary.baselineTestSeconds))
            baseline profiling:  \(seconds(summary.baselineProfilingSeconds))
          mutant build (sum):    \(seconds(summary.mutantBuildSeconds))
          mutant test (sum):     \(seconds(summary.mutantTestSeconds))
          confirmation (sum):    \(seconds(summary.confirmationSeconds))
          other / unaccounted:   \(seconds(summary.otherSeconds))
          mutant time (sum):     \(seconds(summary.totalMutantSeconds))
          executed mutants:      \(summary.executedMutants)
          average / mutant:      \(seconds(summary.averageMutantSeconds))
          median / mutant:       \(seconds(summary.medianMutantSeconds))
          p95 / mutant:          \(seconds(summary.p95MutantSeconds))
          batch count:           \(count(summary.batchCount))
          total configurations:  \(count(summary.totalConfigurations))
          avg configs / batch:   \(seconds(summary.averageConfigurationsPerBatch))
          resumed mutants:       \(summary.resumedMutants)
          cache-reused mutants: \(summary.cachedMutants)
          crash confirmations:   \(summary.crashConfirmations)
          timeout confirmations: \(summary.timeoutConfirmations)
        """
    }
}
