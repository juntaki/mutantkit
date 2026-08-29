import Darwin
import Foundation
import MutationExecution

/// Turns a `ResourceSnapshot` (and a best-effort simulator-contention count)
/// into warn-only diagnosis items — never `.failure` on its own.
///
/// This exists because of a standing, repeatedly-hit failure mode on the
/// local corpus-validation host (see `Research/corpus-validation/*/README.md`):
/// starting a multi-hour corpus run while memory is already under pressure,
/// load is already high from something else running, or a stray booted
/// simulator is competing for CoreSimulator resources, degrades run quality
/// in ways that surface hours later as `.infrastructureFailure`/`.flaky`
/// results indistinguishable from a real product bug. Catching that *before*
/// the run starts is far cheaper than diagnosing it after.
///
/// Deliberately never kills or restarts anything — a booted simulator or a
/// loaded machine might belong to work the person running this had no idea
/// this tool would look at, let alone touch. This only measures and reports;
/// what to do about a warning (close the browser, wait, or run anyway) is
/// left to whoever reads it.
///
/// The two callers apply different policy to the same items:
/// - `mutantkit doctor` always just prints them — informational only,
///   because "the machine happens to be busy right now" is not something
///   `doctor` should ever block on.
/// - `mutantkit run --require-healthy-host` fails closed on any non-`.ok`
///   item, for the one caller (the corpus runner) that has already decided
///   a bad host reading should abort *before* hours of runtime are spent on
///   results that would otherwise be indistinguishable from real findings.
enum HostResourcePreflight {
    /// Below this, a `swift build`/`xcodebuild` invocation competing with
    /// whatever else is resident risks paging under load — exactly the
    /// condition `Research/corpus-validation` runs have hit before.
    /// Heuristic, not a proven cliff: chosen as "uncomfortably low for a
    /// multi-hour build+test loop on a laptop-class Mac," not measured from
    /// a specific OOM threshold.
    static let lowAvailableMemoryBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// 1-minute load average above this many multiples of the core count
    /// suggests the machine is already busy with something else. Same
    /// heuristic caveat as above.
    static let highLoadPerCoreMultiplier = 1.5

    /// `false` for a run whose resolved destination never touches
    /// CoreSimulator (a macOS target, an Xcode project's own `.notApplicable`
    /// simulator preparation outcome). A second codex review found the first
    /// version always probed and judged booted-simulator state regardless —
    /// so a `--require-healthy-host` macOS-destination run could fail closed
    /// over simulators it was never going to use, or a probe failure it had
    /// no reason to care about. `true` by default since most callers (e.g.
    /// `doctor`, which resolves its adapter separately and does not thread
    /// this through) have not determined applicability and the check is
    /// warn-only there regardless.
    static func diagnose(
        snapshot: ResourceSnapshot,
        activeProcessorCount: Int,
        bootedSimulatorCount: Int?,
        availableMemoryBytes: UInt64? = HostResourcePreflight.availableMemoryBytes(),
        simulatorApplicable: Bool = true
    ) -> [DiagnosisItem] {
        diagnoseHost(snapshot: snapshot, activeProcessorCount: activeProcessorCount, availableMemoryBytes: availableMemoryBytes)
            + diagnoseSimulators(bootedSimulatorCount: bootedSimulatorCount, simulatorApplicable: simulatorApplicable)
    }

    /// Memory and load only — deliberately independent of simulator state, so
    /// a caller that needs to fail closed *before* booting a simulator (see
    /// `diagnoseSimulators` below) has something to check first. Split out of
    /// `diagnose` so `mutantkit run` can gate simulator preparation on this
    /// half without waiting to learn whether the destination is even a
    /// simulator one.
    static func diagnoseHost(
        snapshot: ResourceSnapshot,
        activeProcessorCount: Int,
        availableMemoryBytes: UInt64? = HostResourcePreflight.availableMemoryBytes()
    ) -> [DiagnosisItem] {
        var items: [DiagnosisItem] = []

        if let availableMemoryBytes {
            let gigabytes = Double(availableMemoryBytes) / 1_000_000_000
            let low = availableMemoryBytes < lowAvailableMemoryBytes
            let lowMemoryRemedy = "Close other heavy applications before a long corpus run — low available memory has "
                + "been observed to change a mutant's confirmed outcome (crash vs. timeout vs. flaky) between otherwise-identical attempts."
            items.append(DiagnosisItem(
                name: "Available memory",
                status: low ? .warning : .ok,
                code: .availableMemory,
                detail: String(format: "%.1f GB available", gigabytes),
                remedy: low ? lowMemoryRemedy : nil
            ))
        } else {
            items.append(DiagnosisItem(
                name: "Available memory",
                status: .warning,
                code: .availableMemory,
                detail: "could not be determined",
                remedy: "host_statistics64 failed to report memory usage; proceeding without this signal."
            ))
        }

        let loadThreshold = Double(max(activeProcessorCount, 1)) * highLoadPerCoreMultiplier
        let highLoad = snapshot.loadAverage1Minute > loadThreshold
        items.append(DiagnosisItem(
            name: "System load",
            status: highLoad ? .warning : .ok,
            code: .systemLoad,
            detail: String(
                format: "%.2f, %.2f, %.2f (1m, 5m, 15m) on %d cores",
                snapshot.loadAverage1Minute, snapshot.loadAverage5Minute, snapshot.loadAverage15Minute,
                activeProcessorCount
            ),
            remedy: highLoad
                ? "1-minute load is above \(String(format: "%.1f", loadThreshold))x the core count — something else is already competing for CPU."
                : nil
        ))

        return items
    }

