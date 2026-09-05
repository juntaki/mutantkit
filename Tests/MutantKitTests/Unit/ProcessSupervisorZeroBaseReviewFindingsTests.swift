import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// F3 zero-base review (HEAD `08e8b019a176646c2f5bb42300f562ba1c9dc26e`) raised
/// three blocking findings before approval. See the review response report
/// for the full writeup (real `swiftpm-testing-helper` process-tree
/// capture, the `kqueue`/`EVFILT_PROC`/`NOTE_TRACK` bounded spike, and the
/// `waitid(WNOWAIT)` PID-reuse spike).
///
/// Findings 2 and 3 are regression tests here, expected to stay GREEN —
/// both landed a production fix. Finding 1's own permanent RED proof lives
/// separately, excluded from the default suite on purpose: see
/// `Tests/MutantKitTests/Diagnostics
/// /ProcessSupervisorEscapedDescendantOwnershipBoundaryDiagnostic.swift`'s
/// own doc comment for why a documented implementation *boundary* does not
/// belong in the same suite as a *regression* the codebase is expected to
/// keep fixed.
@Suite("F3 zero-base review: blocking findings", .subprocessExclusive)
struct ProcessSupervisorZeroBaseReviewFindingsTests {
    // MARK: - Finding 1: group-escaped descendant ownership boundary (supporting fact)

