import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// The control run is shared by every kill with the same selection, so the extra
/// cost is one execution per distinct selection rather than one per kill.
@Suite("Baseline control sharing")
struct BaselineControlMemoTests {
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    @Test("Concurrent kills with the same selection share one control run; a different selection runs its own")
    func sameKeyRunsOnce() async {
        let memo = BaselineControlMemo()
        let counter = Counter()
        let produced = makePassingBaselineControl()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    _ = await memo.observation(key: "whole-suite") {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        return produced
                    }
                }
            }
        }
        #expect(await counter.count == 1)
        _ = await memo.observation(key: "A") {
            await counter.increment()
            return produced
        }
        #expect(await counter.count == 2)
        #expect(await memo.startedCount == 2)
    }

    private func control(status: TestRunStatus) -> BaselineControlObservation {
        BaselineControlObservation(
            method: .unmutatedBuildProducts,
            run: TestRunResult(
                status: status, summary: status == .passed ? makeTestSummary() : nil,
                command: CommandRecord(executable: "", arguments: [], workingDirectory: ""),
                resultArtifactPath: nil, diagnosis: "control"
            ),
            selectedTests: nil
        )
    }

    @Test("A control that could not be established is retried on the next request, not kept for the run")
    func transientFailureIsRetried() async {
        let memo = BaselineControlMemo()
        let counter = Counter()
        func request() async -> BaselineControlObservation {
            await memo.observation(key: "whole-suite") {
                await counter.increment()
                return await counter.count == 1 ? self.control(status: .infrastructureFailure) : self.control(status: .passed)
            }
        }
        let first = await request()
        #expect(first.run.status == .infrastructureFailure)
        let second = await request()
        #expect(second.run.status == .passed)
        // A good control is then shared as before.
        _ = await request()
        #expect(await counter.count == 2)
    }

    @Test("Retries are bounded; the last observation then stands")
    func retriesAreBounded() async {
        let memo = BaselineControlMemo()
        let counter = Counter()
        for _ in 0 ..< 6 {
            _ = await memo.observation(key: "k") {
                await counter.increment()
                return self.control(status: .timedOut)
            }
        }
        #expect(await counter.count == BaselineControlMemo.maximumAttempts)
        #expect(await memo.startedCount == BaselineControlMemo.maximumAttempts)
    }

    @Test("A crash or a failing control is a result and is kept")
    func definiteResultsAreKept() async {
        for status in [TestRunStatus.crashed, .failed] {
            let memo = BaselineControlMemo()
            let counter = Counter()
            for _ in 0 ..< 3 {
                _ = await memo.observation(key: "k") {
                    await counter.increment()
                    return self.control(status: status)
                }
            }
            #expect(await counter.count == 1)
        }
    }
}