    /// Booted-simulator contention only. Necessarily measured *after*
    /// simulator preparation — whether a destination even resolves to a
    /// simulator is only known once preparation has run — which is exactly
    /// why `mutantkit run` fails closed on `diagnoseHost` first: a low-memory
    /// or high-load host should abort before ever reaching this point, not
    /// after a simulator has already been booted trying to get here.
    static func diagnoseSimulators(bootedSimulatorCount: Int?, simulatorApplicable: Bool) -> [DiagnosisItem] {
        switch bootedSimulatorCount {
        case _ where !simulatorApplicable:
            return [DiagnosisItem(
                name: "Booted simulators", status: .ok, code: .bootedSimulators,
                detail: "not applicable (non-simulator destination)"
            )]
        case nil:
            return [DiagnosisItem(
                name: "Booted simulators",
                status: .warning,
                code: .bootedSimulators,
                detail: "could not be determined",
                remedy: "`xcrun simctl list devices booted` failed; proceeding without this signal."
            )]
        case let .some(count) where count > 1:
            let contentionRemedy = "More than one booted simulator competes for CoreSimulator resources with the one this run will use. "
                + "Not stopped automatically — quit the ones this run does not need."
            return [DiagnosisItem(
                name: "Booted simulators",
                status: .warning,
                code: .bootedSimulators,
                detail: "\(count) booted",
                remedy: contentionRemedy
            )]
        case let .some(count):
            return [DiagnosisItem(name: "Booted simulators", status: .ok, code: .bootedSimulators, detail: "\(count) booted")]
        }
    }

    /// `vm_statistics64.free_count` alone is not "available memory" on macOS
    /// — the kernel deliberately keeps free pages low and holds recently-used
    /// file data in the reclaimable `inactive`/`purgeable` pools instead of
    /// discarding it, so a healthy machine with plenty of headroom can still
    /// report only a few hundred MB of literal free pages (a codex review of
    /// this preflight caught it doing exactly that on the machine it was
    /// developed on — `free_count` alone made `--require-healthy-host`
    /// trigger-happy on hosts with nothing actually wrong). Free + inactive +
    /// purgeable approximates what Activity Monitor calls "available" memory
    /// — pages the kernel can reclaim without touching anything actively in
    /// use. `nil` on any failure to query — absence of the number, not a
    /// fabricated zero, mirroring `ResourceSnapshot.freeMemoryBytes`.
    static func availableMemoryBytes() -> UInt64? {
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

        let reclaimablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        return reclaimablePages * UInt64(pageSize)
    }

    /// This is a best-effort check meant to run before every corpus run, so
    /// it must never itself become the thing that makes a run hang — a
    /// second codex review found the first version could: `simctl` writing
    /// enough to stderr to fill an undrained pipe would deadlock against
    /// `readDataToEndOfFile()` on stdout, and nothing bounded how long a
    /// wedged CoreSimulator's `simctl` could take to answer at all.
    /// stderr is discarded (nothing here reads it, so there is nothing to
    /// drain), and the process is raced against a timeout that kills it and
    /// returns `nil` rather than hanging.
    static let simctlTimeoutSeconds: UInt64 = 5

    /// A fourth codex review found `terminate()` (`SIGTERM`) alone is not a
    /// guaranteed bound: a `simctl` wedged badly enough to need this timeout
    /// in the first place can just as easily be wedged badly enough to
    /// ignore or not promptly act on it, leaving the reader still blocked in
    /// `readDataToEndOfFile()` past the nominal timeout. This grace period
    /// is how long `SIGTERM` gets before escalating to `SIGKILL`, which the
    /// kernel cannot ignore — the one thing that actually guarantees the
    /// pipe closes and the read unblocks.
    static let simctlKillGraceSeconds: UInt64 = 1

    /// Best-effort, read-only: counts devices `simctl` reports as `Booted`.
    /// `nil` on any failure to run, parse, or finish within
    /// `simctlTimeoutSeconds` — absence of the count, not a fabricated zero,
    /// mirroring `ResourceSnapshot.freeMemoryBytes`.
    static func bootedSimulatorCount() async -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "--json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Raced against a timeout rather than a shared mutable flag: the
        // read side blocks synchronously on `readDataToEndOfFile()`
        // (`Process`/`Pipe` have no async-native API), so the timeout has to
        // win the race by terminating the process, which closes the pipe
        // and unblocks the read with whatever partial data got written —
        // not by trying to interrupt the blocking call directly.
        let data: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return process.terminationStatus == 0 ? data : nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: simctlTimeoutSeconds * 1_000_000_000)
                guard process.isRunning else { return nil }
                process.terminate()
                try? await Task.sleep(nanoseconds: simctlKillGraceSeconds * 1_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let data else { return nil }

        struct Payload: Decodable {
            struct Device: Decodable { let state: String }
            let devices: [String: [Device]]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return payload.devices.values.flatMap { $0 }.filter { $0.state == "Booted" }.count
    }
}
