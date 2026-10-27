import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// After close-out has sent its group SIGKILL, being unable to verify that
/// every descendant is gone is reported as `cleanupVerified == false`, never
/// returned as an ordinary result, and trips the run's
/// `RunContainmentMonitor`.
@Suite("ProcessSupervisor: post-SIGKILL cleanup verification", .subprocessExclusive)
struct ProcessSupervisorCleanupVerificationTests {
    @Test("An unreadable process table during the SIGKILL branch reports cleanupVerified == false")
    func unreadableTableDuringSigkillIsReportedUnverified() async throws {
        let result = try await UnverifiedCleanupFixture.run()

        #expect(result.timedOut, "the scenario must reach close-out through the timeout")
        #expect(result.cleanupVerified == false)
        let diagnosis = try #require(result.cleanupDiagnosis)
        #expect(diagnosis.contains("SIGKILL"), "diagnosis: \(diagnosis)")
    }

    @Test("The same SIGKILL escalation against a readable table is verified")
    func readableTableAfterSigkillIsVerified() async throws {
        let result = try await UnverifiedCleanupFixture.run(injectFault: false)

        #expect(result.timedOut)
        #expect(result.terminatingSignal == SIGKILL, "the control must exercise the SIGKILL branch too")
        #expect(result.cleanupVerified)
        #expect(result.cleanupDiagnosis == nil)
    }

    @Test("ProcessSupervisor records an unverified cleanup in the bound RunContainmentMonitor")
    func unverifiedCleanupTripsTheBoundMonitor() async throws {
        let monitor = RunContainmentMonitor()
        _ = try await RunContainmentMonitor.$current.withValue(monitor) {
            try await UnverifiedCleanupFixture.run()
        }

        #expect(monitor.isAborted)
        #expect(throws: RunAbortedError.self) { try monitor.throwIfAborted() }
    }

    /// A root that SIGKILL cannot settle (for example one stuck in an
    /// uninterruptible sleep) must not keep the result, and so the abort,
    /// from reaching the caller. The reap is simulated as never finishing by
    /// holding the `.finalReap` lifecycle hook, which runs right after it.
    @Test("A root that never exits after SIGKILL does not block the unverified result from reaching the caller")
    func unexitedRootDoesNotBlockTheResult() async throws {
        let reapGate = DispatchSemaphore(value: 0)
        defer { reapGate.signal() }
        let monitor = RunContainmentMonitor()
        let started = Date()
        let result = try await RunContainmentMonitor.$current.withValue(monitor) {
            try await ProcessSupervisor.run(
                executable: "/bin/sh", arguments: ["-c", UnverifiedCleanupFixture.script],
                workingDirectory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment,
                timeoutSeconds: 1.5, terminationGracePeriodSeconds: 0.5,
                lifecycleEventHook: { event in
                    if case .finalReap = event { _ = reapGate.wait(timeout: .now() + 30) }
                },
                rootExitProbe: { _ in false }
            )
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 20, "the result waited on the reap: \(elapsed)s")
        #expect(result.cleanupVerified == false)
        #expect(result.cleanupDiagnosis?.contains("had not exited") == true, "diagnosis: \(result.cleanupDiagnosis ?? "nil")")
        #expect(monitor.isAborted)
    }

    /// A same-group descendant that polling never observed (here the table
    /// reads empty, as a descendant double-forked inside one poll tick or a
    /// transient failed read leaves it) and that ignores SIGTERM. The root
    /// exits on its own, so close-out ends before its SIGKILL escalation;
    /// the group SIGKILL must still reach the descendant, or a close-out
    /// reported verified leaves it running.
    @Test("An unobserved same-group descendant that ignores SIGTERM does not survive close-out")
    func unobservedSigtermIgnoringDescendantIsKilled() async throws {
        let script = "( trap '' TERM; exec /bin/sleep 60 ) </dev/null >/dev/null 2>&1 & echo $!"
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 10, terminationGracePeriodSeconds: 0.5, lifecycleEventHook: nil,
            processTableReader: { [] }
        )
        let output = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let descendant = try #require(pid_t(output), "the root must report its descendant's pid: \(output)")
        defer { kill(descendant, SIGKILL) }

