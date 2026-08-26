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
@Suite("Acceptance: ProcessSupervisor reaps descendants regardless of exit status")
struct ProcessSupervisorResidueTests {
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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.contains("pgrep") }
    }

    private func killByMarker(_ marker: String) {
        for line in survivingProcesses(referencing: marker) {
            if let pid = Int32(line.split(separator: " ").first ?? "") { kill(pid, SIGKILL) }
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
            bystander.terminate()
            bystander.waitUntilExit()
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
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        )
        #expect(result.exitCode == 1)
        #expect(!result.timedOut)

        try await Task.sleep(nanoseconds: 300_000_000)
        let survivors = survivingProcesses(referencing: marker)
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
            timeoutSeconds: 10
        )
        #expect(result.exitCode == 1)
        #expect(!result.timedOut)

        try await Task.sleep(nanoseconds: 300_000_000)
        let survivors = survivingProcesses(referencing: marker)
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
            unrelated.terminate()
            unrelated.waitUntilExit()
            try? FileManager.default.removeItem(atPath: unrelatedMarker)
        }

        // A supervised process with a real, *different* descendant of its
        // own — proving reaping is actually exercised in this test, not
        // skipped because nothing was ever observed.
        let ownMarker = markerPath("own")
        _ = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: ownMarker)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        )
        defer { killByMarker(ownMarker); try? FileManager.default.removeItem(atPath: ownMarker) }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(unrelated.isRunning, "an unrelated process must never be killed just because it shares an executable name")
        #expect(survivingProcesses(referencing: ownMarker).isEmpty, "the supervised process's own descendant should have been reaped")
    }

    // MARK: - Item 7: repeated invocations do not leak provenance between runs

    @Test("Two sequential invocations each reap only their own descendant, with no leakage between them")
    func repeatedInvocationsDoNotLeakProvenance() async throws {
        let markerA = markerPath("run-a")
        let markerB = markerPath("run-b")

        let resultA = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: markerA)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        )
        #expect(resultA.exitCode == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(survivingProcesses(referencing: markerA).isEmpty, "run A's own descendant must be reaped after run A")

        let resultB = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", backgroundingScript(marker: markerB)],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        )
        #expect(resultB.exitCode == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        defer {
            killByMarker(markerA); killByMarker(markerB)
            try? FileManager.default.removeItem(atPath: markerA)
            try? FileManager.default.removeItem(atPath: markerB)
        }
        #expect(
            survivingProcesses(referencing: markerB).isEmpty, "run B's own descendant must be reaped after run B, independently of run A"
        )
    }
}
