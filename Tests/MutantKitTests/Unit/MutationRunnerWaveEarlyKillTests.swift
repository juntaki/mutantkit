import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// End-to-end coverage for wave-based early kill —
/// `Configuration.execution.earlyAbortSelectedTests` combined with
/// `testBatchSize` — the batched replacement for
/// `PrioritizingTestAdapter`'s one-`xcodebuild`-invocation-per-test
/// strategy. See `MutationRunner.testInWaves`.
///
/// Each wave batch-tests one prioritised covering test per surviving
/// mutant: a mutant whose test fails is killed and drops out; one whose
/// test passes advances to its next covering test in the next wave; one
/// that exhausts its covering tests without ever failing is `.survived`.
/// Mutants with no covering-test attribution run their full configured test
/// list in a single batch and never enter the wave loop.
///
/// Several tests in this suite assert on wave-boundary durations
/// (`waveDurationSeconds`, `mutantTimeoutSeconds`). These are realized
/// through a `ManualClock` shared between `MutationRunner` and
/// `SpyWaveAdapter` (see both types below) — `waveDurationSeconds` advances
/// that fake clock by an exact amount instead of sleeping in real wall-clock
/// time, so every duration this suite asserts on is deterministic
/// regardless of scheduling delays from unrelated, concurrently-running
/// tests. This suite previously ran `.serialized` to keep real
/// `Task.sleep`-controlled durations out of CPU contention with other
/// suites' tests; that dependency is gone, so this suite runs concurrently
/// with the rest of the target like any other.
@Suite("Mutation runner: wave-based early kill")
struct MutationRunnerWaveEarlyKillTests {
    private let fixture = WaveEarlyKillFixture()

