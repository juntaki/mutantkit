import AppleBuildAdapters
import Foundation
import MutationExecution

/// The one place a command takes the project/destination run lock.
///
/// `run` and `dry-run` both call this with the `ResolvedInvocationContext`
/// they resolved, so "same device" and "same lock key" are one fact
/// (`DestinationIdentity`), not two derivations that can drift apart. Call it
/// before any simulator side effect: a process that loses the race fails
/// before it has booted or prepared anything.
///
/// Independent MutantKit processes must not compete for one project/destination:
/// resource contention and a shared simulator can change a mutant's observable
/// failure mode (crash vs timeout) and so the score. Internal workers share the
/// owning process and therefore its lock.
///
/// Mixed versions: builds from before the OS-held lock (existence + PID
/// metadata, unlinkable) and newer builds do not see each other's ownership, and
/// the key format changed with `DestinationIdentity`. This does not try to
/// interlock them: recognising the old format would mean guessing liveness from
/// a PID again. Do not run mixed versions against one project/destination
/// concurrently.
enum DestinationLock {
    static func acquire(
        context: ResolvedInvocationContext, runDirectory: URL
    ) throws -> (lock: RunIsolationLock, lockRoot: URL) {
        let lockRoot = runDirectory.appendingPathComponent("run-locks")
        let lock = try RunIsolationLock.acquire(
            projectRoot: context.projectRoot, lockRoot: lockRoot, destination: context.destinationIdentity.lockKey
        )
        return (lock, lockRoot)
    }
}
