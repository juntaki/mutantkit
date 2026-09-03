import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// F3 zero-base review: pins the exact bug the `POSIX_SPAWN_SETSIGMASK`/
/// `POSIX_SPAWN_SETSIGDEF` fix in `ProcessSupervisor.runBlocking` closes —
/// a spawned process starting with `SIGTERM` blocked (inherited from
/// whatever the *calling thread's* own mask happened to be, for reasons
/// unrelated to this codebase — confirmed directly to be true of the
/// dedicated `Thread` `run(...)` spawns its blocking work onto under
/// `swift test`) or ignored (inherited disposition, independent of
/// masking) would make every `SIGTERM` this codebase's own `TERM -> grace
/// -> KILL` escalation contract depends on silently do nothing, with no
/// error, no different exit code — the escalation would just always run
/// the full grace period and fall through to `SIGKILL`, indistinguishable
/// from an intentionally uncooperative process without directly asking
/// the spawned process itself. Deterministic, not a timing measurement:
/// asks the spawned process to report its own, real, kernel-visible
/// `SIGTERM` blocked-state and disposition immediately at startup, before
/// this codebase's own signal ever reaches it.
@Suite("ProcessSupervisor: spawned processes start with SIGTERM unblocked and default-disposed", .subprocessExclusive)
struct ProcessSupervisorSpawnedProcessSignalStateTests {
    @Test("A freshly spawned process reports SIGTERM as neither blocked nor ignored, regardless of the spawning thread's own state")
    func spawnedProcessStartsWithSigtermUnblockedAndDefault() async throws {
        let script = """
        import signal
        blocked = signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, [])
        # Compared as a plain int, not the disposition's own repr: Python's
        # `Handlers` enum reprs `SIG_DFL`/`SIG_IGN` differently across
        # versions (e.g. "Handlers.SIG_DFL" vs a bare "0"), but the
        # underlying value is a stable, version-independent int either way.
        is_default = int(signal.getsignal(signal.SIGTERM)) == int(signal.SIG_DFL)
        print(f"blocked={blocked} is_default_disposition={is_default}")
        """
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 10
        )

        #expect(result.succeeded)
        #expect(result.outputComplete)
        let output = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "blocked=False is_default_disposition=True", "spawned process reported: \(output)")
    }
}
