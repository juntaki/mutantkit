import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// F3: deterministic ownership regressions for `ProcessSupervisor`. Every
/// scenario here synchronizes with a real readiness handshake
/// (`ProcessSupervisorOwnershipFixture`), never a `sleep`/retry-based guess
/// at whether a race resolved favorably.
@Suite("ProcessSupervisor: deterministic descendant ownership (F3)", .serialized, .subprocessExclusive)
struct ProcessSupervisorOwnershipTests {
    private func isAlive(_ pid: pid_t) -> Bool {
        ProcessTree.isAlive(pid)
    }

    private func cleanup(_ pid: pid_t) {
        if isAlive(pid) { kill(pid, SIGKILL) }
    }

    @Test("A child that stays alive after its root exits promptly is still owned and reaped")
    func fastParentExitChildIsOwned() async throws {
        let outcome = try await ProcessSupervisorOwnershipFixture.runFastParentExit()
        defer { cleanup(outcome.descendantPID) }

        #expect(!isAlive(outcome.descendantPID), "the child must be reaped even though root exited before the test could observe it")
    }

    /// Not the primary proof (that's the single-shot test above, and the
    /// `swift build -c release` production audit) -- this exists purely to
    /// check whether the same scenario, run under genuine machine
    /// contention (the shape the pre-F3 flaky test's own doc comment
    /// attributes its historical misses to: "reproduced locally too,
    /// deterministically, by adding artificial CPU oversubscription"),
    /// still holds. Runs `iterations` fixture instances concurrently, on
    /// purpose, to create real core contention on this machine, rather than
    /// hoping a sequential loop happens to reproduce it.
    @Test("Stress: many concurrent fast-parent-exit races under real contention are all owned")
    func fastParentExitUnderConcurrentContention() async throws {
        let iterations = 20
        let outcomes = try await withThrowingTaskGroup(of: ProcessSupervisorOwnershipFixture.FastExitResult.self) { group in
            for _ in 0 ..< iterations {
                group.addTask { try await ProcessSupervisorOwnershipFixture.runFastParentExit() }
            }
            var collected: [ProcessSupervisorOwnershipFixture.FastExitResult] = []
            for try await outcome in group { collected.append(outcome) }
            return collected
        }
        defer { for outcome in outcomes { cleanup(outcome.descendantPID) } }

        let survivors = outcomes.map(\.descendantPID).filter { isAlive($0) }
        #expect(survivors.isEmpty, "\(survivors.count) of \(iterations) children under concurrent contention were not reaped: \(survivors)")
    }

    @Test("A grandchild that stays alive after root exits promptly is owned along with its parent")
    func fastParentExitGrandchildIsOwned() async throws {
        let outcome = try await ProcessSupervisorOwnershipFixture.runFastParentExitWithGrandchild()
        let grandchildPID = try #require(outcome.grandchildPID)
        defer {
            cleanup(outcome.descendantPID)
            cleanup(grandchildPID)
        }

        #expect(!isAlive(outcome.descendantPID), "the child must be reaped")
        #expect(!isAlive(grandchildPID), "the grandchild must be reaped along with its own parent")
    }

    @Test("Stress: many concurrent fast-parent-exit races with a grandchild under real contention are all owned")
    func fastParentExitGrandchildUnderConcurrentContention() async throws {
        let iterations = 20
        let outcomes = try await withThrowingTaskGroup(of: ProcessSupervisorOwnershipFixture.FastExitResult.self) { group in
            for _ in 0 ..< iterations {
                group.addTask { try await ProcessSupervisorOwnershipFixture.runFastParentExitWithGrandchild() }
            }
            var collected: [ProcessSupervisorOwnershipFixture.FastExitResult] = []
            for try await outcome in group { collected.append(outcome) }
            return collected
        }
        defer {
            for outcome in outcomes {
                cleanup(outcome.descendantPID)
                if let grandchildPID = outcome.grandchildPID { cleanup(grandchildPID) }
            }
        }

        let allDescendants = outcomes.flatMap { [$0.descendantPID] + ($0.grandchildPID.map { [$0] } ?? []) }
        let survivors = allDescendants.filter { isAlive($0) }
        #expect(survivors.isEmpty, "\(survivors.count) of \(allDescendants.count) descendants under concurrent contention were not reaped: \(survivors)")
    }

