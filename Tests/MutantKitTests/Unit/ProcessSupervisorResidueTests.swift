import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// Phase 1 (status-independent descendant containment): a promptly-exiting
/// supervised process can leave a live descendant behind exactly as easily as
/// a timed-out one — demonstrated directly against real subprocesses here
/// (`ProcessSupervisor.run`, not the full CLI/mutation pipeline, since the
/// mechanism under test lives entirely in `ProcessSupervisor`/`ProcessTree`,
/// shared unchanged by isolated and schemata mode alike).
///
/// The safety invariant under test throughout: never kill a process merely
/// because it resembles one of ours — only reap a PID whose provenance
/// (PID *and* recorded start time, per `ProcessTree.ProcessIdentity`) to the
/// supervised invocation was positively established while that invocation
/// was still alive to prove it.
///
/// Every scenario that needs a background-forking supervised process uses
/// `/usr/bin/python3 -c '...'` (`subprocess.Popen`) as the vehicle, never
/// `sh -c '... &'`. Measured directly, with extensive raw-`sysctl` timing
/// diagnostics, before settling on this shape: `sh -c 'cmd &'` under this
/// toolchain's `/bin/sh` (bash 3.2 in POSIX mode) reliably kills the
/// backgrounded child soon after the shell itself exits — no trappable
/// signal observed (SIGKILL or an equivalent uncatchable teardown), 100%
/// reproducible across 20 raw trials regardless of poll granularity down to
/// 1 ms, and unrelated to `ProcessSupervisor`/`ProcessTree` entirely (the
/// same loss occurs polling with a bare, unrelated `Foundation.Process`).
/// `python3`'s `subprocess.Popen` (no shell involved) does not exhibit this
/// at all — 10/10 raw trials survived — and is what `SchemataCrashResidue
/// AcceptanceTests` (ADR-0008 §5 item 5(b)) already uses successfully for
/// the same reason.
/// `.serialized`: real, direct evidence this suite's own 4 process-spawning
/// tests running concurrently with *each other* (Swift Testing's default)
/// is itself the dominant driver of the CI flakiness this file went through
/// two prior rounds of fixing (`eventuallyNoSurvivors` polling,
/// `ProcessSupervisor`'s descendant-tracking thread QoS) -- a real public CI
/// run failed 3 of this suite's own 4 tests simultaneously, on a
/// GitHub-hosted macOS runner confirmed (via that same run's own "Toolchain"
/// step) to have exactly 3 vCPUs. Each test here spawns a real `python3`
/// process that itself forks a background child, and asserts on how quickly
/// the OS actually reaps/removes a killed descendant from the process
/// table -- a fundamentally real-wall-clock-dependent measurement that
/// cannot be made deterministic the way `MutationRunnerWaveEarlyKillTests`'
/// own doc comment describes doing for *simulated* durations (a fake clock
/// cannot stand in for "did the kernel actually finish removing this PID").
/// Four such probes racing each other for 3 real cores is a self-inflicted
/// worst case none of them individually need to survive to prove their own
/// claim -- unlike the *separate*, deliberately-concurrent-usage tests
/// elsewhere in this codebase (e.g. "Under real chunk concurrency
/// (workers: 2)..."), nothing here is testing `ProcessSupervisor`'s
/// behavior *under* concurrent invocation, so removing this suite's own
/// self-contention changes nothing about what it verifies.
///
/// `.serialized` alone was not the end of the story: this suite kept
/// failing in CI even after adopting it, because Swift Testing schedules
/// every *other* suite fully concurrently by default -- these tests were
/// still racing `XcodeConfigDetectorTests`/
/// `XcodeBuildAdapterUninstallFailureTests` (different suites, same 3 real
/// cores). `.subprocessExclusive` (`Tests/MutantKitTests/Support/
/// SubprocessTestGate.swift`) is the real, cross-suite fix -- `.serialized`
/// is kept alongside it as a harmless, redundant-in-one-direction
/// documentation of this suite's own internal self-contention history,
/// not because it is still load-bearing on its own.
@Suite("Acceptance: ProcessSupervisor reaps descendants regardless of exit status", .serialized, .subprocessExclusive)
struct ProcessSupervisorResidueTests {
    /// The `timeoutSeconds` passed to every `ProcessSupervisor.run` call below
    /// that expects a *prompt* exit. Originally 10, then 30 — raised again
    /// (to 60) after a real, repeated public-CI failure pattern (not just
    /// local reproduction this time): a GitHub-hosted macOS runner
    /// confirmed to have only 3 vCPUs kept intermittently failing this
    /// suite's own residue checks even after both the cross-suite
    /// subprocess-exclusion fix and a CI-only Swift Testing concurrency cap
    /// (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`, see `ci.yml`).
    /// Treat "the CI machine was briefly under real load" as an expected,
    /// tolerable condition this suite should be robust to by design — a
    /// generous poll-until-true ceiling, not something to engineer away
    /// entirely via scheduling alone. Costs nothing on the passing case:
    /// these scripts still exit in well under a second on any machine with
    /// spare capacity, and `eventuallyNoSurvivors` below returns the
    /// moment survivors actually disappear, never waiting out the full
    /// ceiling on a genuine pass.
    private static let promptExitTimeoutSeconds: Double = 60

