import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Wave-based early kill (see `MutationRunnerWaveEarlyKillTests`): evidence,
/// batch timeouts, native timeout containment and cumulative budget handling.
@Suite("Mutation runner: wave-based early kill, timeouts and budgets")
struct MutationRunnerWaveEarlyKillTimeoutTests {
    private let fixture = WaveEarlyKillFixture()

    /// Codex review finding on this branch: an exhausted (survived) or
    /// budget-expired mutant's synthesized final result reported the build
    /// artifact's command as `evidence.testCommand`, discarding the actual
    /// test command/result-artifact evidence its real wave tests produced.
    @Test("A survived mutant's evidence carries its real last test command, not the build command")
    func survivedMutantReportsRealTestCommand() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed]] }
        )
        let report = outcome.report

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

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed]] },
            mutantTimeoutSeconds: 10,
            waveDurationSeconds: 3
        )
        let adapter = outcome.adapter

        let timeouts = await adapter.runBatchTimeouts
        // `#require`, not `#expect`: observed to crash the whole test
        // process (unguarded `timeouts[0]`/`timeouts[1]` below trapping)
        // under severe machine contention. Fail cleanly instead.
        try #require(timeouts.count == 2)
        // A fixed 10s mutant timeout (`mutantTimeoutSeconds: 10` above) —
        // `TimeoutController.mutantLimitSeconds(selectedTests:)` no longer
        // narrows by selection size (that was found uncalibrated for
        // real Xcode/Simulator overhead; see its own doc comment), so this
        // test pins a small budget directly instead.
        // Wave 1: nothing spent yet, so the fresh 10s budget.
        #expect(timeouts[0] == 10)
        // Wave 2: already spent 3s of it in wave 1, so this wave's timeout
        // must reflect the budget already spent (10 - 3 = 7), not the same
        // 10s value repeated.
        #expect(timeouts[1] == 7, "expected wave 2's timeout to reflect the budget already spent, got \(timeouts[1])")
    }

    // MARK: - Native XCTest timeout containment

    /// A chunk with more than one member is exactly the case native
    /// containment exists for: the outer `batchTimeout` above
    /// stays a shared, ambiguous fail-safe across every member, so this is
    /// where XCTest's own per-test allowance is asked to localize a hang to
    /// just the one member that has it.
    @Test("A multi-member wave chunk's batch call requests native timeout containment, sized from the resolved mutant limit")
    func nativeTimeoutAllowanceIsSetForMultiMemberWaveChunksAboveTheFloor() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let outcome = try await fixture.run(
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
        let adapter = outcome.adapter

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

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .passed, testB: .passed]] },
            mutantTimeoutSeconds: 90
        )
        let adapter = outcome.adapter

        let allowances = await adapter.runBatchNativeTimeoutAllowances
        #expect(allowances == [nil, nil])
    }

    /// The validation only ever exercised a 60s allowance against a real
    /// hang — a resolved mutant limit below that has no evidence behind it,
    /// so containment is skipped rather than risking a false-positive
    /// timeout from Xcode/Simulator's own per-invocation startup overhead.
    /// The outer `batchTimeout` alone still applies, exactly as before this
    /// phase.
    @Test("A multi-member wave chunk below the validated floor does not request native timeout containment")
    func nativeTimeoutAllowanceIsNilBelowThePhaseH1Floor() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let outcome = try await fixture.run(
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
        let adapter = outcome.adapter

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

        let outcome = try await fixture.run(
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
            // longer narrows by selection size (that was found
            // uncalibrated for real Xcode/Simulator overhead; see its own
            // doc comment), so this test pins the budget directly instead.
            // A real, controllable per-wave duration of 8s: after wave 1
            // cumulative (8s) is under the 15s budget, so wave 2 runs; after
            // wave 2 (16s) it's over budget, so wave 3 never happens — the
            // standalone verification below runs instead.
            mutantTimeoutSeconds: 15,
            waveDurationSeconds: 8
        )
        let report = outcome.report
        let adapter = outcome.adapter

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

        let outcome = try await fixture.run(
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
        let report = outcome.report

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

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            // Two covering tests — if confirmation used the whole original
            // selection instead of narrowing to the winner, the individual
            // confirmation call would be given both, not one.
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .failed]] },
            retestKilledMutants: true
        )
        let report = outcome.report
        let adapter = outcome.adapter

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        let confirmationCalls = await adapter.runMutantSelectedTestsCalls
        #expect(confirmationCalls.count == 2, "one individual confirmation and one baseline control, not through runBatch")
        #expect(confirmationCalls[0] == [testA], "confirmation must rerun only the test that produced the detection")
        #expect(confirmationCalls[1] == [testA], "the baseline control must run the same narrowed selection")
    }
}
