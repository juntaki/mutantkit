@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Unit tests for `SimulatorPool`'s Phase C4 clone-lifecycle additions
/// (`cloneDevice`/`deleteDevice`/`provisionWorkerPool`/`releaseWorkerPool`/
/// `cleanupOrphanClones`), using an injected `ProcessRunner` backed by a
/// small in-memory device-list model — mutable, so `simctl clone`/`delete`
/// calls actually change what a subsequent `simctl list` reports, the same
/// way real `simctl` state evolves across calls. `SimulatorPoolLifecycleTests`'
/// static-JSON scripting is enough for `prepare(udid:)`'s own boot sequence
/// (the device list never changes there); this needs more.
@Suite("Simulator pool: clone lifecycle (Phase C4)")
struct SimulatorPoolCloningTests {
    private static let workingDirectory = FileManager.default.temporaryDirectory
    private static let baseUDID = "BASE0000-0000-0000-0000-000000000001"
    private static let baseName = "iPhone 16"
    private static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"

    private static func success(_ stdout: String = "") -> ProcessResult {
        ProcessResult(
            exitCode: 0, standardOutput: Data(stdout.utf8), standardError: Data(),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil
        )
    }

    private static func failure(_ stderr: String = "boom") -> ProcessResult {
        ProcessResult(
            exitCode: 1, standardOutput: Data(), standardError: Data(stderr.utf8),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil
        )
    }

    /// A minimal in-memory model of `simctl`'s own device registry: `list`
    /// reflects whatever `clone`/`delete` have done so far. Boot/bootstatus/
    /// shutdown always succeed unless `failBootFor` names a UDID. Also
    /// models the one real-`simctl` constraint that bit the first version
    /// of `provisionWorkerPool` (confirmed directly against a real
    /// simulator, not assumed): `simctl clone` refuses to clone a
    /// currently-booted source.
    private actor FakeSimctl {
        private(set) var devices: [(udid: String, name: String)]
        var failCloneWithError = false
        /// When set, only this many `clone` calls succeed; every call after
        /// that fails -- models a clone failing partway through
        /// provisioning several devices.
        var succeedCloneCountRemaining: Int?
        var failBootFor: Set<String> = []
        private(set) var bootedUDIDs: Set<String>
        private(set) var cloneCallCount = 0
        private(set) var deletedUDIDs: [String] = []
        private var nextCloneUDID = 100

        init(devices: [(udid: String, name: String)], initiallyBooted: Set<String> = []) {
            self.devices = devices
            bootedUDIDs = initiallyBooted
        }

        func listJSON() -> String {
            let entries = devices.map {
                "{\"udid\": \"\($0.udid)\", \"name\": \"\($0.name)\", \"state\": \"\(bootedUDIDs.contains($0.udid) ? "Booted" : "Shutdown")\", \"isAvailable\": true}"
            }
            return "{\"devices\": {\"\(SimulatorPoolCloningTests.runtime)\": [\(entries.joined(separator: ","))]}}"
        }

        /// `nil` distinguishes "clone refused" from "clone succeeded" the
        /// same way the real runner's failure path does; `sourceBooted`
        /// is the specific, real-`simctl`-confirmed refusal reason.
        enum CloneOutcome {
            case succeeded(udid: String)
            case sourceBooted
            case otherFailure
        }

        func clone(source: String, name: String) -> CloneOutcome {
            cloneCallCount += 1
            guard !failCloneWithError else { return .otherFailure }
            guard !bootedUDIDs.contains(source) else { return .sourceBooted }
            if let remaining = succeedCloneCountRemaining {
                guard remaining > 0 else { return .otherFailure }
                succeedCloneCountRemaining = remaining - 1
            }
            nextCloneUDID += 1
            let udid = "CLONE\(String(format: "%03d", nextCloneUDID))-0000-0000-0000-000000000000"
            devices.append((udid: udid, name: name))
            return .succeeded(udid: udid)
        }

        func delete(udid: String) -> Bool {
            guard devices.contains(where: { $0.udid == udid }) else { return false }
            devices.removeAll { $0.udid == udid }
            bootedUDIDs.remove(udid)
            deletedUDIDs.append(udid)
            return true
        }

        func boot(udid: String) {
            guard !failBootFor.contains(udid) else { return }
            bootedUDIDs.insert(udid)
        }

        func shutdown(udid: String) {
            bootedUDIDs.remove(udid)
        }

        func setFailCloneWithError() {
            failCloneWithError = true
        }

        func setFailCloneAfter(_ succeedCount: Int) {
            succeedCloneCountRemaining = succeedCount
        }

        func setFailBoot(udid: String) {
            failBootFor.insert(udid)
        }
    }

