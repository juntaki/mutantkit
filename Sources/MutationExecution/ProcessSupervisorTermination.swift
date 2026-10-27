import Foundation

// MARK: - Deterministic ownership close-out (F3)

//
// Split from ProcessSupervisor.swift's own declaration purely to keep that
// type's body under swiftlint's type_body_length ceiling — an `extension`
// in a separate file, not a different type, so everything below still
// resolves as ProcessSupervisor.<member> and shares its full context.

extension ProcessSupervisor {
    /// Times `ProcessTree.descendantIdentities(of:)`, accumulates whatever
    /// it finds into `observed` (never replaces — see `detectRootExit`'s
    /// own doc comment for why *continuous* accumulation across every poll,
    /// not a single snapshot, is what makes ancestry-based ownership
    /// survive `pid` exiting), and adapts `pollIntervalMicroseconds`
    /// (doubling, capped at `maxPollIntervalMicroseconds`, relaxing back
    /// toward the 1 ms baseline once polls are cheap again) so a poll that
    /// meaningfully exceeds the current interval — a large process table
    /// under real system load — backs this loop off gracefully instead of
    /// hammering an already-slow `sysctl` at a fixed cadence regardless of
    /// what that cadence now actually costs. Shared by `detectRootExit` and
    /// `closeOutOwnedGroup`, the two places that poll descendants.
    static func pollDescendants(
        of pid: pid_t, observed: inout Set<ProcessTree.ProcessIdentity>, pollIntervalMicroseconds: inout useconds_t
    ) {
        let pollStarted = Date()
        observed.formUnion(ProcessTree.descendantIdentities(of: pid))
        let pollDurationMicroseconds = Date().timeIntervalSince(pollStarted) * 1_000_000
        if pollDurationMicroseconds > Double(pollIntervalMicroseconds) {
            pollIntervalMicroseconds = min(pollIntervalMicroseconds * 2, maxPollIntervalMicroseconds)
        } else if pollIntervalMicroseconds > baselinePollIntervalMicroseconds {
            pollIntervalMicroseconds = max(pollIntervalMicroseconds / 2, baselinePollIntervalMicroseconds)
        }
    }

