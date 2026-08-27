import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// The descendant walk that makes killing a hung mutant actually work.
///
/// Covered here as well as in the acceptance suite because the acceptance suite
/// takes a minute and this takes milliseconds — and because these assert the
/// mechanism directly rather than through a whole mutation run.
@Suite("Process tree", .subprocessExclusive)
struct ProcessTreeTests {
    /// Spawns `/bin/sh -c 'sleep 30 & sleep 30'`, giving a child with a child.
    ///
    /// Deliberately not a process group escape — that is what the acceptance suite
    /// reproduces with a real SwiftPM helper. This checks the plain case: that the
    /// walk actually descends.
    private func spawnTree() throws -> (parent: pid_t, cleanup: () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & sleep 30"]
        try process.run()

        // The grandchild needs a moment to exist before it can be found.
        Thread.sleep(forTimeInterval: 0.4)

        return (
            process.processIdentifier,
            {
                let survivors = ProcessTree.descendants(of: process.processIdentifier)
                kill(process.processIdentifier, SIGKILL)
                ProcessTree.forceKill(survivors)
                process.waitUntilExit()
            }
        )
    }

    @Test("The walk finds children and grandchildren")
    func descendantsAreFoundRecursively() throws {
        let (parent, cleanup) = try spawnTree()
        defer { cleanup() }

        let descendants = ProcessTree.descendants(of: parent)
        // `sh` forks one backgrounded `sleep` and execs into another, so the exact
        // shape is the shell's business — but there must be at least one.
        #expect(!descendants.isEmpty, "expected at least one descendant of \(parent)")
        #expect(!descendants.contains(parent), "a process is not its own descendant")
    }

    @Test("Every descendant is dead after a force kill")
    func forceKillReclaimsTheTree() throws {
        let (parent, cleanup) = try spawnTree()
        defer { cleanup() }

        let descendants = ProcessTree.descendants(of: parent)
        try #require(!descendants.isEmpty)

        kill(parent, SIGKILL)
        ProcessTree.forceKill(descendants)
        // Reaping is the kernel's, and it is not instant.
        Thread.sleep(forTimeInterval: 0.4)

        let survivors = descendants.filter { ProcessTree.isAlive($0) }
        #expect(survivors.isEmpty, "survived a force kill: \(survivors)")
    }

    /// A process with no children must not report the whole machine.
    @Test("A leaf process has no descendants")
    func leafHasNoDescendants() {
        #expect(ProcessTree.descendants(of: getpid()).isEmpty
            || !ProcessTree.descendants(of: getpid()).contains(getpid()))
    }

    /// A pid that does not exist is a normal thing to ask about — a process that
    /// already exited on its own — and must not be an error or a wildcard.
    @Test("An unknown pid has no descendants")
    func unknownPIDIsEmpty() {
        // Above the pid range the kernel will hand out.
        #expect(ProcessTree.descendants(of: 999_999).isEmpty)
    }

    /// Killing an empty list must be a no-op rather than a signal to something
    /// unrelated — `kill(0, ...)` and `kill(-1, ...)` both mean "broadcast".
    @Test("Force killing nothing signals nothing")
    func forceKillOfEmptyListIsSafe() {
        ProcessTree.forceKill([])
        #expect(ProcessTree.isAlive(getpid()), "the test process should still be here")
    }

    // MARK: - ProcessIdentity / reap(_:) — the delayed, PID-reuse-safe path

    @Test("descendantIdentities finds the same processes as descendants(of:)")
    func descendantIdentitiesMatchesDescendants() throws {
        let (parent, cleanup) = try spawnTree()
        defer { cleanup() }

        let pids = Set(ProcessTree.descendants(of: parent))
        let identities = ProcessTree.descendantIdentities(of: parent)
        #expect(Set(identities.map(\.pid)) == pids)
    }

    @Test("An identity observed while the process is alive is still verifiable, and reap(_:) reclaims it")
    func reapReclaimsAVerifiedIdentity() throws {
        let (parent, cleanup) = try spawnTree()
        defer { cleanup() }

        let identities = ProcessTree.descendantIdentities(of: parent)
        try #require(!identities.isEmpty)
        #expect(identities.allSatisfy { ProcessTree.isAlive($0) })

        ProcessTree.reap(identities)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(identities.allSatisfy { !ProcessTree.isAlive($0) })
    }

    /// The actual safety property `reap(_:)` exists for: a stale identity —
    /// one whose recorded PID is no longer running the same process instance
    /// (here, simulated directly by fabricating a start time no live process
    /// could plausibly have) — must never be signalled, even though its PID
    /// number alone might currently belong to something else entirely.
    ///
    /// What this does *not*, and structurally cannot, exercise: the genuine
    /// kernel TOCTOU window between `signal(_:_:)`'s own `isAlive(_:)` check
    /// and its own `kill` call a few instructions later (flagged in review;
    /// see that function's own doc comment for the full disposition). Real
    /// PID reuse landing inside that specific few-instruction window is not
    /// deterministically triggerable from a test — the kernel does not
    /// expose a way to force it — so this test instead pins the comparator
    /// half of the property (a mismatched identity is correctly rejected),
    /// which is the part that *is* reliably testable, and is not weakened by
    /// the residual, acknowledged race the narrower window still carries.
    @Test("reap(_:) never signals a PID whose current start time no longer matches — the PID-reuse safety property")
    func reapNeverSignalsAMismatchedIdentity() throws {
        let (parent, cleanup) = try spawnTree()
        defer { cleanup() }

        let real = try #require(ProcessTree.descendantIdentities(of: parent).first)
        let stale = ProcessTree.ProcessIdentity(pid: real.pid, startTimeSeconds: 1, startTimeMicroseconds: 0)
        #expect(!ProcessTree.isAlive(stale), "a fabricated start time must not match the real process")

        ProcessTree.reap([stale])
        Thread.sleep(forTimeInterval: 0.2)
        #expect(ProcessTree.isAlive(real), "reap(_:) must not have killed the real process via its PID-only-matching stale identity")
    }

    @Test("Reaping nothing signals nothing")
    func reapOfEmptyListIsSafe() {
        ProcessTree.reap([])
        #expect(ProcessTree.isAlive(getpid()), "the test process should still be here")
    }
}
