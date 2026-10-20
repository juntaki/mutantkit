import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Wave-based early kill (see `MutationRunnerWaveEarlyKillTests`): batch
/// composition, kill-priority accounting and the native-timeout fast path.
@Suite("Mutation runner: wave-based early kill, batching and detection accounting")
struct MutationRunnerWaveEarlyKillAccountingTests {
    private let fixture = WaveEarlyKillFixture()

    /// Real-world regression, the same one `testAndFinish` was fixed for:
    /// bundling several unattributed (full-suite-fallback) mutants into one
    /// shared batch multiplies their cost rather than sharing it, which can
    /// exceed even a generously per-mutant-sized timeout and mark every
    /// mutant in that batch unprovable together.
    @Test("Multiple unattributed mutants are never bundled into the same batch")
    func multipleUnattributedMutantsGetSeparateBatches() async throws {
        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter
        let points = outcome.points

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

        let outcome = try await fixture.run(
            count: 1,
            testBatchSize: 10,
            coverage: { points in [points[0].file: [points[0].line: [testA, testB]]] },
            waveOutcomes: { points in [points[0].id: [testA: .infrastructureFailure]] }
        )
        let report = outcome.report
        let priorityStoreURL = outcome.priorityStoreURL

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .infrastructureFailure)

        // An infrastructure failure proves nothing about whether testA is
        // any good at catching mutants — it must not be credited. Mirrors
        // `PrioritizingTestAdapter.runMutant`'s identical
        // `.passed, .infrastructureFailure: break` distinction.
        let detections = fixture.persistedDetections(at: priorityStoreURL)
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

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let priorityStoreURL = outcome.priorityStoreURL

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .killedByAssertion)

        let detections = fixture.persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == 1, "the real, standalone-verified kill must be credited")
    }

    @Test("A wave detection that confirmation downgrades to flaky does not credit the test's kill-priority history")
    func flakyConfirmationDoesNotRecordDetection() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let priorityStoreURL = outcome.priorityStoreURL

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .flaky)

        // The wave's raw result looked like a detection, but the *final*,
        // confirmed outcome is `.flaky` — crediting testA's kill-priority
        // history from the raw wave result (as opposed to the final,
        // confirmed outcome) would corrupt the learned ordering with a
        // result that did not hold up. This is the exact case the review
        // that found this bug described: crediting on the raw wave status
        // instead of waiting for `finishAfterTest`'s confirmation to settle.
        let detections = fixture.persistedDetections(at: priorityStoreURL)
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
        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter

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

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter
        let points = outcome.points

        let sorted = report.results.sorted { $0.id < $1.id }
        #expect(sorted[0].outcome == .killedByAssertion, "the mutant whose own run genuinely failed the shared test must be killed")
        #expect(sorted[1].outcome == .survived, "its sibling, whose own run genuinely passed the same shared test, must not be")

        // Both landed in the same single wave-1 batch call.
        let calls = await adapter.runBatchCalls
        #expect(calls.count == 1)
        #expect(Set(calls[0].map(\.id)) == Set(points.map(\.id)))
        #expect(calls[0].allSatisfy { $0.selectedTests == [sharedTest] })
    }

    // MARK: - Native-timeout-vs-batch-attributed standalone-rerun gate

    @Test(
        """
        A native-XCTest-timeout wave result (isBatchAttributedTimeout=false) skips the redundant standalone \
        rerun and flows straight to timeout confirmation, which — timing out again — verifies the timeout
        """
    )
    func nativeTimeoutSkipsStandaloneRerunAndConfirmsDirectly() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter

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

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter

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

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter
        let priorityStoreURL = outcome.priorityStoreURL

        #expect(report.results.count == 1)
        #expect(report.results[0].outcome == .flaky)

        // Still only one individual rerun (the confirmation) — the native
        // path's redundant-rerun removal applies regardless of how the
        // confirmation itself turns out.
        let calls = await adapter.runMutantSelectedTestsCalls
        #expect(calls.count == 1)

        let detections = fixture.persistedDetections(at: priorityStoreURL)
        #expect(detections[testA.onlyTestingArgument] == nil, "a flaky-confirmed result must not be recorded as a detection")
    }

    @Test("Sibling mutants in the same wave chunk are unaffected by one mutant's native-timeout fast path")
    func siblingMutantsUnaffectedByNativeTimeoutFastPath() async throws {
        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")

        let outcome = try await fixture.run(
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
        let report = outcome.report
        let adapter = outcome.adapter

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