    /// Non-reaping peek: `true` once `pid` has exited, without ever
    /// consuming its zombie entry.
    ///
    /// F3 zero-base review Finding 2: `waitpid(pid, &status, WNOHANG)` —
    /// this codebase's previous detection mechanism — reaps the instant it
    /// reports a match, immediately freeing `pid` for the kernel to recycle
    /// to a completely unrelated process. Every caller of this function is
    /// required to defer its own *real*, consuming reap until every
    /// `-pid`/process-group signal it might send has already happened —
    /// only then can such a signal never reach a process the kernel has
    /// since reassigned that same numeric pid to. `WNOWAIT` is a real,
    /// kernel-enforced guarantee of this, not another observe-then-act
    /// race pushed to a different syscall pair the way a bare
    /// `kill(pid, 0)` / `getpgid(pid)` check-then-act pair would be:
    /// verified directly (a standalone spike, not committed here) that a
    /// pid peeked this way survives a 500-process rapid spawn/reap burst
    /// completely unreused, and only becomes reusable once a real,
    /// consuming `waitpid`/`waitid` call finally reaps it.
    static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        info.si_pid = 0
        let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return rc == 0 && info.si_pid == pid
    }

    /// `detectRootExit`'s own result — see that function's doc comment for
    /// what each case here means for `runBlocking`'s own subsequent
    /// handling.
    struct RootExitDetection {
        /// `true` when `pid` had already exited on its own (peeked via
        /// `hasExited`, never reaped) before any deadline/cancellation/
        /// stall fired; `false` when this loop broke out *because* one of
        /// those fired while `pid` was still running.
        let rootExitedOnItsOwn: Bool
        let stalled: Bool
        let observed: Set<ProcessTree.ProcessIdentity>
    }

    /// Polls continuously for two things at once, neither ever consuming
    /// `pid`'s zombie (see `hasExited`'s own doc comment): every descendant
    /// `pid` has ever forked, and whether `pid` itself has exited.
    ///
    /// **Why continuous descendant tracking, not a single snapshot.** The
    /// process group is the first defense but cannot be the only one:
    /// spawning the child as a group leader makes `kill(-pgid)` reach
    /// everything that stays in that group, and some things do not —
    /// SwiftPM's `swiftpm-testing-helper` puts *itself* into a new group,
    /// so the process actually running the mutated tests is unreachable
    /// that way. Measured: after killing the group of a mutant whose test
    /// loops forever, the helper survived with `PGID == PID` and
    /// `PPID == 1`, still burning half a core, and still holding the write
    /// end of our stdout pipe, so EOF never arrived and the supervisor
    /// itself blocked forever draining it. A *second*, independent gap sits
    /// beside that one: this same escape is reachable from a process that
    /// exits *promptly* too (a crash, not only a hang) — a snapshot taken
    /// only once, at the moment of a timeout, never fires at all on that
    /// path, so a descendant left behind by an otherwise-ordinary, on-time
    /// exit was previously never even looked for. Fixing that requires
    /// knowing the tree *before* the root is gone, since ancestry is the
    /// only proof a descendant is really ours, and it disappears the
    /// instant the root exits (reparented to launchd — confirmed directly,
    /// 5/5 trials with zero variance, by
    /// `ProcessSupervisorZeroBaseReviewFindingsTests
    /// .reparentingToLaunchdIsAlreadyCompleteTheInstantRootExits`). **How
    /// fast that window closes was measured directly, not assumed, and the
    /// answer forced the polling interval below far tighter than the
    /// original `waitpid` loop's own 10 ms:** a script that forks a
    /// background child and then exits can complete that *entire* round
    /// trip — including a fresh `python3` interpreter's own startup — in
    /// under 10 ms often enough that 10 ms polling missed the descendant
    /// roughly 9 times out of 10 in repeated real trials; even 5 ms polling
    /// still missed it more often than not. 2 ms was the first interval
    /// that caught it reliably (10/10), so this polls at 1 ms — one safety
    /// margin below that measured threshold, not an arbitrarily
    /// "tight-sounding" number. Accumulating every identity across every
    /// poll (`pollDescendants` above) is what makes that ancestry proof
    /// available *after* the root is already gone: `ProcessTree.reap(_:)`
    /// re-verifies each one (PID *and* recorded start time, surviving PID
    /// reuse) against the live table before ever signalling it. **The one
    /// gap this cannot close** — confirmed structurally, not just
    /// empirically, by F3's zero-base review — **is a descendant that
    /// forks, escapes its own process group, and whose root exits within
    /// the same observation window this loop's own polling frequency
    /// cannot shrink to zero.** A `kqueue`/`EVFILT_PROC` bounded spike
    /// (not committed here) confirmed `NOTE_TRACK`/`NOTE_CHILD` — the one
    /// kernel primitive that could close this atomically — is `ENOTSUP` on
    /// this Darwin kernel, and bare `NOTE_FORK` carries no child-pid
    /// payload; within the macOS APIs an ordinary, unprivileged CLI can
    /// use, no mechanism was found that removes this gap outright.
    /// `ProcessSupervisorZeroBaseReviewFindingsTests
    /// .groupEscapedDescendantIsUnrecoverableAfterZeroObservationWindow`
    /// pins this as a deterministic, timing-independent fact rather than a
    /// probabilistic one. Resolving what `ProcessSupervisor`'s own
    /// ownership contract should say about this case is open F3 design
    /// work, not something this loop's polling frequency can paper over.
    static func detectRootExit(
        for pid: pid_t, policy: SupervisionPolicy, pollIntervalMicroseconds: inout useconds_t
    ) -> RootExitDetection {
        let stallDetection = policy.stallDetection
        let cancellationFlag = policy.cancellationFlag
        let deadline = Date().addingTimeInterval(policy.timeoutSeconds)
        var observed: Set<ProcessTree.ProcessIdentity> = []

        // Tracks `stallDetection.progressFilePath`'s own
        // size — deliberately just a byte count, not any understanding of
        // what the file contains — resetting `lastProgressAt` whenever it
        // grows, checked no more often than `checkIntervalSeconds` so this
        // never adds meaningful overhead to the tight descendant-polling
        // loop below. `nil` `stallDetection` (every caller before Gate 3
        // Phase H10, and every caller that does not opt in) makes this
        // whole block dead code — `lastStallCheckAt`/`lastProgressSize`
        // never read, `isStalled()` never called.
        func progressFileSize() -> Int64? {
            guard let stallDetection else { return nil }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: stallDetection.progressFilePath.path) else {
                return nil
            }
            return attributes[.size] as? Int64
        }

        var lastProgressSize = progressFileSize() ?? 0
        var lastProgressAt = Date()
        var lastStallCheckAt = Date()

        func isStalled() -> Bool {
            guard let stallDetection else { return false }
            let now = Date()
            guard now.timeIntervalSince(lastStallCheckAt) >= stallDetection.checkIntervalSeconds else { return false }
            lastStallCheckAt = now
            if let currentSize = progressFileSize(), currentSize > lastProgressSize {
                lastProgressSize = currentSize
                lastProgressAt = now
                return false
            }
            return now.timeIntervalSince(lastProgressAt) >= stallDetection.stallTimeoutSeconds
        }

        while true {
            pollDescendants(of: pid, observed: &observed, pollIntervalMicroseconds: &pollIntervalMicroseconds)
            if hasExited(pid) {
                // An on-time, non-timeout exit — the path a single
                // at-deadline snapshot could never reach at all. `pid`
                // is *not* reaped here (see `hasExited`'s own doc
                // comment) — `runBlocking` is responsible for the
                // ownership close-out and deferred final reap that
                // follow.
                return RootExitDetection(rootExitedOnItsOwn: true, stalled: false, observed: observed)
            }

            // F3: cancellation is checked exactly like the absolute
            // deadline above it — the same break, into the same
            // ownership close-out `runBlocking` runs either way, never a
            // second, independently maintained teardown path.
            // `cancellationFlag` is set by `run(...)`'s own
            // `withTaskCancellationHandler`, from whatever thread
            // requested cancellation — this poll loop is the only place
            // that ever observes it, since nothing in this blocking
            // implementation has a cooperative suspension point of its
            // own.
            if Date() >= deadline || cancellationFlag.isCancelled {
                return RootExitDetection(rootExitedOnItsOwn: false, stalled: false, observed: observed)
            }
            if isStalled() {
                return RootExitDetection(rootExitedOnItsOwn: false, stalled: true, observed: observed)
            }
            // 1 ms baseline, not the coarser granularity a build's own
            // timeout would suggest is "plenty" — see this function's own
            // doc comment for the measurements that ruled out every coarser
            // fixed interval tried, and for why this adapts upward under load.
            usleep(pollIntervalMicroseconds)
        }
    }

    /// TERM -> bounded grace -> KILL if still alive, on the process group
    /// `pid` leads plus every individually tracked `observed` identity.
    ///
    /// Safe to call regardless of whether `pid` has already exited (an
    /// unreaped zombie — `detectRootExit` returned
    /// `rootExitedOnItsOwn == true`) or is still running (a real
    /// timeout/cancellation while it was still alive): the caller must not
    /// have reaped `pid` yet either way (see `hasExited`'s own doc
    /// comment) — every signal below happens strictly before the caller's
    /// own final, consuming reap, so `pid` cannot have been recycled to an
    /// unrelated process, let alone an unrelated process-group leader, by
    /// the time any of them are sent.
    ///
    /// Unconditional, never shortcut to "nothing in `observed` looks
    /// alive, skip the group signal": `kill(-pid, ...)` reaches every
    /// process-group member by PGID alone, including a same-group
    /// descendant continuous polling never individually observed — the
    /// same real gap `ProcessSupervisorResidueTests
    /// .promptExitReapsAChildInTheSameGroup`'s own fixture (a `tail -f
    /// ... /dev/null` that never touches the supervised pipe) exists to
    /// pin, and the reason this must never be reduced to "only signal
    /// what `observed` already contains."
    ///
    /// Every exit sends a group SIGKILL, and is only reported verified if a
    /// bounded re-check afterwards reads the process table and finds the
    /// root exited, no tracked descendant running and no other member of
    /// the root's process group running. An unreadable table, or a survivor
    /// at the end of `postKillVerificationSeconds`, returns
    /// `verified == false` — never a silent success. `allDead()` before the
    /// kill is not enough on its own: it sees only the root and `observed`,
    /// and with nothing observed it never reads the table.
    static func closeOutOwnedGroup(
        pid: pid_t, observed: inout Set<ProcessTree.ProcessIdentity>, policy: SupervisionPolicy,
        pollIntervalMicroseconds: inout useconds_t
    ) -> CleanupVerification {
        let readTable = policy.processTableReader
        // `ProcessTree.isRunning`, not `isAlive`: a descendant this process
        // is not the real OS parent of (a grandchild, reparented to
        // launchd once its own direct parent also exits) only ever gets
        // reaped by launchd's own, unpredictably timed pass — `isAlive`
        // reports a zombie as "alive" until that happens, which measurably
        // kept this grace loop waiting out its *entire* configured period
        // on every call, even for a descendant SIGTERM had already and
        // successfully killed seconds earlier. See `ProcessTree.isRunning`'s
        // own doc comment. An unreadable process table reads as "still
        // running", so a failed `sysctl` escalates to SIGKILL, never skips it.
        func allDead() -> Bool {
            guard policy.rootExitProbe(pid) else { return false }
            let table = readTable()
            return !observed.contains { ProcessTree.isRunning($0, in: table) }
        }
        // `allDead()` sees only the root and `observed`, so a close-out it
        // ends before SIGKILL still sends the group SIGKILL: a same-group
        // descendant polling never observed, and that ignores SIGTERM, would
        // otherwise outlive a close-out reported verified. The same re-check
        // as the escalation path then confirms the group really emptied.
        // Safe for the same reason as every signal here: `pid` is still
        // unreaped.
        func groupKillThenVerify() -> CleanupVerification {
            kill(-pid, SIGKILL)
            policy.lifecycleEventHook?(.groupSignal(pid: pid, signal: SIGKILL))
            return verifyAfterKill(
                pid: pid, observed: observed, everyIdentityChecked: true, readTable: readTable,
                rootExitProbe: policy.rootExitProbe
            )
        }

        // Politely first, to the group and to anything that left it —
        // `signal(_:_:)` re-verifies provenance before this ever reaches a
        // stale/reused PID, so a SIGTERM is exactly as safe to send here as
        // the SIGKILL below.
        kill(-pid, SIGTERM)
        policy.lifecycleEventHook?(.groupSignal(pid: pid, signal: SIGTERM))
        ProcessTree.signal(observed, SIGTERM, readTable: readTable)

        guard !allDead() else { return groupKillThenVerify() }
        let graceDeadline = Date().addingTimeInterval(policy.terminationGracePeriodSeconds)
        while Date() < graceDeadline, !allDead() {
            pollDescendants(of: pid, observed: &observed, pollIntervalMicroseconds: &pollIntervalMicroseconds)
            if allDead() { break }
            // F3 zero-base review Finding 3: a cancellation arriving
            // mid-grace must not sit out the remainder of
            // `terminationGracePeriodSeconds` when it is *this same
            // escalation* already in flight — escalate to KILL
            // immediately rather than waiting out a SIGTERM grace that
            // cancellation itself has already decided not to honor.
            if policy.cancellationFlag.isCancelled { break }
            usleep(pollIntervalMicroseconds)
        }
        guard !allDead() else { return groupKillThenVerify() }

        kill(-pid, SIGKILL)
        policy.lifecycleEventHook?(.groupSignal(pid: pid, signal: SIGKILL))
        let everyIdentityChecked = ProcessTree.reap(observed, readTable: readTable)
        return verifyAfterKill(
            pid: pid, observed: observed, everyIdentityChecked: everyIdentityChecked, readTable: readTable,
            rootExitProbe: policy.rootExitProbe
        )
    }

    /// Reaps the root after close-out and returns its wait status.
    ///
    /// When close-out could not be verified because the root still had not
    /// exited after SIGKILL, it may never exit (for example, stuck in an
    /// uninterruptible sleep). A blocking `waitpid` here would then keep
    /// the unverified result, and with it the run's abort, from ever
    /// reaching the caller. So in that case the reap moves to a detached
    /// thread, and the status reads as killed by SIGKILL. Until that reap
    /// completes the pid stays unreaped, so it still cannot be reused.
    static func reapRoot(pid: pid_t, cleanup: CleanupVerification, policy: SupervisionPolicy) -> Int32 {
        let hook = policy.lifecycleEventHook
        guard cleanup.verified || policy.rootExitProbe(pid) else {
            Thread.detachNewThread {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                hook?(.finalReap(pid: pid))
            }
            return SIGKILL
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        hook?(.finalReap(pid: pid))
        return status
    }

    /// Whether close-out proved containment. See `closeOutOwnedGroup`.
    struct CleanupVerification {
        let verified: Bool
        let diagnosis: String?

        static let verified = CleanupVerification(verified: true, diagnosis: nil)
    }

    /// How long the post-SIGKILL re-check waits for the kernel to finish
    /// tearing down killed processes. SIGKILL cannot be caught, so a
    /// healthy kill settles well inside this; the bound only exists so an
    /// unreadable table cannot stall close-out.
    static let postKillVerificationSeconds: Double = 5

    /// The bounded re-check after SIGKILL. `everyIdentityChecked == false`
    /// means `reap` had to skip at least one identity because it could not
    /// read the table; that identity may still be running unsignalled, so
    /// it is reported even if a later read succeeds and shows nothing.
    ///
    /// Besides `observed`, this lists the root's process group by PGID, so
    /// a same-group member polling never saw is caught too. A member forked
    /// while the group SIGKILL was being delivered can escape it, so a
    /// running member found here gets the group SIGKILL again before the
    /// next read. That is safe because `pid` is still unreaped, so no
    /// unrelated process can lead a group with that ID.
    private static func verifyAfterKill(
        pid: pid_t, observed: Set<ProcessTree.ProcessIdentity>, everyIdentityChecked: Bool,
        readTable: ProcessTree.TableReader, rootExitProbe: (pid_t) -> Bool
    ) -> CleanupVerification {
        let deadline = Date().addingTimeInterval(postKillVerificationSeconds)
        var lastProblem = "the process table could not be read"
        while true {
            if let table = readTable() {
                let groupSurvivors = ProcessTree.runningGroupMembers(pid, excluding: pid, in: table)
                let survivors = Set(observed.filter { ProcessTree.isRunning($0, in: table) }.map(\.pid))
                    .union(groupSurvivors.map(\.pid))
                if survivors.isEmpty, rootExitProbe(pid) {
                    if everyIdentityChecked { return .verified }
                    return CleanupVerification(
                        verified: false,
                        diagnosis: """
                        SIGKILL escalation skipped at least one tracked descendant of pid \(pid) because the process table \
                        could not be read to verify its identity, so its termination is unproven
                        """
                    )
                }
                if !groupSurvivors.isEmpty { kill(-pid, SIGKILL) }
                let survivorPIDs = survivors.sorted().map(String.init).joined(separator: ", ")
                lastProblem = survivors.isEmpty ? "root pid \(pid) had not exited" : "still running: \(survivorPIDs)"
            } else {
                lastProblem = "the process table could not be read"
            }
            if Date() >= deadline { break }
            usleep(10000)
        }
        return CleanupVerification(
            verified: false,
            diagnosis: """
            descendant cleanup of pid \(pid) could not be verified \(String(format: "%.0f", postKillVerificationSeconds))s \
            after SIGKILL (\(lastProblem))
            """
        )
    }

    /// Waits for `drainGroup`, bounded by `timeoutSeconds`, but polled in
    /// short slices so a `cancellationFlag` set mid-wait is noticed
    /// promptly rather than only after the full bound elapses — unlike a
    /// single `drainGroup.wait(timeout:)` call, which
    /// `ProcessSupervisorZeroBaseReviewFindingsTests
    /// .cancellationAfterRootExitEscalatesPromptlyRatherThanWaitingOutTheDrain`
    /// measured taking the entire bound (~5s) regardless of cancellation
    /// (F3 zero-base review Finding 3).
    static func waitForDrain(
        _ drainGroup: DispatchGroup, timeoutSeconds: Double, cancellationFlag: CancellationFlag
    ) -> DispatchTimeoutResult {
        let sliceSeconds = 0.05
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }
            if drainGroup.wait(timeout: .now() + min(sliceSeconds, remaining)) == .success { return .success }
            if cancellationFlag.isCancelled { return .timedOut }
        }
    }
}
