import Darwin
import Foundation

/// The machine's state at one moment, captured for evidence rather than for
/// any decision this tool makes from it.
///
/// A mutant's manifestation was found — on two different projects, on two
/// different machines — to vary between crash, timeout, and flaky under
/// otherwise-identical conditions, with no direction of system load
/// correlating with which one showed up. That finding depended entirely on
/// having `uptime`/`vm_stat` output sitting next to each attempt to compare
/// against by hand. This is that record, captured automatically instead of
/// requiring a human watching the machine at the right moment.
public struct ResourceSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let loadAverage1Minute: Double
    public let loadAverage5Minute: Double
    public let loadAverage15Minute: Double
    /// `nil` when the host statistics call failed — absence of the number,
    /// not a fabricated zero.
    public let freeMemoryBytes: UInt64?
    /// The number of `RunIsolationLock` files present under `run-locks/`,
    /// across every destination this project has ever locked — including
    /// stale ones nothing has reclaimed yet. A coarse signal, not a proof:
    /// what matters is not the exact count but whether it is ever anything
    /// other than the one this run itself just acquired.
    public let runLockFilesPresent: Int

    public init(
        capturedAt: Date,
        loadAverage1Minute: Double,
        loadAverage5Minute: Double,
        loadAverage15Minute: Double,
        freeMemoryBytes: UInt64?,
        runLockFilesPresent: Int
    ) {
        self.capturedAt = capturedAt
        self.loadAverage1Minute = loadAverage1Minute
        self.loadAverage5Minute = loadAverage5Minute
        self.loadAverage15Minute = loadAverage15Minute
        self.freeMemoryBytes = freeMemoryBytes
        self.runLockFilesPresent = runLockFilesPresent
    }

    /// Captures the current moment. `lockRoot` is the same
    /// `.mutantkit/run-locks` directory `RunIsolationLock.acquire` uses;
    /// passing it after this run's own lock is already held means the count
    /// this returns always includes at least one (this run) — a `1` is "as
    /// expected, solo," not "no lock exists."
    public static func capture(lockRoot: URL) -> ResourceSnapshot {
        var loads: [Double] = [0, 0, 0]
        // `getloadavg` returns however many of the requested samples the
        // platform can supply; short-reads are left at zero rather than
        // reported as a real (and misleadingly idle) load.
        _ = loads.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, 3)
        }

        return ResourceSnapshot(
            capturedAt: Date(),
            loadAverage1Minute: loads[0],
            loadAverage5Minute: loads[1],
            loadAverage15Minute: loads[2],
            freeMemoryBytes: Self.freeMemoryBytes(),
            runLockFilesPresent: Self.lockFileCount(in: lockRoot)
        )
    }

    private static func freeMemoryBytes() -> UInt64? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(stats.free_count) * UInt64(pageSize)
    }

    private static func lockFileCount(in lockRoot: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: lockRoot, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "lock" }
            .count ?? 0
    }
}
