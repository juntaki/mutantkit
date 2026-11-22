@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Each caller loads the catalog in its own task. A forced reload
/// (`invalidate()`) or a `deleteDevice` makes any load already running in
/// another caller stale: its result — or its failure — must never be committed
/// over, or thrown at a caller with, newer state; it re-reads instead. A
/// cancelled caller throws `CancellationError` and launches nothing further.
@Suite("Simulator pool: catalog load vs reloads, deletes and cancellation")
struct SimulatorPoolLoadTests {
    private static let runtime = SimctlFixtures.prefix + "iOS-26-0"

    /// Scripted `simctl`: the `devices` listing reports `state`, and the first
    /// `blockedListings` of them wait on `gate` after reading it (so the answer
    /// they return is older than anything that happens while they wait).
    private actor Fake {
        var devices: [(udid: String, name: String)]
        private(set) var commands: [[String]] = []
        private var blocked: Int
        private var gateOpen = false
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var failBlocked: Bool
        private var cloneCount = 0
        private let booted: Set<String>
        /// Once a clone exists, `simctl list runtimes` keeps failing.
        private let failRuntimesAfterClone: Bool

        private let blockOn: String

        init(
            devices: [(udid: String, name: String)], blockedListings: Int, blockOn: String = "devices", failBlocked: Bool = false,
            booted: Set<String> = [], failRuntimesAfterClone: Bool = false
        ) {
            self.booted = booted
            self.failRuntimesAfterClone = failRuntimesAfterClone
            self.devices = devices
            blocked = blockedListings
            self.blockOn = blockOn
            self.failBlocked = failBlocked
        }

        func setDevices(_ new: [(udid: String, name: String)]) { devices = new }
        func openGate() {
            gateOpen = true
            parked.forEach { $0.resume() }
            parked = []
        }

        func ran(_ words: [String]) -> Bool { commands.contains { $0.suffix(words.count) == words[...] } }

        func count(_ word: String) -> Int { commands.filter { $0.contains(word) }.count }

        /// `nil` means the command fails (exit 1).
        func run(_ arguments: [String]) async -> String? {
            commands.append(arguments)
            if blockOn != "devices", blockOn != "runtimes", blocked > 0, arguments.contains(blockOn) {
                blocked -= 1
                if !gateOpen { await withCheckedContinuation { parked.append($0) } }
            }
            if arguments.contains("runtimes") || arguments.contains("devices") {
                let isRuntimes = arguments.contains("runtimes")
                if isRuntimes, failRuntimesAfterClone, cloneCount > 0 { return nil }
                var body = isRuntimes
                    ? SimctlFixtures.runtimesJSON([.init(SimulatorPoolLoadTests.runtime, "26.0", "iOS")])
                    : SimctlFixtures.devicesJSON([SimulatorPoolLoadTests.runtime: devices])
                for device in devices where booted.contains(device.udid) {
                    body = body.replacingOccurrences(
                        of: "\"udid\": \"\(device.udid)\", \"name\": \"\(device.name)\", \"state\": \"Shutdown\"",
                        with: "\"udid\": \"\(device.udid)\", \"name\": \"\(device.name)\", \"state\": \"Booted\""
                    )
                }
                if blocked > 0, arguments.contains(blockOn) {
                    blocked -= 1
                    if !gateOpen { await withCheckedContinuation { parked.append($0) } }
                    if failBlocked { return nil }
                }
                return body
            }
            if arguments.contains("clone") {
                cloneCount += 1
                devices.append(("CLONE-\(cloneCount)", arguments.last ?? "clone"))
                return "CLONE-\(cloneCount)\n"
            }
            if arguments.contains("delete") {
                devices.removeAll { arguments.contains($0.udid) }
            }
            return ""
        }
    }

