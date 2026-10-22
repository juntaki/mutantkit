import Foundation
import MutationExecution

public extension SimulatorPool {
    // MARK: - Worker-pool cloning

    /// Every MutantKit-created clone's name carries this prefix, so a later
    /// run can find exactly the clones this tool created and nothing else,
    /// regardless of what a developer has named their own simulators.
    /// `simctl clone`'s new-name argument accepts any string; nothing about
    /// this prefix is special to CoreSimulator, it is purely a convention
    /// this type imposes and later greps for.
    ///
    /// Every clone's name also embeds the PID of the process that created
    /// it (`ownedCloneLabel(_:)`), so `cleanupOrphanClones()` can tell a
    /// clone that belongs to a *currently running* MutantKit process (do
    /// not touch — it may still be mid-test) apart from one whose owning
    /// process is confirmed dead (safe to sweep). Without this, a global
    /// sweep by name prefix alone could delete a concurrently-running run's
    /// live devices — see `parseOwnerPID(fromCloneName:)`.
    static let clonePrefix = "mutantkit-clone-"

    /// Builds the full label passed to `cloneDevice(from:label:)`, embedding
    /// this process's PID ahead of the caller-supplied, human-readable
    /// suffix. Format: `<pid>-<suffix>`. Parsed back by
    /// `parseOwnerPID(fromCloneName:)`.
    private static func ownedCloneLabel(_ suffix: String) -> String {
        "\(ProcessInfo.processInfo.processIdentifier)-\(suffix)"
    }

    /// Recovers the owning process's PID from a clone's full device name
    /// (`clonePrefix` + `ownedCloneLabel(_:)`'s output), if the name is
    /// shaped as this pool itself would have produced it. A clone name that
    /// does not parse (e.g. hand-created, or from a version of this tool
    /// predating PID-embedding) is treated as ownerless — `cleanupOrphanClones`
    /// still sweeps it, matching this method's only caller's own fallback.
    internal static func parseOwnerPID(fromCloneName name: String) -> Int32? {
        guard name.hasPrefix(clonePrefix) else { return nil }
        let remainder = name.dropFirst(clonePrefix.count)
        guard let dashIndex = remainder.firstIndex(of: "-") else { return nil }
        return Int32(remainder[remainder.startIndex ..< dashIndex])
    }

    /// Mirrors `RunIsolationLock`'s own private `processIsAlive(_:)` exactly
    /// (`kill(pid, 0) == 0` means alive and signalable; `errno == EPERM`
    /// means alive but owned by another user, e.g. root) — duplicated here
    /// rather than shared because that method is private to its own file.
    private static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    enum SimulatorCloneError: Error, CustomStringConvertible, Sendable {
        case cloneFailed(source: String, detail: String)
        case cloneNotFound(udid: String)
        case bootFailed(udid: String, detail: String)

        public var description: String {
            switch self {
            case let .cloneFailed(source, detail):
                "Could not clone simulator \(source): \(detail)"
            case let .cloneNotFound(udid):
                "simctl clone reported UDID \(udid), but it does not appear in `simctl list` afterward."
            case let .bootFailed(udid, detail):
                "Clone \(udid) could not be booted: \(detail)"
            }
        }
    }

