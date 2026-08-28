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
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-wave-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-wave-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// `count` independent bool-literal mutation sites, one per line — each
    /// on its own line deliberately, exactly like the sibling batch-testing
    /// suites: on a shared line every mutant would report the same
    /// `point.line`, and a coverage map keyed by file+line could not tell
    /// them apart.
    private func writeMutantProject(count: Int) throws {
        let url = root.appendingPathComponent("Sources/W.swift")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fields = (0 ..< count).map { "    var v\($0) = true" }.joined(separator: "\n")
        try Data("struct W {\n\(fields)\n}".utf8).write(to: url)
    }

    /// Plans `count` mutants and runs them through a real `MutationRunner`
    /// wired for wave-based early kill: `selectCoveringTests` +
    /// `earlyAbortSelectedTests` + `testBatchSize`, and a `TestPriorityStore`
    /// passed to the runner directly (never wrapped in
    /// `PrioritizingTestAdapter` — that is the CLI's non-batched fallback,
    /// exercised elsewhere).
    ///
    /// `coverage` and `waveOutcomes`/`fullSuiteOutcomes` are built from the
    /// already-planned, ID-sorted points, so callers can key by point index
    /// without knowing a `MutationID` up front.
    private func run(
        count: Int,
        testBatchSize: Int,
        coverage: (_ points: [MutationPoint]) -> [String: [Int: Set<TestIdentifier>]],
        waveOutcomes: (_ points: [MutationPoint]) -> [MutationID: [TestIdentifier: TestRunStatus]] = { _ in [:] },
        fullSuiteOutcomes: (_ points: [MutationPoint]) -> [MutationID: TestRunStatus] = { _ in [:] },
        retestKilledMutants: Bool = false,
        confirmTimedOutMutants: Bool = false,
        mutantTimeoutSeconds: Double? = nil,
        waveDurationSeconds: Double = 0,
        unbatchedOverride: (_ points: [MutationPoint]) -> [MutationID: TestRunStatus] = { _ in [:] },
        // Gate 3 Phase H12.2B: which mutants' wave `.timedOut` result should
        // be scripted as batch-attributed (`isBatchAttributedTimeout: true`
        // — a whole shared invocation killed with no way to tell which
        // configuration caused it) rather than the default, native-XCTest-
        // timeout shape (`false` — this one configuration was individually,
        // trustworthily identified).
        batchAttributedTimeouts: (_ points: [MutationPoint]) -> Set<MutationID> = { _ in [] },
        incrementalBuild: Bool = false
    ) async throws -> (report: RunReport, adapter: SpyWaveAdapter, points: [MutationPoint], priorityStoreURL: URL) {
        try writeMutantProject(count: count)

        let execution = ExecutionSettings(
            workers: 1,
            retestKilledMutants: retestKilledMutants,
            confirmCrashKills: false,
            confirmTimedOutMutants: confirmTimedOutMutants,
            selectCoveringTests: true,
            incrementalBuild: incrementalBuild,
            earlyAbortSelectedTests: true,
            testBatchSize: testBatchSize
        )
        var timeouts = TimeoutSettings()
        if let mutantTimeoutSeconds {
            timeouts.mutant = MutantTimeoutSettings(strategy: .fixed, maximumSeconds: mutantTimeoutSeconds)
        }
        let configuration = Configuration(execution: execution, timeouts: timeouts)
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == count)
        let points = plan.mutations.sorted { $0.id < $1.id }

        let coverageMap = PerTestCoverageMap(coveringTests: coverage(points), source: "test")
        // A manually-advanced clock, shared between the runner and the
        // adapter, replaces `Task.sleep`-and-hope-the-real-elapsed-time-
        // lands-close-enough: `waveDurationSeconds` now advances this fake
        // clock by an exact amount instead of sleeping for real, so every
        // duration this suite asserts on is deterministic — never at the
        // mercy of full-suite CPU contention stretching a real sleep past a
        // budget boundary the test never intended to cross.
        let clock = ManualClock()
        let adapter = SpyWaveAdapter(
            perTestCoverage: coverageMap,
            waveOutcomes: waveOutcomes(points),
            fullSuiteOutcomes: fullSuiteOutcomes(points),
            waveDurationSeconds: waveDurationSeconds,
            unbatchedOverride: unbatchedOverride(points),
            batchAttributedTimeouts: batchAttributedTimeouts(points),
            clock: clock
        )

        let priorityStoreURL = scratchRoot.appendingPathComponent("priority-\(UUID().uuidString).json")
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan,
            configuration: configuration,
            projectRoot: root,
            build: StubBuildAdapter(),
            test: adapter,
            workspaces: workspaces,
            priorityStore: TestPriorityStore(url: priorityStoreURL),
            monotonicNow: clock.now
        )
        let report = try await runner.run()
        return (report, adapter, points, priorityStoreURL)
    }

    /// Decodes a `TestPriorityStore`'s persisted detection counts directly —
    /// the store itself exposes no getter, only `order`/`recordDetection`,
    /// so the on-disk snapshot is the only external window onto what got
    /// credited.
    private func persistedDetections(at url: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistedPriorities.self, from: data)
        else { return [:] }
        return snapshot.detections
    }

    private struct PersistedPriorities: Codable {
        let detections: [String: Int]
    }

    @Test("A mutant killed on its first wave's test stops immediately, never running its later covering tests")
    func killedOnFirstWaveStopsImmediately() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (report, adapter, points, priorityStoreURL) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .failed]] }
        )

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
        let detections = persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == 1)
        #expect(detections[testB.onlyTestingArgument] == nil)
    }

    @Test("A mutant survives waves 1 and 2 and is killed on wave 3, advancing one test per wave")
    func killedOnThirdWaveAfterTwoSurvivedWaves() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            waveOutcomes: { points in
                [points[0].id: [testA: .passed, testB: .passed, testC: .failed]]
            },
            waveDurationSeconds: 0.02
        )

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

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            waveOutcomes: { points in
                [points[0].id: [testA: .passed, testB: .passed, testC: .failed]]
            },
            incrementalBuild: true
        )

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

        let (report, _, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            waveOutcomes: { points in
                [points[0].id: [testA: .passed, testB: .passed, testC: .failed]]
            }
        )

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

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed]] },
            waveDurationSeconds: 0.02
        )

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

        let (report, adapter, points, _) = try await run(
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

        let (report, adapter, points, _) = try await run(
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

        let (report, _, _, _) = try await run(
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

    /// Codex review finding on this branch: an exhausted (survived) or
    /// budget-expired mutant's synthesized final result reported the build
    /// artifact's command as `evidence.testCommand`, discarding the actual
    /// test command/result-artifact evidence its real wave tests produced.
    @Test("A survived mutant's evidence carries its real last test command, not the build command")
    func survivedMutantReportsRealTestCommand() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (report, _, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed]] }
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .survived)
        let testCommand = try #require(report.results[0].evidence?.testCommand)
        // StubBuildAdapter's build command is `swift build`; SpyWaveAdapter's
        // test result command is `xcodebuild test` — seeing the latter here
        // proves this is the real wave test's command, not the build's.
        #expect(testCommand.executable == "xcodebuild")
    }

    /// Codex review finding on this branch: a survivor already close to its
    /// cumulative budget was still handed a batch timeout sized as a fresh
    /// `mutantLimitSeconds` per mutant, which could let a single wave alone
    /// run for nearly another full `mutantLimitSeconds` regardless of what
    /// that survivor had already spent — defeating the cumulative-budget
    /// check that runs before each wave.
    @Test("Each wave's batch timeout reflects survivors' remaining budget, not a fresh one")
    func batchTimeoutReflectsRemainingBudget() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (_, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed]] },
            mutantTimeoutSeconds: 10,
            waveDurationSeconds: 3
        )

        let timeouts = await adapter.runBatchTimeouts
        // `#require`, not `#expect`: observed to crash the whole test
        // process (unguarded `timeouts[0]`/`timeouts[1]` below trapping)
        // under severe machine contention. Fail cleanly instead.
        try #require(timeouts.count == 2)
        // A fixed 10s mutant timeout (`mutantTimeoutSeconds: 10` above) —
        // `TimeoutController.mutantLimitSeconds(selectedTests:)` no longer
        // narrows by selection size (Gate 3 found that uncalibrated for
        // real Xcode/Simulator overhead; see its own doc comment), so this
        // test pins a small budget directly instead.
        // Wave 1: nothing spent yet, so the fresh 10s budget.
        #expect(timeouts[0] == 10)
        // Wave 2: already spent 3s of it in wave 1, so this wave's timeout
        // must reflect the budget already spent (10 - 3 = 7), not the same
        // 10s value repeated.
        #expect(timeouts[1] == 7, "expected wave 2's timeout to reflect the budget already spent, got \(timeouts[1])")
    }

    // MARK: - Native XCTest timeout containment (Gate 3 Phase H3)

    /// A chunk with more than one member is exactly the case native
    /// containment exists for (Phase H1/H2): the outer `batchTimeout` above
    /// stays a shared, ambiguous fail-safe across every member, so this is
    /// where XCTest's own per-test allowance is asked to localize a hang to
    /// just the one member that has it.
    @Test("A multi-member wave chunk's batch call requests native timeout containment, sized from the resolved mutant limit")
    func nativeTimeoutAllowanceIsSetForMultiMemberWaveChunksAboveTheFloor() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (_, adapter, _, _) = try await run(
            count: 3,
            testBatchSize: 3,
            coverage: { points in
                var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
                for point in points { coveringTests[point.file, default: [:]][point.line] = [testA] }
                return coveringTests
            },
            waveOutcomes: { points in
                Dictionary(uniqueKeysWithValues: points.map { ($0.id, [testA: TestRunStatus.passed]) })
            },
            mutantTimeoutSeconds: 90
        )

        let calls = await adapter.runBatchCalls
        #expect(calls.count == 1)
        #expect(calls[0].count == 3)
        let allowances = await adapter.runBatchNativeTimeoutAllowances
        #expect(allowances == [90])
    }

    /// A chunk of exactly one member has no attribution ambiguity for the
    /// outer timeout to begin with — the same reasoning
    /// `XcodeBuildAdapter.runBatchOnDestination`'s own
    /// `isBatchAttributedTimeout: configurationTestIdentifiers.count > 1`
    /// already applies. Nothing for native containment to localize, so it
    /// is not requested.
    @Test("A single-member wave chunk does not request native timeout containment")
    func nativeTimeoutAllowanceIsNilForASingleMemberChunk() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (_, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed]] },
            mutantTimeoutSeconds: 90
        )

        let allowances = await adapter.runBatchNativeTimeoutAllowances
        #expect(allowances == [nil, nil])
    }

    /// Phase H1's spike only ever exercised a 60s allowance against a real
    /// hang — a resolved mutant limit below that has no evidence behind it,
    /// so containment is skipped rather than risking a false-positive
    /// timeout from Xcode/Simulator's own per-invocation startup overhead.
    /// The outer `batchTimeout` alone still applies, exactly as before this
    /// phase.
    @Test("A multi-member wave chunk below Phase H1's validated floor does not request native timeout containment")
    func nativeTimeoutAllowanceIsNilBelowThePhaseH1Floor() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (_, adapter, _, _) = try await run(
            count: 3,
            testBatchSize: 3,
            coverage: { points in
                var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
                for point in points { coveringTests[point.file, default: [:]][point.line] = [testA] }
                return coveringTests
            },
            waveOutcomes: { points in
                Dictionary(uniqueKeysWithValues: points.map { ($0.id, [testA: TestRunStatus.passed]) })
            },
            mutantTimeoutSeconds: 45
        )

        let allowances = await adapter.runBatchNativeTimeoutAllowances
        #expect(allowances == [nil])
    }

    /// Codex review finding on this branch: granting a fresh
    /// `mutantLimitSeconds` budget on every wave means a mutant with many
    /// covering tests could accumulate `coveringTests × mutantLimitSeconds`
    /// of wall clock — the setting no longer bounds what a user configuring
    /// it expects it to. A mutant whose cumulative time already exhausted
    /// its budget must stop, not get another wave.
    @Test("A mutant whose cumulative wave budget estimate expires is verified standalone, not timed out on the estimate alone")
    func cumulativeBudgetExhaustionTriggersStandaloneVerification() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            // testC is the mutant's one still-unrun test once the estimate
            // expires — scripted to genuinely time out, so this test proves
            // the eventual `.timedOut` verdict comes from a real, individual
            // measurement of testC, never from the cumulative estimate alone
            // (which — see the fair-share/estimate-only bug this branch's own
            // real-Xcode acceptance run caught — must never itself decide a
            // classification).
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed, testC: .timedOut]] },
            // A fixed 15s mutant timeout (`mutantTimeoutSeconds: 15` below)
            // — `TimeoutController.mutantLimitSeconds(selectedTests:)` no
            // longer narrows by selection size (Gate 3 found that
            // uncalibrated for real Xcode/Simulator overhead; see its own
            // doc comment), so this test pins the budget directly instead.
            // A real, controllable per-wave duration of 8s: after wave 1
            // cumulative (8s) is under the 15s budget, so wave 2 runs; after
            // wave 2 (16s) it's over budget, so wave 3 never happens — the
            // standalone verification below runs instead.
            mutantTimeoutSeconds: 15,
            waveDurationSeconds: 8
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .timedOut)
        // Two real waves ran (testA, testB) before the budget estimate
        // triggered standalone verification — never zero, which would mean
        // the check fired before any real wave ran at all.
        let calls = await adapter.runBatchCalls
        #expect(calls.count == 2)
        // The standalone verification ran through the unbatched path, on
        // exactly the one test still outstanding, not the batched `runBatch`
        // adapter.
        let standaloneCalls = await adapter.runMutantSelectedTestsCalls
        #expect(standaloneCalls.last ?? nil == [testC])
        // The reported duration is the accumulated simulated time across
        // both waves (8 + 8 = 16s; the unbatched standalone call itself
        // advances the shared clock by nothing), not just the last wave (or
        // omitted entirely).
        let testDuration = try #require(report.results[0].testDurationSeconds)
        #expect(testDuration == 16)
    }

    @Test(
        """
        A mutant whose cumulative wave budget estimate expires but genuinely passes standalone survives, \
        not timed out on the estimate alone
        """
    )
    func cumulativeBudgetExhaustionFalsePositiveSurvives() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        let (report, _, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB, testC]]] },
            // Nothing here is ever scripted to fail. Fair-share division of
            // shared batch wall clock is only ever an ESTIMATE of what this
            // mutant individually spent — reaching a `.timedOut` classification
            // from that estimate alone, with no real measurement backing it,
            // is exactly the bug the real-Xcode acceptance suite caught on
            // this branch. This mutant's real, standalone test of its one
            // remaining test genuinely passes, so it must survive, not time
            // out on an estimate nobody ever verified.
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed, testC: .passed]] },
            mutantTimeoutSeconds: 0.08,
            waveDurationSeconds: 0.05
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .survived)
    }

    /// Codex review finding on this branch: a wave detection is only ever
    /// caused by the ONE test that mutant ran that wave, but confirmation
    /// (`retestKilledMutants`) was rerunning against the mutant's whole
    /// original covering-test set — a broader rerun than the witness that
    /// actually produced the detection, which could reach a different
    /// result than the specific test that killed it.
    @Test("Confirmation reruns only the single test that produced the wave detection")
    func confirmationNarrowsToTheWinningTest() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            // Two covering tests — if confirmation used the whole original
            // selection instead of narrowing to the winner, the individual
            // confirmation call would be given both, not one.
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .failed]] },
            retestKilledMutants: true
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        let confirmationCalls = await adapter.runMutantSelectedTestsCalls
        #expect(confirmationCalls.count == 1, "confirmation should run exactly once, individually, not through runBatch")
        #expect(confirmationCalls[0] == [testA], "confirmation must rerun only the test that produced the detection")
    }

    /// Real-world regression, the same one `testAndFinish` was fixed for:
    /// bundling several unattributed (full-suite-fallback) mutants into one
    /// shared batch multiplies their cost rather than sharing it, which can
    /// exceed even a generously per-mutant-sized timeout and mark every
    /// mutant in that batch unprovable together.
    @Test("Multiple unattributed mutants are never bundled into the same batch")
    func multipleUnattributedMutantsGetSeparateBatches() async throws {
        let (report, adapter, points, _) = try await run(
            count: 3,
            testBatchSize: 10,
            coverage: { points in
                var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
                for point in points {
                    coveringTests[point.file, default: [:]][point.line] = []
                }
                return coveringTests
            },
            fullSuiteOutcomes: { points in
                [points[0].id: .passed, points[1].id: .failed, points[2].id: .passed]
            }
        )

        #expect(report.results.count == 3)
        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .survived)
        #expect(sorted[1].outcome == .killedByAssertion)
        #expect(sorted[2].outcome == .survived)

        let calls = await adapter.runBatchCalls
        // Three unattributed mutants, three separate batch calls — never
        // bundled together, regardless of testBatchSize.
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.count == 1 })
        #expect(Set(calls.flatMap { $0.map(\.id) }) == Set(points.map(\.id)))
    }

    @Test("An infrastructureFailure result within a wave does not credit the test's kill-priority history — the bug fix")
    func infrastructureFailureDoesNotRecordDetection() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (report, _, _, priorityStoreURL) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .infrastructureFailure]] }
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .infrastructureFailure)

        // An infrastructure failure proves nothing about whether testA is
        // any good at catching mutants — it must not be credited. Mirrors
        // `PrioritizingTestAdapter.runMutant`'s identical
        // `.passed, .infrastructureFailure: break` distinction.
        let detections = persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == nil, "an infrastructureFailure must not be recorded as a detection")
    }

    @Test(
        """
        A solo-chunk infrastructureFailure from the wave batch itself is re-verified standalone before being \
        trusted, and a real kill discovered that way is credited — the real-Xcode acceptance bug
        """
    )
    func soloChunkInfrastructureFailureIsReVerifiedStandalone() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (report, _, _, priorityStoreURL) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            // Wave 1's batch itself reports infrastructureFailure for this
            // mutant (a chunk of exactly one — no batch-mate to share
            // ambiguity with, and still wrong on a real Xcode project: this
            // is the exact bug the real-Xcode differential acceptance suite
            // caught, where a solo-survivor wave 2 chunk reported
            // infrastructureFailure for a mutant a standalone rerun
            // immediately confirmed was killedByAssertion).
            waveOutcomes: { points in [points[0].id: [testA: .infrastructureFailure]] },
            // The standalone re-verification (an unbatched runMutant call)
            // gets a different, real answer: testA genuinely fails.
            unbatchedOverride: { points in [points[0].id: .failed] }
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        let detections = persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == 1, "the real, standalone-verified kill must be credited")
    }

    @Test("A wave detection that confirmation downgrades to flaky does not credit the test's kill-priority history")
    func flakyConfirmationDoesNotRecordDetection() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let (report, _, _, priorityStoreURL) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            // Wave 1 reports testA failing this mutant — a detection, on its
            // face. `retestKilledMutants` then reruns the identical mutant
            // against the same narrowed test and gets a pass, the way a
            // genuinely flaky test would: the confirmation downgrades the
            // final outcome to `.flaky`.
            waveOutcomes: { points in [points[0].id: [testA: .failed]] },
            retestKilledMutants: true,
            unbatchedOverride: { points in [points[0].id: .passed] }
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .flaky)

        // The wave's raw result looked like a detection, but the *final*,
        // confirmed outcome is `.flaky` — crediting testA's kill-priority
        // history from the raw wave result (as opposed to the final,
        // confirmed outcome) would corrupt the learned ordering with a
        // result that did not hold up. This is the exact case the review
        // that found this bug described: crediting on the raw wave status
        // instead of waiting for `finishAfterTest`'s confirmation to settle.
        let detections = persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == nil, "a flaky-confirmed result must not be recorded as a detection")
    }

    @Test(
        """
        A mixed multi-wave run — early-killed, late-killed, fully-surviving, and unattributed mutants together — \
        delivers exactly one result per mutant, and batchExecution reports one batch per wave plus the \
        unattributed batch, not one per mutant
        """
    )
    func mixedWaveScenarioExactlyOnceAndBatchAccounting() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        let testC = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testC")

        // Point 0: killed on wave 1 (testA fails immediately).
        // Point 1: survives waves 1-2, killed on wave 3 (testA, testB pass; testC fails).
        // Point 2: exhausts testA, testB without failing → survived.
        // Point 3: unattributed → full-suite batch, passes → survived.
        let (report, adapter, _, _) = try await run(
            count: 4,
            testBatchSize: 10,
            coverage: { points in
                var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
                coveringTests[points[0].file, default: [:]][points[0].line] = [testA]
                coveringTests[points[1].file, default: [:]][points[1].line] = [testA, testB, testC]
                coveringTests[points[2].file, default: [:]][points[2].line] = [testA, testB]
                coveringTests[points[3].file, default: [:]][points[3].line] = []
                return coveringTests
            },
            waveOutcomes: { points in
                [
                    points[0].id: [testA: .failed],
                    points[1].id: [testA: .passed, testB: .passed, testC: .failed],
                    points[2].id: [testA: .passed, testB: .passed]
                ]
            },
            fullSuiteOutcomes: { points in [points[3].id: .passed] }
        )

        // Exactly one result per planned mutant, no duplicates and no drops.
        #expect(report.results.count == 4)
        #expect(Set(report.results.map(\.id)).count == 4)
        #expect(report.integrity.violations.isEmpty)

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .killedByAssertion)
        #expect(sorted[1].outcome == .killedByAssertion)
        #expect(sorted[2].outcome == .survived)
        #expect(sorted[3].outcome == .survived)

        // Batch accounting: unattributed (point 3, 1 configuration) + wave 1
        // (points 0, 1, 2 — 3 configurations) + wave 2 (points 1, 2 — 2
        // configurations, point 0 already dropped) + wave 3 (point 1 only —
        // 1 configuration, point 2 already exhausted-and-survived). Four
        // batches total, one per wave plus the unattributed batch — never
        // one per mutant (which would be 4 mutants × up to 3 tests each).
        let summary = try #require(report.batchExecution)
        #expect(summary.batchCount == 4)
        #expect(summary.totalConfigurations == 7)

        let calls = await adapter.runBatchCalls
        #expect(calls.count == 4)
    }

    @Test(
        """
        Two different mutants sharing the same covering test in the same wave batch, one genuinely failing it and \
        one genuinely passing it, are classified independently from the batch's per-mutant result dictionary
        """
    )
    func sharedTestInSameWaveBatchClassifiesIndependently() async throws {
        let sharedTest = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testShared")

        let (report, adapter, points, _) = try await run(
            count: 2,
            testBatchSize: 10,
            coverage: { points in
                [
                    points[0].file: [
                        points[0].line: [sharedTest],
                        points[1].line: [sharedTest]
                    ]
                ]
            },
            waveOutcomes: { points in
                [
                    points[0].id: [sharedTest: .failed],
                    points[1].id: [sharedTest: .passed]
                ]
            }
        )

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .killedByAssertion, "the mutant whose own run genuinely failed the shared test must be killed")
        #expect(sorted[1].outcome == .survived, "its sibling, whose own run genuinely passed the same shared test, must not be")

        // Both landed in the same single wave-1 batch call.
        let calls = await adapter.runBatchCalls
        #expect(calls.count == 1)
        #expect(Set(calls[0].map(\.id)) == Set(points.map(\.id)))
        #expect(calls[0].allSatisfy { $0.selectedTests == [sharedTest] })
    }

    // MARK: - Native-timeout-vs-batch-attributed standalone-rerun gate (Gate 3 Phase H12.2B)

    @Test(
        """
        A native-XCTest-timeout wave result (isBatchAttributedTimeout=false) skips the redundant standalone \
        rerun and flows straight to timeout confirmation, which — timing out again — verifies the timeout
        """
    )
    func nativeTimeoutSkipsStandaloneRerunAndConfirmsDirectly() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA]]] },
            waveOutcomes: { points in [points[0].id: [testA: .timedOut]] },
            confirmTimedOutMutants: true,
            // Confirmation (the same fake `runMutant` path) times out again —
            // a genuine, reproduced hang.
            unbatchedOverride: { points in [points[0].id: .timedOut] }
            // batchAttributedTimeouts left empty: this mutant's `.timedOut`
            // is the native-XCTest shape (isBatchAttributedTimeout: false).
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .verifiedTimeout)

        // Exactly one individual rerun — the timeout confirmation — never
        // two (which the old, unconditional `run.status == .timedOut` gate
        // would have produced: one redundant standaloneVerify, plus the
        // separate confirmTimedOutMutants confirmation).
        let calls = await adapter.runMutantSelectedTestsCalls
        #expect(calls.count == 1, "expected only the timeout confirmation rerun, no redundant standalone verify, got \(calls.count)")
        #expect(calls == [[testA]])
    }

    @Test(
        """
        A batch-attributed timeout (isBatchAttributedTimeout=true — a whole shared invocation killed, no \
        individual attribution) still gets the mandatory standalone rerun before it is trusted
        """
    )
    func batchAttributedTimeoutStillGetsStandaloneRerun() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (report, adapter, _, _) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA]]] },
            waveOutcomes: { points in [points[0].id: [testA: .timedOut]] },
            confirmTimedOutMutants: true,
            // Both the standalone rerun and the subsequent timeout
            // confirmation go through this same fake `runMutant` path —
            // scripted to time out again both times, a genuine reproduced
            // hang either way.
            unbatchedOverride: { points in [points[0].id: .timedOut] },
            batchAttributedTimeouts: { points in [points[0].id] }
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .verifiedTimeout)

        // Two individual reruns: the mandatory standalone rerun (this
        // mutant's own timeout was never individually attributed by the
        // batch itself, so it must be re-established first) plus the
        // separate timeout confirmation.
        let calls = await adapter.runMutantSelectedTestsCalls
        #expect(calls.count == 2, "expected both the standalone rerun and the timeout confirmation, got \(calls.count)")
        #expect(calls == [[testA], [testA]])
    }

    @Test("A native-XCTest timeout whose confirmation genuinely passes is downgraded to flaky, same as before this phase")
    func nativeTimeoutConfirmationPassingIsFlaky() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (report, adapter, _, priorityStoreURL) = try await run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA]]] },
            waveOutcomes: { points in [points[0].id: [testA: .timedOut]] },
            confirmTimedOutMutants: true,
            // Confirmation does NOT reproduce the timeout — a flake, not a
            // real hang. `MutationVerdictVerifier.confirmTimeout` already
            // requires `isBatchAttributedTimeout == true` before crediting a
            // non-reproducing confirmation as a trusted kill — for the
            // native (false) case this must stay `.flaky` exactly as it did
            // before this phase's change, since that verifier rule is
            // untouched.
            unbatchedOverride: { points in [points[0].id: .passed] }
        )

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .flaky)

        // Still only one individual rerun (the confirmation) — the native
        // path's redundant-rerun removal applies regardless of how the
        // confirmation itself turns out.
        let calls = await adapter.runMutantSelectedTestsCalls
        #expect(calls.count == 1)

        let detections = persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == nil, "a flaky-confirmed result must not be recorded as a detection")
    }

    @Test("Sibling mutants in the same wave chunk are unaffected by one mutant's native-timeout fast path")
    func siblingMutantsUnaffectedByNativeTimeoutFastPath() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let (report, adapter, _, _) = try await run(
            count: 2,
            testBatchSize: 10,
            // Both points land in the same generated file (`writeMutantProject`
            // puts every field on its own line of one `W.swift`) — one
            // top-level key with both lines, not two entries for the same
            // file, which would crash as a duplicate dictionary key.
            coverage: { points in
                [points[0].file: [points[0].line: [testA], points[1].line: [testA]]]
            },
            waveOutcomes: { points in
                [
                    points[0].id: [testA: .timedOut],
                    points[1].id: [testA: .passed]
                ]
            },
            confirmTimedOutMutants: true,
            unbatchedOverride: { points in [points[0].id: .timedOut] }
        )

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .verifiedTimeout)
        #expect(sorted[1].outcome == .survived)

        // Only the timed-out mutant triggers any individual rerun — its
        // passing sibling, sharing the same wave batch, is untouched by the
        // native-timeout fast path.
        let calls = await adapter.runMutantSelectedTestsCalls
        #expect(calls.count == 1)
        #expect(calls == [[testA]])
    }
}