    /// Independent confirmation of the claim
    /// `EscapedDescendantOwnershipBoundaryDiagnostic
    /// .groupEscapedDescendantIsUnrecoverableAfterZeroObservationWindow`
    /// (see `Tests/MutantKitTests/Diagnostics/`, excluded from the default
    /// suite — see that file's own doc comment for why) depends on:
    /// once root has exited (reaped), the escaped child's own `ppid` is
    /// already `1` (launchd), not root's pid -- reparenting happens at
    /// (or effectively immediately after) the parent's exit, not at the
    /// parent's later reaping. 5 trials, no retry: this is not a timing
    /// race being measured for "how often" -- it is checking whether the
    /// fact ever fails to hold at all.
    @Test("Reparenting to launchd is already complete by the time root has been reaped, every time")
    func reparentingToLaunchdIsAlreadyCompleteTheInstantRootExits() throws {
        for _ in 0 ..< 5 {
            let resultsPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("mkit-zbr-f1-reparent-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: resultsPath) }

            let script = """
            import os, time
            pid = os.fork()
            if pid == 0:
                os.setpgid(0, 0)
                with open(\(pythonLiteral(resultsPath)) + ".tmp", "w") as f:
                    f.write(str(os.getpid()))
                os.rename(\(pythonLiteral(resultsPath)) + ".tmp", \(pythonLiteral(resultsPath)))
                time.sleep(1.0)
                os._exit(0)
            else:
                os._exit(0)
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            let childPID = try waitForResultsFile(resultsPath)
            defer { if ProcessTree.isAlive(childPID) { kill(childPID, SIGKILL) } }

            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, childPID]
            let rc = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
            #expect(rc == 0, "could not read the child's own process-table entry")
            #expect(
                info.kp_eproc.e_ppid == 1,
                """
                the escaped child's ppid must already be launchd (1), confirming reparenting happens at root's exit, \
                not at root's later reaping
                """
            )
        }
    }

    // MARK: - Finding 2: PID-reuse safety (deterministic event-ordering, not forced reuse)

    /// F3 zero-base review Finding 2. Forcing an *actual* PID-reuse
    /// collision on demand is not something any portable API can do —
    /// no syscall lets a caller request a specific PID from the kernel —
    /// so this proves the actual safety property instead: every `-pid`
    /// process-group signal `ProcessSupervisor` ever sends for a given
    /// `pid` happens strictly before that `pid`'s own final, consuming
    /// reap (`waitpid`) — the reap that is the only thing that ever makes
    /// `pid` recyclable. If that ordering always holds, no group signal
    /// can ever reach a process the kernel has since reassigned that same
    /// numeric pid to, regardless of how fast or slow real PID recycling
    /// happens to be on any given machine.
    ///
    /// Passes a `lifecycleEventHook` (see `ProcessSupervisor.LifecycleEvent`'s
    /// own doc comment — a per-invocation closure threaded through
    /// `SupervisionPolicy`, never process-global mutable state, so this
    /// test's own log cannot be corrupted by, or corrupt, any concurrently
    /// running `ProcessSupervisor` invocation elsewhere in the binary) to
    /// record every `.groupSignal`/`.finalReap` event this one invocation
    /// emits — real production code paths, not simulated. Still grouped by
    /// `pid` below regardless, since a hook only ever observes its own
    /// invocation's events anyway, matching how `runBlocking` itself never
    /// mixes pids within a single run.
    ///
    /// Drives `ProcessSupervisorOwnershipFixture.runIgnoringSIGTERM` (Mode
    /// D) specifically because it is the one existing fixture guaranteed to
    /// produce *both* a TERM and a KILL `.groupSignal` event for the same
    /// pid (a SIGTERM-ignoring child forces the full TERM -> grace -> KILL
    /// escalation) — the richest ordering this invariant could actually be
    /// violated by, not just the single-TERM common case.
    @Test("No -pid process-group signal is ever sent after that pid's own final reap")
    func noGroupSignalEverFollowsThatPidsFinalReap() async throws {
        final class EventLog: @unchecked Sendable {
            private var events: [ProcessSupervisor.LifecycleEvent] = []
            private let lock = NSLock()
            func record(_ event: ProcessSupervisor.LifecycleEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            var snapshot: [ProcessSupervisor.LifecycleEvent] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }
        }

        let log = EventLog()

        // `timeoutSeconds` was 1. It is the fixture child's entire budget for
        // interpreter startup as well as announcing its pid (see
        // `runIgnoringSIGTERM`'s own comment), and under a full-suite run
        // python3 startup intermittently lost that race on unmodified `main`,
        // failing this test with a setup error rather than a real finding.
        // Nothing here measures the timeout's value — the assertions below
        // are about signal *ordering* — so widening it costs one extra second
        // of runtime and removes the race entirely.
        let outcome = try await ProcessSupervisorOwnershipFixture.runIgnoringSIGTERM(
            timeoutSeconds: 5, terminationGracePeriodSeconds: 1,
            lifecycleEventHook: { log.record($0) }
        )
        defer { if ProcessTree.isAlive(outcome.descendantPID) { kill(outcome.descendantPID, SIGKILL) } }

        #expect(outcome.processResult.timedOut)
        #expect(outcome.processResult.terminatingSignal == SIGKILL)

        let events = log.snapshot
        var pidsWithSignalsAfterTheirOwnReap: Set<pid_t> = []
        var sawGroupSignal = false
        var sawFinalReap = false
        var reapedPids: Set<pid_t> = []
        for event in events {
            switch event {
            case let .groupSignal(pid, _):
                sawGroupSignal = true
                if reapedPids.contains(pid) { pidsWithSignalsAfterTheirOwnReap.insert(pid) }
            case let .finalReap(pid):
                sawFinalReap = true
                reapedPids.insert(pid)
            }
        }

        #expect(sawGroupSignal, "this scenario must exercise at least one group signal for the assertion below to mean anything")
        #expect(sawFinalReap, "this scenario must exercise at least one final reap for the assertion below to mean anything")
        #expect(
            pidsWithSignalsAfterTheirOwnReap.isEmpty,
            """
            a -pid group signal was sent for a pid after that same pid's own final reap: \
            \(pidsWithSignalsAfterTheirOwnReap) -- events: \(events)
            """
        )
    }

    // MARK: - Finding 3: cancellation after root has already exited

    /// F3 zero-base review Finding 3, made deterministic via
    /// `CancellationAfterRootExitFixture`'s real-fact polling (never a
    /// sleep guess) for "root has already exited and been reaped by the
    /// supervisor's own `wait(for:policy:)`." Cancellation is issued only
    /// after that fact is confirmed, landing the cancellation squarely in
    /// `runBlocking`'s post-exit drain wait -- a window
    /// `cancellationFlag` is never consulted in today.
    ///
    /// The contract this pins: cancellation must trigger the *same*
    /// SIGTERM -> grace -> SIGKILL escalation a timeout already uses,
    /// bounded by `terminationGracePeriodSeconds` (set to 1s here) --
    /// **not** silently fall back to waiting out the passive post-exit
    /// drain window (`drainGracePeriodSeconds` = 5s, plus a further
    /// unconditional 2s second-wait in the current ownership-close-out
    /// code = up to ~7s), which is what actually happens today because
    /// nothing after `wait(for:policy:)` returns ever checks
    /// `cancellationFlag` again.
    ///
    /// `elapsed < 4` is the RED assertion: comfortably above what a
    /// correct 1s-grace escalation should take even under real scheduling
    /// jitter, comfortably below the ~7s the current unconditional,
    /// cancellation-blind drain wait actually takes. This is a real,
    /// documented timeout boundary being measured (`terminationGracePeriodSeconds`),
    /// the same class of assertion `ProcessSupervisorOwnershipTests
    /// .sigtermIgnoringChildEscalatesToSIGKILL`'s own `elapsed >= 1 + 2`
    /// already makes -- not a race being hidden behind a stopwatch.
    @Test("Cancelling after root has already exited must trigger prompt owned-tree escalation, not wait out the passive drain window")
    func cancellationAfterRootExitEscalatesPromptlyRatherThanWaitingOutTheDrain() async throws {
        let started = try CancellationAfterRootExitFixture.startAndWaitUntilRootHasExited(
            terminationGracePeriodSeconds: 1
        )
        defer { if ProcessTree.isAlive(started.childPID) { kill(started.childPID, SIGKILL) } }

        // Root is now confirmed gone (fact-polled, not guessed) -- the
        // supervisor is inside, or about to enter, the post-exit drain.
        #expect(
            ProcessTree.isAlive(started.childPID),
            "the descendant holding the pipe must still be alive at the moment of cancellation for this to test anything"
        )

        let cancelledAt = Date()
        started.task.cancel()

        var thrown: Error?
        do {
            _ = try await started.task.value
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(cancelledAt)

        #expect(thrown is CancellationError, "expected CancellationError, got \(String(describing: thrown))")
        #expect(
            elapsed < 4,
            """
            cancellation after root's exit took \(elapsed)s -- a correct implementation escalates the owned tree \
            within terminationGracePeriodSeconds (1s here); ~7s means cancellation was never observed and the \
            passive drain window ran to completion instead
            """
        )
        #expect(
            !ProcessTree.isAlive(started.childPID),
            "the descendant holding the pipe must be torn down as part of cancellation, not left running"
        )
    }

    // MARK: - Satisfiable positive invariant: the root process itself is always reaped

    /// One of the small set of *satisfiable* ownership invariants F3's own
    /// zero-base review asked to keep in the default suite regardless of
    /// Finding 1's own, separately-scoped boundary (the root process
    /// itself is never the thing that boundary is about — only a
    /// descendant that both escapes its process group *and* forks within
    /// the same instant the root exits is): whatever else happens, the
    /// one process `ProcessSupervisor.run` itself spawned is always fully
    /// reaped by the time it returns — not merely killed, not left as an
    /// unreaped zombie holding its own pid reserved forever.
    ///
    /// Real-fact checked, not inferred from `ProcessResult` alone: root
    /// announces its own pid via the same handshake-file convention every
    /// other fixture here uses, and the test independently confirms — via
    /// a second, non-consuming `waitid(..., WNOWAIT)` peek of its own,
    /// mirroring production's own `ProcessSupervisor.hasExited` — that the
    /// pid no longer refers to *any* process at all (not even a zombie)
    /// once `run` has returned.
    @Test("The supervised root process itself is always fully reaped by the time run(...) returns")
    func rootProcessIsAlwaysFullyReapedWhenRunReturns() async throws {
        let rootPidPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkit-zbr-root-reaped-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: rootPidPath) }

        let script = """
        import os
        with open(\(pythonLiteral(rootPidPath)) + ".tmp", "w") as f:
            f.write(str(os.getpid()))
        os.rename(\(pythonLiteral(rootPidPath)) + ".tmp", \(pythonLiteral(rootPidPath)))
        """
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        )
        #expect(result.succeeded)

        let rootPID = try waitForResultsFile(rootPidPath)
        var info = siginfo_t()
        info.si_pid = 0
        let rc = waitid(P_PID, id_t(rootPID), &info, WEXITED | WNOHANG | WNOWAIT)
        #expect(
            !(rc == 0 && info.si_pid == rootPID),
            "root's own pid (\(rootPID)) still refers to a live-or-zombie process after run(...) returned -- it was not fully reaped"
        )
    }

    // MARK: - Support

    private func waitForResultsFile(_ path: String, timeoutSeconds: Double = 10) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            usleep(1000)
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw CancellationAfterRootExitFixture.SetupFailure(description: "\(path) never appeared with a readable pid")
        }
        return pid
    }

    private func pythonLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