    @Test("A mutant killed on its first wave's test stops immediately, never running its later covering tests")
    func killedOnFirstWaveStopsImmediately() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .failed]] }
        )
        let report = outcome.report
        let adapter = outcome.adapter
        let points = outcome.points
        let priorityStoreURL = outcome.priorityStoreURL

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        // Only one wave ran, and it ran only testA — testB, the mutant's
        // second covering test, was never reached.
        //
        // `#require` here, not `#expect`: this exact assertion has been
        // observed to crash the whole test process (`Array.subscript`
        // trapping on an out-of-bounds index below) under severe machine
        // contention, when `#expect`'s non-fatal failure let execution
        // fall through to `calls[0]` with `calls` shorter than expected.
        // Fail the test cleanly instead of taking the process down with it.
        let calls = await adapter.runBatchCalls
        try #require(calls.count == 1, "expected exactly one wave, got \(calls.count)")
        #expect(calls[0].map(\.id) == [points[0].id])
        #expect(calls[0][0].selectedTests == [testA])

        // The detecting test is credited in the priority store's history.
        let detections = fixture.persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == 1)
        #expect(detections[testB.onlyTestingArgument] == nil)
    }

    @Test("A mutant survives waves 1 and 2 and is killed on wave 3, advancing one test per wave")
    func killedOnThirdWaveAfterTwoSurvivedWaves() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            waveOutcomes: { points in
                [points[0].id: [testA: .passed, testB: .passed, testC: .failed]]
            },
            waveDurationSeconds: 0.02
        )
        let report = outcome.report
        let adapter = outcome.adapter

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        let calls = await adapter.runBatchCalls
        #expect(calls.count == 3, "expected one wave per covering test up to the kill, got \(calls.count)")
        // Alphabetical priority order (a fresh store has no history), one
        // test per wave, front element dropped each time it passes.
        #expect(calls[0][0].selectedTests == [testA])
        #expect(calls[1][0].selectedTests == [testB])
        #expect(calls[2][0].selectedTests == [testC])

        // Reported duration accumulates all three waves, not just the final
        // one that produced the kill — codex review finding on this branch.
        let testDuration = try #require(report.results[0].testDurationSeconds)
        #expect(testDuration >= 0.05, "expected roughly 3 waves' worth of accumulated duration, got \(testDuration)")
    }

    @Test(
        """
        Wave-based early kill still dispatches when incrementalBuild is also on — codex review finding on \
        perf/build-test-pipeline: pipelining incremental+batch mode has no equivalent to wave-based early kill, \
        so a wave-mode configuration must keep using the sequential incremental+batch path, not silently fall \
        back to plain batching
        """
    )
    func waveDispatchSurvivesCombinationWithIncrementalBuild() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            waveOutcomes: { points in
                [points[0].id: [testA: .passed, testB: .passed, testC: .failed]]
            },
            incrementalBuild: true
        )
        let report = outcome.report
        let adapter = outcome.adapter

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        // If this configuration had been silently routed through the
        // pipelined path instead, the mutant would run all three covering
        // tests in one shot (no early abort) rather than one wave per test.
        //
        // `#require`, not `#expect`: this exact assertion has been observed
        // to crash the whole test process (unguarded `calls[0]` below
        // trapping on an out-of-bounds index) under severe machine
        // contention, when `#expect`'s non-fatal failure let execution fall
        // through with `calls` shorter than expected. Fail cleanly instead.
        let calls = await adapter.runBatchCalls
        try #require(calls.count == 3, "expected one wave per covering test up to the kill, got \(calls.count)")
        #expect(calls[0][0].selectedTests == [testA])
        #expect(calls[1][0].selectedTests == [testB])
        #expect(calls[2][0].selectedTests == [testC])
    }

    @Test("A mutant killed on wave 3 reports every wave's evidence, not just the final one")
    func killedOnThirdWaveReportsAllWaveEvidence() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            waveOutcomes: { points in
                [points[0].id: [testA: .passed, testB: .passed, testC: .failed]]
            }
        )
        let report = outcome.report

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        // Without `testAttempts`, only the final wave's command/summary
        // survives into `MutationEvidence` — this is the exact evidence this
        // branch's review flagged as silently lost for a mutant killed after
        // surviving earlier waves.
        let attempts = try #require(report.results[0].evidence?.testAttempts)
        #expect(attempts.count == 3, "expected one recorded attempt per wave (passed, passed, failed)")
        #expect(attempts.map(\.waveIndex) == [0, 1, 2])
        #expect(attempts.map(\.status) == ["passed", "passed", "failed"])
        #expect(attempts.map(\.selectedTests) == [
            [testA.onlyTestingArgument], [testB.onlyTestingArgument], [testC.onlyTestingArgument]
        ])
    }

    @Test("A mutant that exhausts every covering test without failing survives, having run only those tests once each")
    func exhaustsCoveringTestsWithoutFailingSurvives() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed]] },
            waveDurationSeconds: 0.02
        )
        let report = outcome.report
        let adapter = outcome.adapter

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .survived)

        // Exactly two waves — one per covering test — and no third,
        // full-suite run once the list was exhausted.
        let calls = await adapter.runBatchCalls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.count == 1 && $0[0].selectedTests?.count == 1 })

        // A survived mutant reports its accumulated duration too — codex
        // review finding on this branch found the exhausted-survivor path
        // omitted testDurationSeconds entirely.
        let testDuration = try #require(report.results[0].testDurationSeconds)
        #expect(testDuration >= 0.03, "expected roughly 2 waves' worth of accumulated duration, got \(testDuration)")
    }

    @Test("Mutants without covering-test attribution run their full test list in wave 1 and never appear in wave 2+")
    func unattributedMutantRunsFullSuiteOnceAndIsExcludedFromLaterWaves() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let outcome = try await fixture.run(
            count: 2,
            testBatchSize: 10,
            coverage: { points in
                [
                    // Point 0: known attribution, two covering tests —
                    // survives wave 1, killed in wave 2.
                    points[0].file: [
                        points[0].line: [testA, testB],
                        // Point 1: present but empty — covered, but no
                        // individual test's profiling run was uniquely
                        // attributed to it, the real shape of "unattributed"
                        // (absent entirely would instead fast-path to
                        // `.noCoverage` before test selection ever runs).
                        points[1].line: []
                    ]
                ]
            },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .failed]] },
            fullSuiteOutcomes: { points in [points[1].id: .passed] }
        )
        let report = outcome.report
        let adapter = outcome.adapter
        let points = outcome.points

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .killedByAssertion)
        #expect(sorted[1].outcome == .survived)

        let calls = await adapter.runBatchCalls
        // Call 0: the unattributed batch, point 1 alone, full test list
        // (nil selectedTests). Call 1: wave 1, point 0 alone, testA. Call
        // 2: wave 2, point 0 alone, testB.
        #expect(calls.count == 3)
        #expect(calls[0].map(\.id) == [points[1].id])
        #expect(calls[0][0].selectedTests == nil)

        // The unattributed mutant never appears again, in wave 1 or wave 2.
        #expect(!calls[1].map(\.id).contains(points[1].id))
        #expect(!calls[2].map(\.id).contains(points[1].id))
        #expect(calls[1].map(\.id) == [points[0].id])
        #expect(calls[2].map(\.id) == [points[0].id])
    }

    /// Codex review finding on this branch: an earlier version of the wave
    /// loop put every surviving mutant into one `runBatch` call regardless
    /// of `testBatchSize`, discarding the resource bound that setting exists
    /// to enforce.
    @Test("A wave with more survivors than testBatchSize splits into multiple batch calls")
    func waveRespectsConfiguredBatchSize() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let outcome = try await fixture.run(
            count: 5,
            testBatchSize: 2,
            coverage: { points in
                var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
                for point in points {
                    coveringTests[point.file, default: [:]][point.line] = [testA]
                }
                return coveringTests
            },
            waveOutcomes: { points in
                Dictionary(uniqueKeysWithValues: points.map { ($0.id, [testA: TestRunStatus.passed]) })
            }
        )
        let report = outcome.report
        let adapter = outcome.adapter
        let points = outcome.points

        #expect(report.results.count == 5)
        #expect(report.results.allSatisfy { $0.outcome == .survived })

        let calls = await adapter.runBatchCalls
        // 5 survivors, batchSize 2: chunks of 2, 2, 1 — three batch calls in
        // this one wave, never a single call with all 5.
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.count <= 2 })
        #expect(Set(calls.flatMap { $0.map(\.id) }) == Set(points.map(\.id)))

        // Codex review finding on this branch: wave mode used to leave
        // batchDurations empty even though each chunk's real duration was
        // measured — PerformanceSummary reads that shape as "legacy report,
        // timing unavailable" and silently drops aggregate test-time
        // reporting for every wave-based run.
        let summary = try #require(report.batchExecution)
        #expect(summary.batchDurations.count == 3)
        #expect(summary.batchDurations.allSatisfy { $0 >= 0 })
    }

    /// Codex review finding on this branch: charging every mutant in a
    /// shared batch the batch's *whole* wall-clock duration (rather than an
    /// even split) inflated `cumulativeTestSeconds` by up to
    /// `chunk.count`x, so a batch of several mutants could exhaust every
    /// one of their budgets at once, well before any of them individually
    /// used that much time.
    @Test("Mutants sharing a wave batch each accumulate their fair share of its duration, not the whole batch")
    func sharedBatchDurationIsSplitFairly() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let outcome = try await fixture.run(
            count: 2,
            testBatchSize: 10,
            coverage: { points in
                var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
                for point in points {
                    coveringTests[point.file, default: [:]][point.line] = [testA, testB]
                }
                return coveringTests
            },
            // Both mutants share every wave batch — 2 configurations per
            // batch throughout.
            waveOutcomes: { points in
                Dictionary(uniqueKeysWithValues: points.map { ($0.id, [testA: .passed, testB: .passed]) })
            },
            // ~0.04s per shared batch (2 mutants, 2 waves): if the whole
            // batch duration were charged to each mutant instead of half,
            // cumulative would be roughly double this.
            waveDurationSeconds: 0.02
        )
        let report = outcome.report

        #expect(report.results.count == 2)
        #expect(report.results.allSatisfy { $0.outcome == .survived })
        for result in report.results {
            let duration = try #require(result.testDurationSeconds)
            // Two waves, each mutant's fair share ~0.01s: comfortably under
            // what charging the full ~0.02s-per-wave batch to both mutants
            // would produce (~0.04s+).
            #expect(duration < 0.035, "expected roughly half-share accumulation, got \(duration)")
        }
    }
}
