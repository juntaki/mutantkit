import Darwin
import Foundation
@testable import MutationExecution

/// Drives a real `ProcessSupervisor` close-out into its SIGKILL branch and
/// then makes the process table unreadable: the failure that must be
/// reported (and abort the run) instead of being treated as a clean kill.
///
/// The supervised `/bin/sh` ignores SIGTERM, and so does the `sleep` it
/// forks (an ignored disposition survives `exec`), so the timeout's SIGTERM
/// cannot end either one and close-out has to escalate. The injected
/// process-table reader works normally until the supervisor reports its
/// SIGKILL group signal, and fails from then on. Both processes stay in the
/// supervisor-owned group, so the group SIGKILL still really kills them: the
/// only thing the fault takes away is the supervisor's ability to verify it.
enum UnverifiedCleanupFixture {
    /// A table reader that starts failing once `arm()` is called.
    final class FaultingTableReader: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false

        func arm() {
            lock.lock()
            failing = true
            lock.unlock()
        }

        var isArmed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failing
        }

        func read() -> [ProcessTree.Entry]? {
            isArmed ? nil : ProcessTree.readProcessTable()
        }
    }

    /// Reads the real table, plus, once `arm(groupID:)` has been called, one
    /// phantom running member of that process group. Only read, never
    /// signalled: close-out signals by group and by verified identity.
    final class PhantomGroupMemberReader: @unchecked Sendable {
        static let phantomPID: pid_t = 99998
        private let lock = NSLock()
        private var groupID: pid_t?

        func arm(groupID: pid_t) {
            lock.lock()
            self.groupID = groupID
            lock.unlock()
        }

        func read() -> [ProcessTree.Entry]? {
            lock.lock()
            let groupID = groupID
            lock.unlock()
            guard let table = ProcessTree.readProcessTable() else { return nil }
            guard let groupID else { return table }
            return table + [ProcessTree.Entry(
                pid: Self.phantomPID, ppid: 1, pgid: groupID, startTimeSeconds: 0, startTimeMicroseconds: 0, isZombie: false
            )]
        }
    }

    static let script = "trap '' TERM; sleep 30 & wait"

    /// Runs the scenario. With `injectFault == false` the same escalation
    /// runs against the real table, as a control.
    static func run(injectFault: Bool = true) async throws -> ProcessResult {
        let reader = FaultingTableReader()
        return try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 1.5, terminationGracePeriodSeconds: 0.5,
            lifecycleEventHook: { event in
                if injectFault, case .groupSignal(_, SIGKILL) = event { reader.arm() }
            },
            processTableReader: { reader.read() }
        )
    }
}
