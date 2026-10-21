import Foundation
import MutationModel

/// Baseline establishment for `SchemataMutationRunner`.
extension SchemataMutationRunner {
    /// `establishBaseline`'s full result: the record every caller already
    /// expected, plus — when `execution.selectCoveringTests` asked for it
    /// and the adapter could produce one — the per-test attribution
    /// `run()` threads down to every embedded mutation's own token run.
    /// `perTestCoverage == nil` means every mutant runs the full configured
    /// test list, the same safe fallback isolated mode's own
    /// `MutationRunner.BaselineContext` uses.
    struct BaselineEstablishment {
        let record: BaselineRecord
        let perTestCoverage: PerTestCoverageMap?
        /// The aggregate "was this line ever executed at all" map — distinct
        /// from `perTestCoverage`'s "which tests cover it" attribution, the
        /// same distinction `MutationRunner.BaselineContext` draws. Used
        /// only for the `coverage.isKnownUncovered(point)` pre-check (see
        /// `runPrimary`) that lets a mutation on a genuinely-unreached line
        /// skip a schemata token attempt entirely, the same fast path
        /// isolated mode's own `prepare(...)` already takes.
        let coverage: CoverageMap?
    }

    /// Throws `RunError.baselineDidNotPass` rather than returning a failed
    /// record, so the diagnosis is thrown by whoever actually observed the
    /// failure and no caller has to reconstruct one. The alternative this
    /// replaces — returning the record and letting `run()` re-derive a
    /// sentence from `testSummary` — could only ever say "N of M tests
    /// failed", and on the failure shape that actually occurred in CI (a
    /// baseline whose suite ran nothing: `0 of 0`) that names neither what
    /// failed nor that nothing ran at all.
    func establishBaseline() async throws -> BaselineEstablishment {
        if let preEstablishedBaseline = session.preEstablishedBaseline {
            switch preEstablishedBaseline {
            case let .failed(record, diagnosis):
                throw RunError.baselineDidNotPass(record: record, diagnosis: diagnosis)
            case let .established(shared):
                return BaselineEstablishment(record: shared.record, perTestCoverage: shared.perTestCoverage, coverage: shared.coverage)
            }
        }

        let started = Date()
        let spanStart = GateTimingRecorder.shared.now()
        let sandbox = try await session.workspaces.createSandbox(id: "schemata-baseline")
        do {
            let established = try await establishBaseline(in: sandbox.workspaceRoot, startedAt: started)
            try? await session.workspaces.destroySandbox(sandbox)
            await GateTimingRecorder.shared.record("schemata.baseline.total", start: spanStart)
            return established
        } catch {
            try? await session.workspaces.destroySandbox(sandbox)
            await GateTimingRecorder.shared.record("schemata.baseline.total.failed", start: spanStart)
            throw error
        }
    }

    func establishBaseline(in sandbox: URL, startedAt started: Date) async throws -> BaselineEstablishment {
        let baselineBuildSpanStart = GateTimingRecorder.shared.now()
        let artifact = try await build.buildBaseline(in: sandbox)
        await GateTimingRecorder.shared.record("schemata.baseline.build", start: baselineBuildSpanStart)
        let testStarted = Date()
        let baselineTestSpanStart = GateTimingRecorder.shared.now()
        // The baseline's own limit, unchanged: this run compiles nothing
        // mutated and executes the entire suite once, which is a different
        // — legitimately longer — concern from one mutant's own run.
        let run = try await test.runBaseline(
            artifact, in: sandbox, timeoutSeconds: TimeoutController(settings: timeouts).baselineLimitSeconds
        )
        await GateTimingRecorder.shared.record("schemata.baseline.test", start: baselineTestSpanStart)
        let testDurationSeconds = Date().timeIntervalSince(testStarted)

        let record = BaselineRecord(
            passed: run.status == .passed,
            testSummary: run.summary,
            durationSeconds: Date().timeIntervalSince(started),
            buildProductHash: artifact.productHash,
            buildCommand: artifact.command,
            testCommand: run.command,
            buildDurationSeconds: testStarted.timeIntervalSince(started),
            testDurationSeconds: testDurationSeconds
        )

        // Thrown here, where `run` — the observation itself — is still in
        // hand: `SharedBaselineEstablisher` words the identical failure the
        // identical way, and neither wording is re-derived from the record's
        // counts afterwards.
        guard record.passed else {
            throw RunError.baselineDidNotPass(record: record, diagnosis: SharedBaselineEstablisher.suiteDidNotPassDiagnosis(run))
        }

        // Per-test attribution (`execution.selectCoveringTests`), measured
        // — like isolated mode's own `MutationRunner.establishBaseline` —
        // *before* the sandbox above is destroyed by the caller: the
        // per-test coverage read needs the same instrumented artifact/
        // sandbox `runBaseline` just used. Only reached once the baseline is
        // known to have passed (the guard above already threw otherwise, and
        // there is nothing legitimate to attribute against a suite that did
        // not pass), only when configured, and only when the adapter conforms to
        // `TestSelecting` — mirroring `MutationRunner`'s exact guard
        // structure so a coverage-blind schemata adapter (no `TestSelecting`
        // conformance) behaves identically to before this parameter existed.
        //
        // The `CoverageProfileCache` is consulted *before* the adapter is
        // asked to measure anything, identically to `MutationRunner
        // .establishBaseline`: a hit skips the profiling pass entirely, a
        // miss measures as usual and stores the result back for the next
        // run. Only the coverage attribution is served from the cache — the
        // baseline build and suite run above have already happened either
        // way, because the suite-must-pass gate and the timeout calibration
        // are not facts a cache can stand in for.
        var perTestCoverage: PerTestCoverageMap?
        if selectCoveringTests {
            let coverageSpanStart = GateTimingRecorder.shared.now()
            if let key = session.coverageCacheKey, let cached = await session.coverageCache?.load(key) {
                perTestCoverage = cached
                await GateTimingRecorder.shared.record("schemata.coverage.cacheHit", start: coverageSpanStart)
            } else if let selecting = selectingTest {
                perTestCoverage = await selecting.measurePerTestCoverage(
                    artifact: artifact, in: sandbox, timeoutSeconds: TimeoutController(settings: timeouts).baselineLimitSeconds
                )
                if let measured = perTestCoverage, let key = session.coverageCacheKey {
                    await session.coverageCache?.store(measured, for: key)
                }
                await GateTimingRecorder.shared.record("schemata.coverage.measured", start: coverageSpanStart)
            }
        }

        // Reported to stderr only: this runner has no `OperationalIssueLog`
        // of its own, and this path runs only when no baseline was
        // pre-established for it — the `SharedBaselineEstablisher` that
        // normally establishes a schemata run's baseline reports the same
        // fact into `RunReport.operationalIssues` itself.
        if let perTestCoverage { await PerTestCoverageAttribution.report(perTestCoverage, to: nil) }
        // `flatMap`, not `?.`: `aggregate()` is itself optional now, and
        // returns `nil` for a partial attribution precisely so the
        // `.noCoverage` fast path cannot be driven by one (see its own doc
        // comment). Flattening keeps "no map at all" and "a map that cannot
        // answer the uncovered question" as the one value every caller
        // already handles.
        return BaselineEstablishment(
            record: record, perTestCoverage: perTestCoverage, coverage: perTestCoverage.flatMap { $0.aggregate() }
        )
    }
}