    /// Clones `source` via `simctl clone`, then re-lists devices so the
    /// clone's full `SimulatorDevice` record (name, runtime, state) is
    /// known — `simctl clone` itself only ever prints the new UDID, never
    /// the rest of the record.
    ///
    /// Does **not** boot or lease the clone; callers needing a ready
    /// device call `prepare(udid:)` afterward, same as any other device —
    /// cloning and booting are kept as separate steps for the same reason
    /// leasing and booting already are (see this type's own doc comment).
    func cloneDevice(from source: SimulatorDevice, label: String) async throws -> SimulatorDevice {
        let name = "\(Self.clonePrefix)\(label)"
        let result: ProcessResult
        do {
            result = try await runProcess(
                ToolPaths.xcrun, ["simctl", "clone", source.udid, name],
                workingDirectory, timeoutSeconds
            )
        } catch {
            throw SimulatorCloneError.cloneFailed(source: source.udid, detail: "\(error)")
        }

        guard result.succeeded else {
            throw SimulatorCloneError.cloneFailed(
                source: source.udid,
                detail: OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let newUDID = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Force a fresh `simctl list` — the clone did not exist at the
        // last load, and a stale cache would report it missing forever.
        loaded = false
        try await loadIfNeeded()

        guard let device = devices.first(where: { $0.udid == newUDID }) else {
            throw SimulatorCloneError.cloneNotFound(udid: newUDID)
        }
        return device
    }

    /// Deletes a device via `simctl delete`. The caller is responsible for
    /// only ever passing a UDID this pool itself created (`cloneDevice`) —
    /// this method has no way to verify that and does not try to; see
    /// `releaseWorkerPool`/`cleanupOrphanClones`, the two call sites that
    /// actually enforce the `clonePrefix` naming convention before ever
    /// reaching here.
    func deleteDevice(udid: String) async throws {
        guard !leased.contains(udid) else {
            throw SimulatorPoolError.deviceIsLeased(udid: udid)
        }

        // Best-effort shutdown first: `simctl delete` has been observed to
        // succeed against an already-booted device directly, but shutting
        // down first is the documented-safe order and costs nothing when
        // the device is already shut down (a no-op, exit code ignored).
        _ = try? await runProcess(ToolPaths.xcrun, ["simctl", "shutdown", udid], workingDirectory, timeoutSeconds)

        let result = try await runProcess(ToolPaths.xcrun, ["simctl", "delete", udid], workingDirectory, timeoutSeconds)
        guard result.succeeded else {
            throw SimulatorPoolError.simctlFailed(
                detail: "could not delete \(udid): "
                    + OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        devices.removeAll { $0.udid == udid }
    }

    /// Provisions `count` devices for worker-affinity assignment: index 0
    /// is `base` itself — the pool must never delete, shut down, or
    /// otherwise treat as disposable a device it did not create — and
    /// indices `1..<count` are fresh clones of `base`, each booted and
    /// `bootstatus`-verified before this returns.
    ///
    /// **`base` is shut down before cloning, if it is booted, and rebooted
    /// afterward.** Confirmed directly against a real simulator, not
    /// assumed: `simctl clone` refuses to clone a booted source
    /// (`"Unable to clone device in current state: Booted"`, exit 405) —
    /// a real constraint this method works around rather than documents
    /// as a caller's problem, since the realistic caller
    /// (`RunCommand.provisionSimulatorWorkerPoolIfNeeded`) only ever
    /// reaches this *after* `prepareSimulatorForRun()` has already booted
    /// `base` for the run's own baseline. Every clone is created while
    /// `base` is shut down, then `base` and every clone are booted
    /// together at the end — never booted, cloned-from, then rebooted
    /// per clone, which would pay the boot/shutdown cost once per clone
    /// instead of once total.
    ///
    /// Throws, rather than returning a partial pool, on the first clone or
    /// boot failure: a caller that received fewer devices than it asked
    /// for with no error would silently under-parallelize with no signal
    /// at all — exactly the "never silently reduce worker count without
    /// reporting it" requirement this feature is held to. Every clone
    /// already created before the failure is deleted before the error
    /// propagates, so a failed provision leaves no orphaned clones behind
    /// for `cleanupOrphanClones` to find on some later, unrelated run. If
    /// `base` itself had to be shut down to make cloning possible, this
    /// method always attempts to reboot it before returning or throwing —
    /// a caller must never be left with a `base` this method quietly put
    /// to sleep and never woke back up.
    func provisionWorkerPool(base: SimulatorDevice, count: Int) async throws -> [SimulatorDevice] {
        guard count > 1 else { return [base] }

        // Defense-in-depth, matching `deleteDevice`'s own guard: this call
        // is about to shut `base` down out from under whatever holds it, so
        // it must not proceed if this same pool instance has `base` leased
        // to an in-flight test right now.
        guard !leased.contains(base.udid) else {
            throw SimulatorPoolError.deviceIsLeased(udid: base.udid)
        }

        // `base.isBooted` (the caller's own copy) is not trusted here: the
        // realistic caller (`RunCommand`) resolves its `SimulatorDevice`
        // value *before* `prepareSimulatorForRun()` boots it, so that
        // value's own `state` field reads stale ("Shutdown") even once the
        // real device is actually booted -- confirmed the hard way, by a
        // unit test written against exactly this sequence that failed
        // against the caller's-copy check and only passed once this was
        // switched to a fresh, forced re-list. Never skip the shutdown
        // step on a state field that might be lying.
        loaded = false
        try await loadIfNeeded()
        let wasBaseBooted = devices.first(where: { $0.udid == base.udid })?.isBooted ?? base.isBooted
        if wasBaseBooted {
            _ = try? await runProcess(ToolPaths.xcrun, ["simctl", "shutdown", base.udid], workingDirectory, timeoutSeconds)
        }

        var provisioned: [SimulatorDevice] = [base]

        do {
            for index in 1 ..< count {
                let clone = try await cloneDevice(from: base, label: Self.ownedCloneLabel("worker\(index)-\(UUID().uuidString.prefix(8))"))
                // Recorded *before* `prepare`, not after: a boot failure
                // must still roll this clone back. Appending only on
                // success left a booted-but-failed clone permanently
                // untracked and undeleted -- caught by
                // `SimulatorPoolCloningTests.provisionBootFailureRollsBack`.
                provisioned.append(clone)
            }
            // Every device -- base included -- boots only after every
            // clone already exists, so a boot never has to be redone.
            for device in provisioned {
                try await prepare(udid: device.udid)
            }
        } catch {
            if wasBaseBooted {
                _ = try? await prepare(udid: base.udid)
            }
            // Roll back every clone this call itself created — never
            // `base`, and never a clone some other, unrelated call created
            // (provisioned only ever contains this call's own additions
            // past index 0).
            for created in provisioned.dropFirst() {
                _ = try? await deleteDevice(udid: created.udid)
            }
            throw error
        }

        return provisioned
    }

    /// Deletes every clone `provisionWorkerPool` created — every element
    /// of `devices` except `base` itself, which this method never deletes
    /// regardless of what is passed. Best-effort per device: one failed
    /// deletion is recorded and every other deletion still proceeds,
    /// rather than aborting the whole cleanup — an orphaned clone
    /// `cleanupOrphanClones` will find on the next run is a far cheaper
    /// failure mode than leaving nine other clones undeleted because the
    /// tenth failed.
    ///
    /// Returns the UDIDs that failed to delete, for the caller to log —
    /// never thrown, since cleanup failing is not this run's own result to
    /// fail on.
    @discardableResult
    func releaseWorkerPool(_ devices: [SimulatorDevice], base: SimulatorDevice) async -> [String] {
        var failures: [String] = []
        for device in devices where device.udid != base.udid {
            do {
                try await deleteDevice(udid: device.udid)
            } catch {
                failures.append(device.udid)
            }
        }
        return failures
    }

    /// Finds and deletes every simulator already on this machine whose
    /// name carries `clonePrefix` **and** whose embedded owning PID
    /// (`parseOwnerPID(fromCloneName:)`) is confirmed dead — orphans left
    /// behind by a process that was killed before `releaseWorkerPool` ever
    /// ran (a crash, a `SIGKILL`, a forced quit).
    ///
    /// Deliberately does **not** delete a clone whose owning PID is still
    /// alive: that clone belongs to a concurrently-running MutantKit
    /// process (a different project, or the same project on a different
    /// destination) that may still be mid-test against it. Without this
    /// check, a global sweep by name prefix alone could delete another
    /// live run's devices out from under it — found by adversarial review
    /// of this exact method before it shipped. A clone name that does not
    /// parse as this pool's own PID-embedding format (e.g. hand-created,
    /// or produced by a version of this tool that predates PID-embedding)
    /// is still swept, since there is no owner to check aliveness against.
    ///
    /// Intended to be called once, early, by any entry point that is about
    /// to provision a fresh worker pool — so a machine that has
    /// accumulated orphaned clones across several interrupted runs is
    /// swept clean before adding more, rather than accumulating them
    /// indefinitely. Safe to call even when nothing needs cleaning: an
    /// empty match list does nothing.
    ///
    /// Matches on name only (plus the PID-liveness check above), the same
    /// pragmatic, not-symbol-resolved convention this codebase already uses
    /// elsewhere (`OperatorExclusions`' builder-property-name matching,
    /// `LifecycleSuperCallRemovalOperator`'s method-name denylist) — a
    /// developer's own simulator named with this exact prefix by
    /// coincidence is an accepted, vanishingly unlikely false positive, not
    /// a risk this type tries to eliminate further.
    @discardableResult
    func cleanupOrphanClones() async -> [String] {
        loaded = false
        try? await loadIfNeeded()

        let candidates = devices.filter { $0.name.hasPrefix(Self.clonePrefix) }
        let orphans = candidates.filter { candidate in
            guard let ownerPID = Self.parseOwnerPID(fromCloneName: candidate.name) else {
                // Unparseable name: no owner to check, treat as an orphan.
                return true
            }
            return !Self.processIsAlive(ownerPID)
        }
        var failures: [String] = []
        for orphan in orphans {
            do {
                try await deleteDevice(udid: orphan.udid)
            } catch {
                failures.append(orphan.udid)
            }
        }
        return failures
    }
}
