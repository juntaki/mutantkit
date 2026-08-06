@testable import CLI
import Foundation
import MutationExecution
import Testing

/// `HostResourcePreflight.diagnose` is the pure decision behind both
/// `mutantkit doctor` (always warn-only) and `mutantkit run
/// --require-healthy-host` (fails closed on any non-`.ok` item). These tests
/// pin that it never itself produces `.failure` — only `.ok`/`.warning` —
/// since the fail-closed behavior belongs to the caller opting into it, not
/// to this diagnosis.
///
/// The memory check is driven by an explicit `availableMemoryBytes:`
/// parameter, not `ResourceSnapshot.freeMemoryBytes` — a codex review of the
/// first version of this preflight found it comparing the raw
/// `vm_statistics64.free_count` byte count against the low-memory threshold,
/// which is not "available memory" on macOS: the kernel deliberately keeps
/// literal free pages low and holds reclaimable data in `inactive`/
/// `purgeable` pools instead, so a perfectly healthy host can report only a
/// few hundred MB "free" and get `--require-healthy-host` to abort for no
/// real reason. These tests exercise `diagnose` directly with an explicit
/// value so the reclaim-aware computation in `availableMemoryBytes()` itself
/// doesn't need to be mocked.
@Suite("Host resource preflight")
struct HostResourcePreflightTests {
    private static func snapshot(loadAverage1Minute: Double = 0.1) -> ResourceSnapshot {
        ResourceSnapshot(
            capturedAt: Date(),
            loadAverage1Minute: loadAverage1Minute,
            loadAverage5Minute: loadAverage1Minute,
            loadAverage15Minute: loadAverage1Minute,
            freeMemoryBytes: nil,
            runLockFilesPresent: 1
        )
    }

    @Test("Plenty of available memory, low load, no contending simulator: everything ok")
    func healthyHostIsAllOK() {
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(loadAverage1Minute: 0.5),
            activeProcessorCount: 8,
            bootedSimulatorCount: 1,
            availableMemoryBytes: 16 * 1024 * 1024 * 1024
        )

        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.status == .ok })
    }

    @Test("Low available memory warns, never fails, and explains the remedy")
    func lowAvailableMemoryWarns() throws {
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(),
            activeProcessorCount: 8,
            bootedSimulatorCount: 1,
            availableMemoryBytes: 512 * 1024 * 1024
        )

        let memoryItem = try #require(items.first { $0.name == "Available memory" })
        #expect(memoryItem.status == .warning)
        #expect(memoryItem.remedy != nil)
    }

    @Test("Unknown available memory (host_statistics64 failed) is reported, not silently zero")
    func unknownAvailableMemoryIsReportedNotFabricatedZero() throws {
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(),
            activeProcessorCount: 8,
            bootedSimulatorCount: 1,
            availableMemoryBytes: nil
        )

        let memoryItem = try #require(items.first { $0.name == "Available memory" })
        #expect(memoryItem.status == .warning)
        #expect(memoryItem.detail == "could not be determined")
    }

    @Test("Load well above the per-core threshold warns")
    func highLoadWarns() throws {
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(loadAverage1Minute: 20),
            activeProcessorCount: 4,
            bootedSimulatorCount: 1,
            availableMemoryBytes: 16 * 1024 * 1024 * 1024
        )

        let loadItem = try #require(items.first { $0.name == "System load" })
        #expect(loadItem.status == .warning)
    }

    @Test("More than one booted simulator warns about contention, without proposing to kill anything")
    func multipleBootedSimulatorsWarn() throws {
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(),
            activeProcessorCount: 8,
            bootedSimulatorCount: 3,
            availableMemoryBytes: 16 * 1024 * 1024 * 1024
        )

        let simItem = try #require(items.first { $0.name == "Booted simulators" })
        #expect(simItem.status == .warning)
        #expect(simItem.detail == "3 booted")
        let remedy = try #require(simItem.remedy)
        #expect(!remedy.lowercased().contains("kill"))
        #expect(!remedy.lowercased().contains("terminate"))
    }

    @Test("A non-simulator destination is never judged on booted-simulator state, even a bad reading")
    func nonSimulatorDestinationSkipsSimulatorCheck() throws {
        // A macOS-destination run never probes `simctl` in the first place
        // (see `RunCommand`), so `bootedSimulatorCount` is `nil` here too —
        // but unlike the genuinely-unknown case, this must stay `.ok`: a
        // failed or contended probe of simulators this run was never going
        // to use is not this run's problem, and `--require-healthy-host`
        // must not abort over it.
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(),
            activeProcessorCount: 8,
            bootedSimulatorCount: nil,
            availableMemoryBytes: 16 * 1024 * 1024 * 1024,
            simulatorApplicable: false
        )

        let simItem = try #require(items.first { $0.name == "Booted simulators" })
        #expect(simItem.status == .ok)
        #expect(items.allSatisfy { $0.status == .ok })
    }

    @Test("Unknown booted simulator count is reported, not silently zero")
    func unknownBootedSimulatorCountIsReported() throws {
        let items = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(),
            activeProcessorCount: 8,
            bootedSimulatorCount: nil,
            availableMemoryBytes: 16 * 1024 * 1024 * 1024
        )

        let simItem = try #require(items.first { $0.name == "Booted simulators" })
        #expect(simItem.status == .warning)
        #expect(simItem.detail == "could not be determined")
    }

    @Test("diagnose never itself produces a .failure item")
    func neverProducesFailure() {
        let unhealthy = HostResourcePreflight.diagnose(
            snapshot: Self.snapshot(loadAverage1Minute: 999),
            activeProcessorCount: 1,
            bootedSimulatorCount: nil,
            availableMemoryBytes: 1
        )

        #expect(unhealthy.allSatisfy { $0.status != .failure })
    }
}