// MARK: - Fakes

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: workspace.appendingPathComponent("baseline.xctestrun"),
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash-\(mutation.point.id.rawValue)",
            xctestrunPath: workspace.appendingPathComponent("mutant.xctestrun"),
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// A manually-advanced monotonic clock shared between a `MutationRunner`
/// under test and its `SpyWaveAdapter`, so a wave's simulated duration is an
/// exact, deterministic quantity — advanced synchronously by `advance(by:)`
/// — rather than `Task.sleep`'s real elapsed wall-clock time, which
/// full-suite CPU contention from unrelated concurrently-running tests can
/// inflate past a budget boundary the test never intended to cross. Returns
/// a plain elapsed-seconds `TimeInterval`, matching `MutationRunner`'s
/// `monotonicNow`, not a wall-clock `Date`.
private final class ManualClock: @unchecked Sendable {
    private var elapsed: TimeInterval = 0
    private let lock = NSLock()

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        elapsed += seconds
        lock.unlock()
    }
}

/// Fakes a batched adapter for the wave loop. Every wave item carries
/// exactly one selected test (`testInWaves` always narrows to the
/// survivor's next test), so an outcome is looked up by `(mutant, that one
/// test)`. Unattributed items carry `selectedTests == nil` (the full
/// configured list) and are looked up in `fullSuiteOutcomes` instead.
/// Anything not scripted defaults to `.passed`, so a test only needs to
/// specify the outcomes it cares about.
private actor SpyWaveAdapter: TestSelecting, BatchTestable {
    private let perTestCoverage: PerTestCoverageMap?
    private let waveOutcomes: [MutationID: [TestIdentifier: TestRunStatus]]
    private let fullSuiteOutcomes: [MutationID: TestRunStatus]
    /// Artificial per-`runBatch`-call delay, so a test can make cumulative
    /// wave duration a known, controllable quantity instead of whatever a
    /// near-instant synchronous call happens to measure. Realized by
    /// advancing `clock` (shared with the `MutationRunner` under test) by
    /// exactly this amount, never by a real `Task.sleep` — see `clock`.
    private let waveDurationSeconds: Double
    /// The same manually-advanced clock passed to `MutationRunner`. Advancing
    /// it here, instead of sleeping for real time, is what makes this
    /// adapter's simulated wave duration exact rather than merely
    /// approximate: the runner reads "now" from this same clock immediately
    /// before and after `runBatch`, so the measured duration is exactly
    /// `waveDurationSeconds`, unaffected by how long this process actually
    /// took to get scheduled.
    private let clock: ManualClock?
    /// What a mutant's unbatched `runMutant(selectedTests:)` call reports,
    /// when present — this path is only ever reached by a confirmation rerun
    /// or a standalone ground-truth verification, never by a wave's own test
    /// (which always goes through `runBatch`), so this simulates that rerun
    /// disagreeing with the mutant's original wave-batch result, the way a
    /// genuinely flaky test would.
    private let unbatchedOverride: [MutationID: TestRunStatus]
    /// Gate 3 Phase H12.2B: mutants whose wave `.timedOut` result should
    /// carry `isBatchAttributedTimeout: true`. Absent from this set (the
    /// default for every mutant) means the native-XCTest-timeout shape —
    /// `false`, this one configuration individually identified.
    private let batchAttributedTimeouts: Set<MutationID>
    private(set) var runBatchCalls: [[BatchMutantItem]] = []
    private(set) var runBatchTimeouts: [Double] = []
    private(set) var runBatchNativeTimeoutAllowances: [Double?] = []
    private(set) var runMutantSelectedTestsCalls: [Set<TestIdentifier>?] = []

    init(
        perTestCoverage: PerTestCoverageMap?,
        waveOutcomes: [MutationID: [TestIdentifier: TestRunStatus]] = [:],
        fullSuiteOutcomes: [MutationID: TestRunStatus] = [:],
        waveDurationSeconds: Double = 0,
        unbatchedOverride: [MutationID: TestRunStatus] = [:],
        batchAttributedTimeouts: Set<MutationID> = [],
        clock: ManualClock? = nil
    ) {
        self.perTestCoverage = perTestCoverage
        self.waveOutcomes = waveOutcomes
        self.fullSuiteOutcomes = fullSuiteOutcomes
        self.waveDurationSeconds = waveDurationSeconds
        self.unbatchedOverride = unbatchedOverride
        self.batchAttributedTimeouts = batchAttributedTimeouts
        self.clock = clock
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        perTestCoverage
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        runMutantSelectedTestsCalls.append(selectedTests)
        if let override = unbatchedOverride[point.id] {
            return Self.result(override)
        }
        let status = selectedTests?.first.flatMap { waveOutcomes[point.id]?[$0] } ?? .failed
        return Self.result(status)
    }

    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        runBatchCalls.append(items)
        runBatchTimeouts.append(timeoutSeconds)
        runBatchNativeTimeoutAllowances.append(nativeTimeoutAllowanceSeconds)
        if waveDurationSeconds > 0 {
            if let clock {
                clock.advance(by: waveDurationSeconds)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(waveDurationSeconds * 1_000_000_000))
            }
        }

        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            let isBatchAttributedTimeout = batchAttributedTimeouts.contains(item.id)
            if let tests = item.selectedTests, let single = tests.first, tests.count == 1 {
                let status = waveOutcomes[item.id]?[single] ?? .passed
                results[item.id] = Self.result(status, isBatchAttributedTimeout: isBatchAttributedTimeout)
            } else {
                let status = fullSuiteOutcomes[item.id] ?? .passed
                results[item.id] = Self.result(status, isBatchAttributedTimeout: isBatchAttributedTimeout)
            }
        }
        return results
    }

    private static func result(_ status: TestRunStatus, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "xcodebuild", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }
}