        #expect(result.exitCode == 0 && !result.timedOut, "the root must exit on its own")
        let deadline = Date().addingTimeInterval(5)
        while ProcessTree.isRunning(pid: descendant), Date() < deadline {
            usleep(50000)
        }
        #expect(!ProcessTree.isRunning(pid: descendant), "the unobserved descendant \(descendant) outlived close-out")
        #expect(result.cleanupVerified)
    }

    /// The root exits on its own with no descendant ever observed, so
    /// close-out ends before its SIGKILL escalation. With an unreadable
    /// table nothing proves the group emptied after the group SIGKILL, so
    /// the close-out must not be reported verified.
    @Test("A close-out that ends before escalation is unverified when the table cannot be read")
    func earlyCloseOutWithUnreadableTableIsUnverified() async throws {
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "exit 0"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 10, terminationGracePeriodSeconds: 0.5, lifecycleEventHook: nil,
            processTableReader: { nil }
        )

        #expect(result.exitCode == 0 && !result.timedOut, "the root must exit on its own")
        #expect(result.cleanupVerified == false)
        #expect(result.cleanupDiagnosis?.contains("could not be read") == true, "diagnosis: \(result.cleanupDiagnosis ?? "nil")")
    }

    /// After the group SIGKILL, the table still shows a running member of
    /// the root's process group that polling never observed (simulated by
    /// a phantom entry, so the scenario is deterministic). Both close-out
    /// exits must report that, not return verified.
    @Test(
        "A same-group member still running after the group SIGKILL makes close-out unverified",
        arguments: [
            (script: "exit 0", timedOut: false),
            (script: UnverifiedCleanupFixture.script, timedOut: true)
        ]
    )
    func runningGroupMemberAfterGroupKillIsUnverified(script: String, timedOut: Bool) async throws {
        let reader = UnverifiedCleanupFixture.PhantomGroupMemberReader()
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 1.5, terminationGracePeriodSeconds: 0.5,
            lifecycleEventHook: { event in
                if case let .groupSignal(pid, SIGKILL) = event { reader.arm(groupID: pid) }
            },
            processTableReader: { reader.read() }
        )

        #expect(result.timedOut == timedOut)
        #expect(result.cleanupVerified == false)
        let diagnosis = try #require(result.cleanupDiagnosis)
        #expect(diagnosis.contains(String(UnverifiedCleanupFixture.PhantomGroupMemberReader.phantomPID)), "diagnosis: \(diagnosis)")
    }

    /// The PID-reuse provenance invariant (`ProcessTree.signal`): an
    /// identity whose table entry cannot be read is never signalled, and
    /// the skip is reported rather than hidden.
    @Test("signal never kills an identity it could not verify, and reports that it could not")
    func signalSkipsAndReportsAnUnverifiableIdentity() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        let pid = sleeper.processIdentifier
        let table = try #require(ProcessTree.readProcessTable())
        let identity = try #require(table.first { $0.pid == pid }?.identity)

        let unverifiedOutcome = ProcessTree.signal([identity], SIGKILL, readTable: { nil })
        #expect(unverifiedOutcome == false)
        #expect(ProcessTree.isAlive(identity), "an unverified identity must not be signalled")

        let verifiedOutcome = ProcessTree.signal([identity], SIGKILL)
        #expect(verifiedOutcome)
        sleeper.waitUntilExit()
        #expect(sleeper.terminationReason == .uncaughtSignal)
    }

    /// A launch inside `permittingTeardownLaunches` removes what the run created and produces no evidence, so
    /// an unverifiable cleanup there must not abort a run whose report may already be written.
    @Test("An unverified cleanup in a teardown launch does not trip the run's monitor, an ordinary one does")
    func teardownLaunchDoesNotTripTheMonitor() async throws {
        func launch(teardown: Bool) async throws -> Bool {
            let monitor = RunContainmentMonitor()
            try await RunContainmentMonitor.$current.withValue(monitor) {
                let run = {
                    try await ProcessSupervisor.run(
                        executable: "/bin/sh", arguments: ["-c", "exit 0"],
                        workingDirectory: FileManager.default.temporaryDirectory,
                        environment: ProcessInfo.processInfo.environment, timeoutSeconds: 10,
                        terminationGracePeriodSeconds: 0.5, lifecycleEventHook: nil, processTableReader: { nil }
                    )
                }
                let result = teardown ? try await RunContainmentMonitor.permittingTeardownLaunches(run) : try await run()
                #expect(result.cleanupVerified == false)
            }
            return monitor.isAborted
        }

        #expect(try await launch(teardown: false), "control: an unverified ordinary launch trips the monitor")
        #expect(try await !launch(teardown: true), "a teardown launch must not")
    }
}