    private func markerPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-residue-\(label)-\(UUID().uuidString)").path
    }

    /// A python3 script that writes `marker`, forks a `tail -f marker`
    /// background child (in the caller's own process group — the ordinary
    /// case, no session/group escape), then exits promptly with status 1.
    private func backgroundingScript(marker: String) -> String {
        """
        open('\(marker)', 'w').close()
        import subprocess
        subprocess.Popen(['/usr/bin/tail', '-f', '\(marker)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise SystemExit(1)
        """
    }

    /// Mirrors `ProcessSupervisionAcceptanceTests.survivingProcesses(referencing:)`
    /// — `pgrep -fl` against a unique marker path embedded in the survivor's
    /// own argv, the same trusted technique used there.
    private func survivingProcesses(referencing needle: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", needle]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        // Close-on-exec, immediately: a real CI stack sample caught this
        // exact function stuck forever in `readDataToEndOfFile()` -- the
        // identical, already-fixed-elsewhere bug class from
        // `ProcessSupervisor.swift`/`ToolRunner.swift` (`pipe(2)` does not
        // set FD_CLOEXEC by default), just never applied to this test
        // helper's own pipes. This suite spawns several other real
        // processes (a bystander `tail -f`, `ProcessSupervisor`-managed
        // `python3` scripts) whose own `posix_spawn` calls, racing on other
        // threads while this pipe's write end is still open, can inherit a
        // copy of it -- holding it open long after `pgrep` itself exited
        // and blocking the read below forever, regardless of how generous
        // `eventuallyNoSurvivors`'s own timeout is (that timeout bounds
        // polling *between* calls to this function; it cannot bound a
        // single call stuck reading a pipe that will never see EOF). Safe
        // for `pgrep`'s own intended stdout/stderr the same way it is in
        // `ProcessSupervisor.swift`: POSIX `dup2` always clears close-on-
        // exec on the *new* descriptor it creates, regardless of the
        // source's own flag, so `Process.run()`'s own `dup2`-based wiring
        // of `standardOutput`/`standardError` into `pgrep`'s real fds 1/2
        // is unaffected by marking these *original* pipe fds here.
        for handle in [outputPipe.fileHandleForReading, outputPipe.fileHandleForWriting,
                       errorPipe.fileHandleForReading, errorPipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        guard (try? process.run()) != nil else { return [] }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.contains("pgrep") }
    }

    private func killByMarker(_ marker: String) {
        for line in survivingProcesses(referencing: marker) {
            if let pid = Int32(line.split(separator: " ").first ?? "") { kill(pid, SIGKILL) }
        }
    }

    /// Terminates a `Foundation.Process` bystander with a bound on how long
    /// this cleanup itself can take -- never `.terminate()` followed
    /// unconditionally by `.waitUntilExit()`, which has no timeout parameter
    /// at all and can block forever.
    ///
    /// A real, direct reproduction (a stack sample of a genuinely stuck
    /// `swiftpm-testing-helper` process, captured while verifying an
    /// unrelated change against the public tree) caught exactly this: a
    /// bystander `tail -f` process's `waitUntilExit()` parked indefinitely
    /// in `mach_msg`, waiting on Foundation's own internal death
    /// notification for that specific child, with the process's own
    /// `.terminate()` (SIGTERM) apparently either never delivered or never
    /// observed as having taken effect. Whichever it was, `waitUntilExit()`
    /// itself has no way to be told "give up after N seconds" -- the only
    /// way to bound this from the caller's side is to poll `isRunning` with
    /// our own deadline and escalate to a raw, uncatchable `SIGKILL` (plus a
    /// best-effort direct `waitpid` to reap it) if Foundation's own
    /// bookkeeping never reports the process as gone.
    private static func terminateBoundedly(_ process: Process, timeoutSeconds: Double = 5) {
        process.terminate()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            usleep(10000)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        var status: Int32 = 0
        // Blocking, not WNOHANG: safe here specifically because SIGKILL
        // cannot be caught or blocked, so a genuinely still-alive child dies
        // essentially immediately, and a child some other mechanism already
        // reaped out from under us returns ECHILD immediately instead of
        // blocking -- there is no shape of "still alive but never exits"
        // left for this call to hang on the way `waitUntilExit()` did.
        _ = waitpid(process.processIdentifier, &status, 0)
    }

    /// Polls `survivingProcesses(referencing:)` until it is empty or
    /// `timeoutSeconds` elapses, instead of a single fixed-delay check.
    ///
    /// `ProcessSupervisor.run` sends the reaping kill synchronously, before it
    /// ever returns to its caller — but the kernel actually removing a killed
    /// process from the process table (what `pgrep`, and therefore
    /// `survivingProcesses`, observes) is a separate step on the kernel's own
    /// schedule, not something the caller can force to complete by any
    /// particular deadline. A single fixed sleep-then-check (originally
    /// 300 ms here) assumes a latency ceiling that only holds on an
    /// uncontended machine: under real GitHub Actions macOS-runner
    /// concurrency (a handful of vCPUs running this entire suite's own
    /// Swift-Testing-level parallelism, each test here itself spawning
    /// `python3`/`tail`/`pgrep` subprocesses), this reliably fired as a false
    /// failure — reproduced locally too, deterministically, by adding
    /// artificial CPU oversubscription (dozens of busy-loop processes on an
    /// 8-core machine) while running the full suite. Polling keeps this fast
    /// on a quiet machine (the common case exits the loop on its first
    /// iteration) while not being a trip wire on a loaded one.
    private func eventuallyNoSurvivors(referencing needle: String, timeoutSeconds: Double = 60) async -> [String] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let survivors = survivingProcesses(referencing: needle)
            if survivors.isEmpty || Date() >= deadline { return survivors }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Item 1: ordinary passing process, no unrelated process affected

    @Test("An ordinary passing process with no descendants never touches an unrelated sibling process")
    func ordinaryPassingProcessAffectsNothingElse() async throws {
        let bystanderMarker = markerPath("bystander")
        FileManager.default.createFile(atPath: bystanderMarker, contents: nil)
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        bystander.arguments = ["-f", bystanderMarker]
        bystander.standardOutput = FileHandle.nullDevice
        bystander.standardError = FileHandle.nullDevice
        try bystander.run()
        defer {
            Self.terminateBoundedly(bystander)
            try? FileManager.default.removeItem(atPath: bystanderMarker)
        }

        let result = try await ProcessSupervisor.run(
            executable: "/bin/echo", arguments: ["hello"], workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 5
        )
        #expect(result.succeeded)
        #expect(bystander.isRunning, "an unrelated sibling process must never be affected by supervising an unrelated child")
    }

    // MARK: - Item 2: ordinary (non-crash) failure with no descendants is a cheap no-op

    @Test("An ordinary non-zero exit with no descendants reports the failure correctly and reaps nothing")
    func ordinaryFailureWithNoDescendantsIsANoOp() async throws {
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "exit 3"], workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 5
        )
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
        #expect(result.terminatingSignal == nil)
    }

    // MARK: - Item 3: a prompt crash (non-timeout) that already left a background child

    @Test("A promptly-exiting process that already forked a background child in its own process group: the child is reaped")
    func promptExitReapsAChildInTheSameGroup() async throws {
        let marker = markerPath("same-group-child")
        // No group/session escape here: this child stays in the supervised
        // process's own group, the ordinary case. It must still be reaped —
        // the prompt-exit path never sends any group signal at all (that
        // only happens on the timeout branch), so only the new continuous
        // descendant tracking can catch this one.
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: marker)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: Self.promptExitTimeoutSeconds
        )
        #expect(result.exitCode == 1)
        #expect(!result.timedOut)

        let survivors = await eventuallyNoSurvivors(referencing: marker)
        defer { killByMarker(marker); try? FileManager.default.removeItem(atPath: marker) }
        #expect(survivors.isEmpty, "residue left behind by a prompt exit: \(survivors)")
    }

    // MARK: - Item 5: a child that escapes into its own process group, on a prompt exit

    @Test("A promptly-exiting process whose child escaped into its own process group is still reaped, by provenance not by group")
    func promptExitReapsAChildThatEscapedItsProcessGroup() async throws {
        let marker = markerPath("escaped-group-child")
        // python3's `start_new_session=True` calls `setsid()` before exec —
        // the same shape of escape ADR-0008/ProcessSupervisor's own doc
        // comment records for `swiftpm-testing-helper` (a new session *and*
        // process group, unreachable via `kill(-pgid)`). `descendants(of:)`
        // still finds it because ancestry (ppid), not group membership, is
        // what it walks — this test exists to confirm the *reap* step
        // (provenance-verified kill) also reaches a group-escaped process
        // when the exit is prompt, not just when it's a timeout.
        let script = """
        open('\(marker)', 'w').close()
        import subprocess
        subprocess.Popen(['/usr/bin/tail', '-f', '\(marker)'], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise SystemExit(1)
        """
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", script], workingDirectory: FileManager.default.temporaryDirectory,
            timeoutSeconds: Self.promptExitTimeoutSeconds
        )
        #expect(result.exitCode == 1)
        #expect(!result.timedOut)

        let survivors = await eventuallyNoSurvivors(referencing: marker)
        defer { killByMarker(marker); try? FileManager.default.removeItem(atPath: marker) }
        #expect(survivors.isEmpty, "a process-group-escaped descendant survived a prompt exit: \(survivors)")
    }

    // MARK: - Item 6: an unrelated process with the same executable name is never killed

    @Test("An unrelated process sharing an executable name with a real descendant is never killed — provenance, not resemblance")
    func unrelatedSameNamedProcessIsNeverKilled() async throws {
        let unrelatedMarker = markerPath("unrelated")
        FileManager.default.createFile(atPath: unrelatedMarker, contents: nil)
        // Launched directly by the *test*, never as a descendant of anything
        // ProcessSupervisor spawns below — same executable ("tail") a real
        // reaped descendant would use elsewhere in this suite, but no
        // ancestry link to the supervised process at all.
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        unrelated.arguments = ["-f", unrelatedMarker]
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer {
            Self.terminateBoundedly(unrelated)
            try? FileManager.default.removeItem(atPath: unrelatedMarker)
        }

        // A supervised process with a real, *different* descendant of its
        // own — proving reaping is actually exercised in this test, not
        // skipped because nothing was ever observed.
        let ownMarker = markerPath("own")
        _ = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: ownMarker)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: Self.promptExitTimeoutSeconds
        )
        defer { killByMarker(ownMarker); try? FileManager.default.removeItem(atPath: ownMarker) }

        let ownSurvivors = await eventuallyNoSurvivors(referencing: ownMarker)
        #expect(unrelated.isRunning, "an unrelated process must never be killed just because it shares an executable name")
        #expect(ownSurvivors.isEmpty, "the supervised process's own descendant should have been reaped")
    }

    // MARK: - Item 7: repeated invocations do not leak provenance between runs

    @Test("Two sequential invocations each reap only their own descendant, with no leakage between them")
    func repeatedInvocationsDoNotLeakProvenance() async throws {
        let markerA = markerPath("run-a")
        let markerB = markerPath("run-b")

        let resultA = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: markerA)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: Self.promptExitTimeoutSeconds
        )
        #expect(resultA.exitCode == 1)
        let survivorsA = await eventuallyNoSurvivors(referencing: markerA)
        #expect(survivorsA.isEmpty, "run A's own descendant must be reaped after run A")

        let resultB = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: markerB)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: Self.promptExitTimeoutSeconds
        )
        #expect(resultB.exitCode == 1)
        let survivorsB = await eventuallyNoSurvivors(referencing: markerB)
        defer {
            killByMarker(markerA); killByMarker(markerB)
            try? FileManager.default.removeItem(atPath: markerA)
            try? FileManager.default.removeItem(atPath: markerB)
        }
        #expect(survivorsB.isEmpty, "run B's own descendant must be reaped after run B, independently of run A")
    }
}