    private static func pool(_ simctl: FakeSimctl) -> SimulatorPool {
        SimulatorPool(
            workingDirectory: workingDirectory,
            processRunner: { _, arguments, _, _ in
                if arguments.contains("list") {
                    return Self.success(await simctl.listJSON())
                }
                if arguments.contains("clone") {
                    // simctl clone <source> <name>.
                    guard arguments.count >= 4 else { return Self.failure("malformed clone invocation") }
                    let source = arguments[arguments.count - 2]
                    let name = arguments[arguments.count - 1]
                    switch await simctl.clone(source: source, name: name) {
                    case let .succeeded(udid):
                        return Self.success(udid)
                    case .sourceBooted:
                        return Self.failure(
                            "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\n"
                                + "Unable to clone device in current state: Booted"
                        )
                    case .otherFailure:
                        return Self.failure("clone failed")
                    }
                }
                if arguments.contains("delete") {
                    guard let udid = arguments.last, await simctl.delete(udid: udid) else {
                        return Self.failure("delete failed: unknown device")
                    }
                    return Self.success()
                }
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    guard let udid = arguments.last else { return Self.success() }
                    if await simctl.failBootFor.contains(udid) {
                        return Self.failure("boot failed")
                    }
                    await simctl.boot(udid: udid)
                    return Self.success()
                }
                if arguments.contains("bootstatus") {
                    guard let udid = arguments.last, await simctl.failBootFor.contains(udid) else {
                        return Self.success()
                    }
                    return Self.failure("bootstatus failed")
                }
                if arguments.contains("shutdown") {
                    if let udid = arguments.last { await simctl.shutdown(udid: udid) }
                    return Self.success()
                }
                return Self.success()
            }
        )
    }

    private static var baseDevice: SimulatorDevice {
        SimulatorDevice(udid: baseUDID, name: baseName, runtimeIdentifier: runtime, state: "Shutdown")
    }

    // MARK: - cloneDevice

    @Test("cloneDevice returns the clone's full device record, discovered via a fresh simctl list")
    func cloneDeviceReturnsFullRecord() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)

        let clone = try await pool.cloneDevice(from: Self.baseDevice, label: "test-1")

        #expect(clone.udid != Self.baseUDID)
        #expect(clone.name == "\(SimulatorPool.clonePrefix)test-1")
        #expect(clone.runtimeIdentifier == Self.runtime)
    }

    @Test("cloneDevice throws when simctl clone itself fails")
    func cloneDeviceThrowsOnCloneFailure() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        await simctl.setFailCloneWithError()
        let pool = Self.pool(simctl)

        await #expect(throws: (any Error).self) {
            _ = try await pool.cloneDevice(from: Self.baseDevice, label: "test-1")
        }
    }

    // MARK: - deleteDevice

    @Test("deleteDevice removes the device so it no longer appears in availableDevices")
    func deleteDeviceRemovesFromList() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName), ("EXTRA0000-0000-0000-0000-000000000002", "extra")])
        let pool = Self.pool(simctl)

        try await pool.deleteDevice(udid: "EXTRA0000-0000-0000-0000-000000000002")

        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    /// Codex-review MEDIUM finding, fixed as defense-in-depth: `deleteDevice`
    /// must refuse a device this same pool instance currently has leased
    /// out to an in-flight test, rather than silently pulling it out from
    /// under that test.
    @Test("deleteDevice refuses to delete a device this pool has leased out")
    func deleteDeviceRefusesLeasedDevice() async throws {
        let extraUDID = "EXTRA0000-0000-0000-0000-000000000002"
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName), (extraUDID, "extra")])
        let pool = Self.pool(simctl)
        _ = try await pool.lease(udid: extraUDID)

        await #expect(throws: (any Error).self) {
            try await pool.deleteDevice(udid: extraUDID)
        }

        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid).contains(extraUDID), "a leased device must survive a deleteDevice call")
    }

    // MARK: - provisionWorkerPool

    /// The exact real-world sequence `RunCommand` actually produces:
    /// `prepareSimulatorForRun()` boots `base` for the run's own baseline
    /// *before* `provisionWorkerPool` is ever called. `simctl clone`
    /// refuses a booted source (confirmed directly, see this method's own
    /// doc comment), so provisioning must shut `base` down, clone from it,
    /// and reboot both `base` and every clone before returning -- catching
    /// the exact regression this suite's own first version had, which
    /// only ever exercised an already-shutdown base and never caught it.
    @Test("provisionWorkerPool shuts a booted base down before cloning, and reboots it and every clone afterward")
    func provisionShutsDownBootedBaseBeforeCloning() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)], initiallyBooted: [Self.baseUDID])
        let pool = Self.pool(simctl)

        let devices = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 3)

        #expect(devices.count == 3)
        let booted = await simctl.bootedUDIDs
        #expect(booted == Set(devices.map(\.udid)), "base and every clone must all be booted once provisioning returns")
    }

    /// If cloning or booting fails partway through, a `base` this method
    /// itself shut down must not be left shut down on the way out --
    /// the caller handed it a booted device and must get one back.
    @Test("provisionWorkerPool reboots a booted base even when provisioning fails partway through")
    func provisionRebootsBaseEvenOnFailure() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)], initiallyBooted: [Self.baseUDID])
        await simctl.setFailCloneAfter(0)
        let pool = Self.pool(simctl)

        await #expect(throws: (any Error).self) {
            _ = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 2)
        }

        let booted = await simctl.bootedUDIDs
        #expect(booted == [Self.baseUDID], "base must be rebooted even though provisioning failed")
    }

    /// Same defense-in-depth guard as `deleteDevice`, at `provisionWorkerPool`'s
    /// own base-shutdown step: this method is about to shut `base` down,
    /// which must not happen while this pool instance has `base` leased.
    @Test("provisionWorkerPool refuses to proceed when base is currently leased")
    func provisionWorkerPoolRefusesLeasedBase() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)
        _ = try await pool.lease(udid: Self.baseUDID)

        await #expect(throws: (any Error).self) {
            _ = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 2)
        }

        let cloneCalls = await simctl.cloneCallCount
        #expect(cloneCalls == 0, "must refuse before ever attempting to clone")
    }

    @Test("provisionWorkerPool with count 1 returns just the base device, no clone created")
    func provisionCountOneReturnsBaseOnly() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)

        let devices = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 1)

        #expect(devices == [Self.baseDevice])
        let cloneCalls = await simctl.cloneCallCount
        #expect(cloneCalls == 0, "count 1 must never call simctl clone at all")
    }

    @Test("provisionWorkerPool with count N returns the base plus N-1 distinct, booted clones")
    func provisionCountNReturnsBasePlusClones() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)

        let devices = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 3)

        #expect(devices.count == 3)
        #expect(devices[0] == Self.baseDevice)
        let udids = Set(devices.map(\.udid))
        #expect(udids.count == 3, "every provisioned device must have a distinct UDID")
        for clone in devices.dropFirst() {
            #expect(clone.name.hasPrefix(SimulatorPool.clonePrefix))
        }
    }

    @Test("A clone failure mid-provision rolls back every clone already created, never touching base")
    func provisionFailureRollsBackPartialClones() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)

        // Let the first clone succeed, then force the second to fail.
        await simctl.setFailCloneAfter(1)

        await #expect(throws: (any Error).self) {
            _ = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 3)
        }

        let remaining = try await pool.availableDevices()
        // Only the base device should remain -- the one successful clone
        // must have been rolled back, and base must never be deleted.
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    @Test("A boot failure on a clone rolls back every clone already created")
    func provisionBootFailureRollsBack() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)
        // The first clone created will get UDID CLONE101...; make its boot fail.
        await simctl.setFailBoot(udid: "CLONE101-0000-0000-0000-000000000000")

        await #expect(throws: (any Error).self) {
            _ = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 2)
        }

        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    // MARK: - releaseWorkerPool

    @Test("releaseWorkerPool deletes every clone but never the base device")
    func releaseWorkerPoolDeletesClonesNotBase() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)
        let devices = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 3)

        let failures = await pool.releaseWorkerPool(devices, base: Self.baseDevice)

        #expect(failures.isEmpty)
        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    @Test("releaseWorkerPool reports a failed deletion but still attempts the rest")
    func releaseWorkerPoolReportsPartialFailure() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)
        let devices = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 3)
        // Delete one clone out from under the pool first, so releaseWorkerPool's
        // own delete call for it fails (already gone).
        try await pool.deleteDevice(udid: devices[1].udid)

        let failures = await pool.releaseWorkerPool(devices, base: Self.baseDevice)

        #expect(failures == [devices[1].udid])
        // The other clone must still have been deleted despite the failure.
        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    // MARK: - cleanupOrphanClones

    @Test("cleanupOrphanClones deletes every device whose name carries the clone prefix")
    func cleanupOrphanClonesDeletesMatchingNames() async throws {
        let simctl = FakeSimctl(devices: [
            (Self.baseUDID, Self.baseName),
            ("ORPHAN001-0000-0000-0000-000000000000", "\(SimulatorPool.clonePrefix)stale-1"),
            ("ORPHAN002-0000-0000-0000-000000000000", "\(SimulatorPool.clonePrefix)stale-2")
        ])
        let pool = Self.pool(simctl)

        let failures = await pool.cleanupOrphanClones()

        #expect(failures.isEmpty)
        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    @Test("cleanupOrphanClones never touches a device whose name does not carry the prefix")
    func cleanupOrphanClonesLeavesOrdinaryDevicesAlone() async throws {
        let simctl = FakeSimctl(devices: [
            (Self.baseUDID, Self.baseName),
            ("DEV000002-0000-0000-0000-000000000000", "Developer's own simulator")
        ])
        let pool = Self.pool(simctl)

        _ = await pool.cleanupOrphanClones()

        let remaining = try await pool.availableDevices()
        #expect(remaining.count == 2)
    }

    @Test("cleanupOrphanClones on a machine with no orphans does nothing and reports no failures")
    func cleanupOrphanClonesNoOrphansIsANoOp() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)

        let failures = await pool.cleanupOrphanClones()

        #expect(failures.isEmpty)
        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID])
    }

    /// Codex-review HIGH finding, fixed: a name-prefix-only sweep could
    /// delete a *different, still-running* MutantKit process's live
    /// clones. Every clone's name now embeds its owning PID
    /// (`<pid>-<suffix>`), and `cleanupOrphanClones` must leave a clone
    /// alone when that PID is confirmed alive -- modeled here with this
    /// very test process's own PID, which is alive by construction.
    @Test("cleanupOrphanClones never deletes a clone whose embedded owner PID is still alive")
    func cleanupOrphanClonesLeavesLiveOwnerAlone() async throws {
        let livePID = ProcessInfo.processInfo.processIdentifier
        let simctl = FakeSimctl(devices: [
            (Self.baseUDID, Self.baseName),
            ("LIVE00001-0000-0000-0000-000000000000", "\(SimulatorPool.clonePrefix)\(livePID)-worker1-abcd1234")
        ])
        let pool = Self.pool(simctl)

        let failures = await pool.cleanupOrphanClones()

        #expect(failures.isEmpty)
        let remaining = try await pool.availableDevices()
        #expect(
            remaining.map(\.udid).sorted() == [Self.baseUDID, "LIVE00001-0000-0000-0000-000000000000"].sorted(),
            "a clone owned by a still-running process must not be deleted"
        )
    }

    /// The counterpart to the test above: a clone whose embedded PID is
    /// confirmed dead (a PID essentially guaranteed unused on any real
    /// machine) is exactly the orphan this method exists to sweep.
    @Test("cleanupOrphanClones deletes a clone whose embedded owner PID is confirmed dead")
    func cleanupOrphanClonesDeletesDeadOwner() async throws {
        let deadPID: Int32 = 999_999
        let simctl = FakeSimctl(devices: [
            (Self.baseUDID, Self.baseName),
            ("DEAD00001-0000-0000-0000-000000000000", "\(SimulatorPool.clonePrefix)\(deadPID)-worker1-abcd1234")
        ])
        let pool = Self.pool(simctl)

        let failures = await pool.cleanupOrphanClones()

        #expect(failures.isEmpty)
        let remaining = try await pool.availableDevices()
        #expect(remaining.map(\.udid) == [Self.baseUDID], "a clone owned by a confirmed-dead process must be swept")
    }

    @Test("parseOwnerPID recovers the embedded PID from a well-formed clone name, and returns nil otherwise")
    func parseOwnerPIDRoundTrips() {
        #expect(SimulatorPool.parseOwnerPID(fromCloneName: "\(SimulatorPool.clonePrefix)4242-worker0-abcd1234") == 4242)
        #expect(SimulatorPool.parseOwnerPID(fromCloneName: "\(SimulatorPool.clonePrefix)not-a-pid") == nil)
        #expect(SimulatorPool.parseOwnerPID(fromCloneName: "Developer's own simulator") == nil)
    }

    /// `provisionWorkerPool` (the real production call site) must itself
    /// produce PID-embedded names, not just `cloneDevice` in isolation --
    /// otherwise this whole safety net never actually engages in practice.
    @Test("provisionWorkerPool's own clones carry this process's PID, parseable by parseOwnerPID")
    func provisionedClonesEmbedThisProcessPID() async throws {
        let simctl = FakeSimctl(devices: [(Self.baseUDID, Self.baseName)])
        let pool = Self.pool(simctl)

        let devices = try await pool.provisionWorkerPool(base: Self.baseDevice, count: 2)

        let clone = try #require(devices.dropFirst().first)
        let ownerPID = SimulatorPool.parseOwnerPID(fromCloneName: clone.name)
        #expect(ownerPID == ProcessInfo.processInfo.processIdentifier)
    }
}