    /// `checksCancellation`: like `ProcessSupervisor.run`, a cancelled caller's
    /// process is killed (the closure throws) both on launch and while running.
    /// Pass `false` to prove the pool itself honours cancellation.
    private func pool(_ fake: Fake, checksCancellation: Bool = true) -> SimulatorPool {
        SimulatorPool(workingDirectory: FileManager.default.temporaryDirectory, processRunner: { _, arguments, _, _ in
            if checksCancellation { try Task.checkCancellation() }
            let body = await fake.run(arguments)
            if checksCancellation { try Task.checkCancellation() }
            return ProcessResult(
                exitCode: body == nil ? 1 : 0, standardOutput: Data((body ?? "").utf8), standardError: Data(),
                durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
            )
        })
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0 ..< 500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("A forced reload does not join a load that started before it")
    func forcedReloadSkipsStaleLoad() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 1)
        let pool = pool(fake)
        let cold = Task { try await pool.availableDevices() }
        await waitUntil { await fake.count("devices") == 1 }

        await fake.setDevices([("X", "iPhone 16"), ("CLONE", "clone")])
        await pool.invalidate()
        let reloaded = Task { try await pool.availableDevices() }
        await waitUntil { await fake.count("devices") == 2 }
        await fake.openGate()

        #expect(try await reloaded.value.map(\.udid).contains("CLONE"), "the reload must list the clone made after the stale load began")
        _ = try await cold.value
        #expect(try await pool.availableDevices().map(\.udid).contains("CLONE"), "the stale result must not overwrite the reload")
    }

    @Test("A device deleted while a load is in flight is not resurrected by that load")
    func deleteDuringLoadIsNotUndone() async throws {
        let fake = Fake(devices: [("X", "iPhone 16"), ("GONE", "clone")], blockedListings: 1)
        let pool = pool(fake)
        let cold = Task { try await pool.availableDevices() }
        await waitUntil { await fake.count("devices") == 1 }

        try await pool.deleteDevice(udid: "GONE")
        await fake.openGate()

        #expect(try await cold.value.map(\.udid) == ["X"])
        #expect(try await pool.availableDevices().map(\.udid) == ["X"])
    }

    @Test("A cancelled sole caller throws CancellationError, not simctlFailed, and launches no devices listing or boot")
    func cancelledCallerLaunchesNothing() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 1, blockOn: "runtimes")
        let pool = pool(fake)
        let caller = Task { try await pool.prepare(udid: "X", retryDelaySeconds: 0) }
        await waitUntil { await fake.count("runtimes") == 1 }
        caller.cancel()
        await fake.openGate()

        await #expect(throws: CancellationError.self) { try await caller.value }
        let deviceListings = await fake.count("devices")
        let bootLaunches = await fake.count("boot")
        #expect(deviceListings == 0, "cancelled while the runtimes listing ran: the devices listing never launches")
        #expect(bootLaunches == 0)
    }

    @Test("A cancelled caller on a warm pool is not handed a lease (the runner does not check cancellation)")
    func cancelledCallerDoesNotLease() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 0)
        let pool = pool(fake, checksCancellation: false)
        _ = try await pool.availableDevices()
        let caller = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await pool.lease(udid: "X")
        }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        // Nothing was leaked: the device can still be leased.
        let lease = try await pool.lease(udid: "X")
        await pool.release(lease)
    }

    @Test("A cancelled waiter woken by a release does not take the lease, and the release still wakes the live one")
    func cancelledWaiterDoesNotTakeTheLease() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 0)
        let pool = pool(fake, checksCancellation: false)
        let held = try await pool.lease(udid: "X")
        let cancelled = Task { try await pool.lease(udid: "X") }
        await waitUntil { await pool.waiters.count == 1 }
        let live = Task { try await pool.lease(udid: "X") }
        await waitUntil { await pool.waiters.count == 2 }
        cancelled.cancel()
        await pool.release(held)

        let first = await cancelled.result
        if case let .success(lease) = first { await pool.release(lease) } // keeps the RED run from hanging
        #expect(throws: CancellationError.self) { try first.get() }
        let granted = try await live.value
        #expect(granted.device.udid == "X", "the same release still wakes the other waiter")
        await pool.release(granted)
    }

    @Test("A device being deleted cannot be leased mid-delete")
    func noLeaseDuringDelete() async throws {
        let fake = Fake(devices: [("X", "iPhone 16"), ("GONE", "clone")], blockedListings: 1, blockOn: "shutdown")
        let pool = pool(fake)
        _ = try await pool.availableDevices()
        let delete = Task { try await pool.deleteDevice(udid: "GONE") }
        await waitUntil { await fake.count("shutdown") == 1 }

        await #expect(throws: SimulatorPoolError.self) { try await pool.lease(udid: "GONE") }
        await fake.openGate()
        try await delete.value
        let deletes = await fake.count("delete")
        #expect(deletes == 1)
    }

    @Test("A failed provision restores a booted base by UDID even when `simctl list` keeps failing")
    func baseRestoredWithoutACatalogReload() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 0, booted: ["X"], failRuntimesAfterClone: true)
        let pool = pool(fake)
        let base = SimulatorDevice(udid: "X", name: "iPhone 16", runtimeIdentifier: Self.runtime, state: "Booted")
        await #expect(throws: (any Error).self) { try await pool.provisionWorkerPool(base: base, count: 2) }
        let rebooted = await fake.ran(["simctl", "boot", "X"])
        #expect(rebooted, "base was shut down for cloning and must be booted again")
        let deletes = await fake.count("delete")
        #expect(deletes == 1, "the clone is still rolled back")
    }

    @Test("A stale load's failure is not thrown at a caller once the current generation succeeds")
    func staleFailureDoesNotPropagate() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 1, failBlocked: true)
        let pool = pool(fake)
        let cold = Task { try await pool.availableDevices() }
        await waitUntil { await fake.count("devices") == 1 }
        await pool.invalidate()
        #expect(try await pool.availableDevices().map(\.udid) == ["X"])
        await fake.openGate()
        #expect(try await cold.value.map(\.udid) == ["X"], "the stale listing failed, but the caller's state is fine")
    }

    @Test("A clone survives a concurrent stale load that fails")
    func cloneSurvivesStaleFailure() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 1, failBlocked: true)
        let pool = pool(fake)
        let cold = Task { try await pool.availableDevices() }
        await waitUntil { await fake.count("devices") == 1 }
        let base = SimulatorDevice(udid: "X", name: "iPhone 16", runtimeIdentifier: Self.runtime, state: "Shutdown")
        let clone = Task { try await pool.cloneDevice(from: base, label: "c") }
        await waitUntil { await fake.count("devices") == 2 }
        await fake.openGate()

        #expect(try await clone.value.udid == "CLONE-1")
        _ = try await cold.value
        let deletes = await fake.count("delete")
        #expect(deletes == 0, "a valid clone must not be rolled back because an older listing failed")
    }

    @Test("A clone is still deleted when the cloning task is cancelled during the post-clone refresh")
    func cloneRollbackRunsWhenCancelled() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 1, blockOn: "runtimes")
        let pool = pool(fake)
        let base = SimulatorDevice(udid: "X", name: "iPhone 16", runtimeIdentifier: Self.runtime, state: "Shutdown")
        let clone = Task { try await pool.cloneDevice(from: base, label: "c") }
        await waitUntil { await fake.count("runtimes") == 1 }
        clone.cancel()
        await fake.openGate()

        await #expect(throws: CancellationError.self) { try await clone.value }
        let deletes = await fake.count("delete")
        #expect(deletes == 1, "the rollback delete must run even though its caller was cancelled")
    }

    @Test("A cancelled provision still deletes the clones it made")
    func provisionRollbackRunsWhenCancelled() async throws {
        let fake = Fake(devices: [("X", "iPhone 16")], blockedListings: 1, blockOn: "boot")
        let pool = pool(fake)
        let base = SimulatorDevice(udid: "X", name: "iPhone 16", runtimeIdentifier: Self.runtime, state: "Shutdown")
        let provision = Task { try await pool.provisionWorkerPool(base: base, count: 2) }
        await waitUntil { await fake.count("boot") == 1 }
        provision.cancel()
        await fake.openGate()

        await #expect(throws: CancellationError.self) { try await provision.value }
        let deletes = await fake.count("delete")
        #expect(deletes == 1, "the clone made before the cancelled boot must be rolled back")
    }
}