    @Test("An unrelated process with the same executable/argument shape as a supervised descendant survives supervision")
    func unrelatedBystanderProcessSurvives() async throws {
        let (bystanderPID, release) = try ProcessSupervisorOwnershipFixture.spawnUnrelatedBystander()
        defer { release() }

        // Run several fast-parent-exit races (the exact scenario that
        // triggers this codebase's own descendant-reaping machinery) while
        // the bystander is alive, to prove reaping is provenance-based
        // (PID + start time, positively established while the supervised
        // process was alive), never a name/argument-shape match that could
        // ever confuse it for one of ours.
        for _ in 0 ..< 5 {
            let outcome = try await ProcessSupervisorOwnershipFixture.runFastParentExit()
            defer { cleanup(outcome.descendantPID) }
            #expect(!isAlive(outcome.descendantPID))
        }

        #expect(isAlive(bystanderPID), "an unrelated process must never be affected by supervising unrelated descendants")
    }

    @Test("A child ignoring SIGTERM is escalated to SIGKILL only after the configured grace period, without stall detection involved")
    func sigtermIgnoringChildEscalatesToSIGKILL() async throws {
        let started = Date()
        let outcome = try await ProcessSupervisorOwnershipFixture.runIgnoringSIGTERM(
            timeoutSeconds: 1, terminationGracePeriodSeconds: 2
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome.processResult.timedOut)
        #expect(outcome.processResult.terminatingSignal == SIGKILL)
        #expect(elapsed >= 1 + 2, "the grace period must actually elapse before escalation — \(elapsed)s")
        #expect(!isAlive(outcome.descendantPID), "the SIGTERM-ignoring child must still be gone after SIGKILL escalation")
    }

    // MARK: - Task cancellation (F3 Phase 8)

    @Test("Cancelling the calling Task tears down the owned process tree and rethrows CancellationError, never returning a ProcessResult")
    func taskCancellationTearsDownOwnedTree() async throws {
        let (task, readyPath) = ProcessSupervisorOwnershipFixture.runLongRunningWithChild()
        let childPID = try ProcessSupervisorOwnershipFixture.waitForReadyFile(at: readyPath)
        defer { cleanup(childPID) }

        // The child is now positively confirmed alive and blocked -- only
        // now does cancellation actually mean something for this test.
        #expect(isAlive(childPID))

        task.cancel()

        var thrown: Error?
        do {
            _ = try await task.value
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError, "expected CancellationError, got \(String(describing: thrown))")
        #expect(!isAlive(childPID), "the owned child must be torn down as part of cancellation, not left running")
    }

    @Test("Stress: many concurrent Task cancellations each tear down their own owned tree, never affecting a sibling's")
    func manyConcurrentTaskCancellationsEachTearDownTheirOwnTree() async throws {
        let iterations = 6
        struct Started { let task: Task<ProcessResult, Error>; let childPID: pid_t }

        // All `iterations` roots are launched first, concurrently, before
        // any readiness wait -- waiting for each in turn before launching
        // the next would serialize their startup and needlessly extend how
        // long earlier roots sit idle while later ones are still forking.
        let launches = (0 ..< iterations).map { _ in ProcessSupervisorOwnershipFixture.runLongRunningWithChild() }
        var started: [Started] = []
        for (task, readyPath) in launches {
            let childPID = try ProcessSupervisorOwnershipFixture.waitForReadyFile(at: readyPath, timeoutSeconds: 30)
            started.append(Started(task: task, childPID: childPID))
        }
        defer { for entry in started { cleanup(entry.childPID) } }

        for entry in started { entry.task.cancel() }

        for entry in started {
            var thrown: Error?
            do {
                _ = try await entry.task.value
            } catch {
                thrown = error
            }
            #expect(thrown is CancellationError)
        }

        let survivors = started.map(\.childPID).filter { isAlive($0) }
        #expect(survivors.isEmpty, "\(survivors.count) of \(iterations) cancelled runs left an owned child behind: \(survivors)")
    }
}
