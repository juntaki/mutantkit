import Darwin

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
    /// A descendant's identity, not just its number.
    ///
    /// `pid_t` is a small, kernel-recycled counter — the OS is free to hand the
    /// exact same number to a completely unrelated process the moment ours frees
    /// it. Pairing a PID with the start time the kernel recorded for it turns
    /// "this PID" into "this specific process instance": a later process that
    /// reused the number necessarily has a different start time, so a check
    /// against both together can never true-positive on an impostor. This is
    /// the identity `reap(_:)` re-verifies against the live table before
    /// signalling anything — see that function's own doc comment for why a
    /// snapshot recorded once, is not, by itself, safe to act on later.
    struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startTimeSeconds: Int
        let startTimeMicroseconds: Int32
    }

    /// Every descendant of `root`, deepest last.
    ///
    /// Must be called while `root` is still alive. Once it exits, its children are
    /// reparented to launchd and nothing remains to identify them as ours.
    static func descendants(of root: pid_t) -> [pid_t] {
        descendantIdentities(of: root).map(\.pid)
    }

    /// Same walk as `descendants(of:)`, but keeping each descendant's start
    /// time alongside its PID — the raw material `reap(_:)` needs to verify
    /// provenance later, after `root` may no longer be alive to vouch for the
    /// ancestry chain itself. See that function and `ProcessIdentity` for why
    /// the plain PID this returns is not enough on its own once any real time
    /// has passed since this call.
    static func descendantIdentities(of root: pid_t) -> [ProcessIdentity] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var childrenByParent: [pid_t: [Entry]] = [:]
        for entry in table {
            childrenByParent[entry.ppid, default: []].append(entry)
        }

        var found: [ProcessIdentity] = []
        var queue = childrenByParent[root] ?? []
        // The kernel cannot report a cycle, but a corrupt read must not become an
        // infinite loop inside the component whose job is to guarantee termination.
        var seen: Set<pid_t> = [root]

        while let next = queue.popLast() {
            guard seen.insert(next.pid).inserted else { continue }
            found.append(next.identity)
            queue.append(contentsOf: childrenByParent[next.pid] ?? [])
        }

        return found
    }

    /// SIGKILLs each process and the group it leads.
    ///
    /// Both, because a descendant that escaped into its own group may have spawned
    /// children of its own that stayed with it. `kill` failing is expected and
    /// ignored: the target has usually already died, which is the outcome we
    /// wanted.
    ///
    /// Takes bare PIDs, not `ProcessIdentity` — every existing call site kills
    /// immediately after its own fresh `descendants(of:)` snapshot, while the
    /// ancestry that snapshot proved is still fresh (no real time has passed
    /// for the kernel to recycle anything). `reap(_:)` is the function for a
    /// PID set observed at some *earlier* point and acted on later.
    static func forceKill(_ pids: [pid_t]) {
        for pid in pids {
            kill(pid, SIGKILL)
            // Only when it leads a group, or this would signal an unrelated one.
            if getpgid(pid) == pid {
                kill(-pid, SIGKILL)
            }
        }
    }

    /// SIGKILLs every identity whose provenance is still verifiable against
    /// the *current* process table — the delayed counterpart to `forceKill`.
    ///
    /// This exists for exactly one shape of caller: something that observed a
    /// set of descendants at various points *while* a supervised process was
    /// alive (continuous polling, not one snapshot), and now — after that
    /// process has already exited, possibly seconds later — needs to reclaim
    /// whatever of that set is still running. By the time this runs, `root`'s
    /// own ancestry link to any survivor is already gone (reparented to
    /// launchd), so nothing here can re-derive "is this really one of ours"
    /// from parentage. `ProcessIdentity`'s start-time pairing is what stands
    /// in for that proof instead: a PID still alive with the *same* start
    /// time it had when first observed is, with overwhelming probability, the
    /// same process instance, never a same-numbered stranger — the kernel
    /// would have to both recycle the PID and coincidentally reuse the exact
    /// microsecond-resolution start time, which is not expected to occur in
    /// practice. A PID alive with a *different* start time is left alone
    /// unconditionally: that is the whole safety property this function
    /// exists to provide, minimized to the narrowest window `signal(_:_:)`'s
    /// own doc comment can achieve — never traded away for a simpler
    /// bare-PID kill here, and never claimed as a stronger, kernel-enforced
    /// atomic guarantee it cannot actually be (see that doc comment for why).
    static func reap(_ identities: some Sequence<ProcessIdentity>) {
        signal(identities, SIGKILL)
    }

    /// `reap(_:)`, generalized to any signal — the same provenance
    /// re-verification, used for the polite SIGTERM pass a timeout sends
    /// before escalating. Sending a lesser signal is not a reason to relax
    /// the check: an unrelated process that happens to hold a recycled PID
    /// deserves no signal from us at all, polite or otherwise.
    ///
    /// **Re-verifies each identity individually, immediately before *that*
    /// identity's own direct `kill` call — never once against a single
    /// batch-wide snapshot shared across the whole set.** An earlier version
    /// of this function read the process table exactly once at the top of
    /// this loop and reused that one snapshot for every identity — flagged
    /// in review as a real gap: for a `identities` set with many entries,
    /// the snapshot backing a `kill` call late in the loop could already be
    /// meaningfully stale by the time that iteration runs, widening the
    /// window in which a verified PID exits and gets recycled before this
    /// function actually signals it. Re-reading fresh per identity (via
    /// `isAlive(_:)`, itself one `processTable()` call) narrows that window,
    /// for the direct kill, to "one `sysctl` call, immediately followed by
    /// one `kill` call" — the practical minimum achievable in userspace,
    /// since macOS has no `pidfd`-equivalent primitive that would let a
    /// caller signal "this exact, already-verified process instance"
    /// atomically. **This is a real, honest limitation, not fully
    /// eliminated by this change, and it does not extend past the direct
    /// kill**: the `getpgid`/group-kill pair immediately below is *not*
    /// re-verified against a fresh `isAlive` check of its own (flagged in
    /// review) — if the process exits and its PID is recycled as an
    /// unrelated group leader in the instant between the direct `kill` and
    /// `getpgid`, the group signal could reach that unrelated group. Closing
    /// that too would only push the identical, structurally-unclosable race
    /// one syscall further, not eliminate it, so this is left as the same
    /// "best-effort, not a hard kernel guarantee" character
    /// `ProcessSupervisor`'s own existing process-group signalling already
    /// has, not silently assumed to be atomic.
    static func signal(_ identities: some Sequence<ProcessIdentity>, _ signalNumber: Int32) {
        for identity in identities {
            guard isAlive(identity) else { continue }
            kill(identity.pid, signalNumber)
            if getpgid(identity.pid) == identity.pid {
                kill(-identity.pid, signalNumber)
            }
        }
    }

    /// True when the process exists and we may signal it. For tests and diagnosis.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// True only when `identity`'s exact process instance — not just its PID
    /// number — is still alive, per the same provenance check `reap(_:)`
    /// uses. Deliberately does **not** distinguish a zombie (already
    /// signalled and dead, just not yet reaped by whichever ancestor is
    /// responsible — possibly launchd, for a descendant this process is
    /// not the real parent of) from a genuinely still-running process: a
    /// zombie still occupies its pid/table entry and still needs `reap(_:)`
    /// (or an ancestor's own eventual wait) before that pid becomes safe to
    /// recycle, so most existing callers correctly want "true" for either.
    /// For tests and diagnosis, and (unlike `isRunning(_:)` below) safe to
    /// use as a general-purpose "does this still occupy its slot" check.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        processTable().contains { $0.identity == identity }
    }

    /// `true` only when `identity` is genuinely still running — a zombie
    /// (exited, signalled, but not yet reaped) reports `false` here, unlike
    /// `isAlive(_:)` above.
    ///
    /// Exists for exactly one shape of caller: something that already sent
    /// a termination signal and needs to know "is there still more work to
    /// do," where a zombie means no — `ProcessSupervisor`'s own
    /// `closeOutOwnedGroup` escalation grace loop is the motivating case.
    /// Using `isAlive(_:)` there instead measurably kept that loop waiting
    /// out its *entire* configured grace period on every call, even for a
    /// descendant SIGTERM had already and successfully killed seconds
    /// earlier: a descendant `ProcessSupervisor` is not the real OS parent
    /// of (a grandchild, reparented to launchd once its own direct parent
    /// also exits) only ever gets reaped by launchd's own, unpredictably
    /// timed pass — an ancestor-external event this process cannot cause
    /// or observe faster by polling `isAlive(_:)` harder, and must not
    /// wait on to decide whether escalation is still needed.
    static func isRunning(_ identity: ProcessIdentity) -> Bool {
        processTable().contains { $0.identity == identity && !$0.isZombie }
    }

    // MARK: - Kernel process table

    private struct Entry {
        let pid: pid_t
        let ppid: pid_t
        let startTimeSeconds: Int
        let startTimeMicroseconds: Int32
        let isZombie: Bool

        var identity: ProcessIdentity {
            ProcessIdentity(pid: pid, startTimeSeconds: startTimeSeconds, startTimeMicroseconds: startTimeMicroseconds)
        }
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

        // `p_stat == SZOMB` (5, `<sys/proc.h>` — not imported into Swift by
        // the Darwin module, so the raw value is used directly, the same
        // way this file already uses raw signal numbers elsewhere) is the
        // kernel's own zombie marker: exited and signalled, occupying its
        // table entry only until reaped.
        let zombieState: Int8 = 5
        return buffer.prefix(length / stride).map {
            Entry(
                pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid,
                startTimeSeconds: $0.kp_proc.p_starttime.tv_sec, startTimeMicroseconds: Int32($0.kp_proc.p_starttime.tv_usec),
                isZombie: $0.kp_proc.p_stat == zombieState
            )
        }
    }
}
