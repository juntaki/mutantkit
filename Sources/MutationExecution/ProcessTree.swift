import Darwin
import Foundation

/// Finds and kills a process's descendants.
///
/// This exists because killing a process group is not sufficient on its own. A
/// child spawned as a group leader takes its subtree with it *if* the subtree
/// stays in the group — and SwiftPM's test helper does not: it puts itself in a
/// new group, so `kill(-pgid)` never reaches the process actually running the
/// tests. A mutant whose tests loop forever then survives its own timeout,
/// holding the supervisor's pipe open and spinning indefinitely.
///
/// Reads the kernel's process table directly rather than shelling out to `ps`.
/// The supervisor is the thing that launches processes; having it launch one more
/// in order to clean up after a launch that went wrong invites the failure it is
/// trying to fix.
enum ProcessTree {
    /// Every descendant of `root`, deepest last.
    ///
    /// Must be called while `root` is still alive. Once it exits, its children are
    /// reparented to launchd and nothing remains to identify them as ours.
    static func descendants(of root: pid_t) -> [pid_t] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in table {
            childrenByParent[entry.ppid, default: []].append(entry.pid)
        }

        var found: [pid_t] = []
        var queue = childrenByParent[root] ?? []
        // The kernel cannot report a cycle, but a corrupt read must not become an
        // infinite loop inside the component whose job is to guarantee termination.
        var seen: Set<pid_t> = [root]

        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            found.append(next)
            queue.append(contentsOf: childrenByParent[next] ?? [])
        }

        return found
    }

    /// SIGKILLs each process and the group it leads.
    ///
    /// Both, because a descendant that escaped into its own group may have spawned
    /// children of its own that stayed with it. `kill` failing is expected and
    /// ignored: the target has usually already died, which is the outcome we
    /// wanted.
    static func forceKill(_ pids: [pid_t]) {
        for pid in pids {
            kill(pid, SIGKILL)
            // Only when it leads a group, or this would signal an unrelated one.
            if getpgid(pid) == pid {
                kill(-pid, SIGKILL)
            }
        }
    }

    /// True when the process exists and we may signal it. For tests and diagnosis.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Kernel process table

    private struct Entry {
        let pid: pid_t
        let ppid: pid_t
    }

    private static func processTable() -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        // Two calls: one to size the buffer, one to fill it. The table can grow
        // between them, so the second is allowed to fail and we simply report
        // nothing rather than read a short buffer.
        var length = 0
        guard sysctl(&name, UInt32(name.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }

        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: length / stride + 1)

        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            var size = length
            return sysctl(&name, UInt32(name.count), raw.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return [] }

        return buffer.prefix(length / stride).map {
            Entry(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid)
        }
    }
}
