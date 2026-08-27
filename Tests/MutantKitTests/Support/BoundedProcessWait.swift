import Darwin
import Foundation

/// Bounds how long waiting for a `Foundation.Process` to exit can take,
/// instead of trusting `Process.waitUntilExit()` unconditionally.
///
/// Part of the mutation-testing hardening program's CI-reliability
/// follow-up (`Research/mutation-testing-hardening-2026-08/PROGRESS.md`).
/// Two independent, real public-CI stack samples this session caught a
/// test process genuinely stuck inside `waitUntilExit()`'s own `mach_msg`
/// wait — once for a long-lived bystander process after `.terminate()`
/// (`ProcessSupervisorResidueTests.terminateBoundedly`, kept as that
/// file's own private implementation since it predates this shared type),
/// and again for a short-lived `pgrep` invocation *after its own stdout
/// pipe had already reached EOF* — proof this is a real, if rare,
/// Foundation-internal death-notification hazard, not something ruled out
/// by the child's own I/O already having finished. `waitUntilExit()` has
/// no timeout parameter at all, so the only way to bound it from the
/// caller's side is to poll `isRunning` against a deadline and escalate to
/// a raw, uncatchable `SIGKILL` (plus a best-effort direct `waitpid` to
/// reap it) if Foundation's own bookkeeping never reports the process as
/// gone.
///
/// Never sends any signal before the deadline: most callers expect the
/// process to exit on its own (a real compiler/tool finishing its work),
/// so signaling it early would interfere with a legitimate, still-running
/// process rather than terminating a genuinely stuck one. A caller that
/// specifically wants to *terminate* a still-running process should send
/// its own signal (e.g. `.terminate()`) before calling this, the way
/// `ProcessSupervisorResidueTests.terminateBoundedly` does.
enum BoundedProcessWait {
    static func wait(_ process: Process, timeoutSeconds: Double = 10) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            usleep(10000)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        var status: Int32 = 0
        // Blocking, not WNOHANG: safe here specifically because SIGKILL
        // cannot be caught or blocked, so a genuinely still-alive process
        // dies essentially immediately, and one some other mechanism
        // already reaped out from under us returns ECHILD immediately
        // instead of blocking -- there is no shape of "still alive but
        // never exits" left for this call to hang on the way
        // `waitUntilExit()` did.
        _ = waitpid(process.processIdentifier, &status, 0)
    }
}
