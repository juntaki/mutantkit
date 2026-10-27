import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// "Nothing new is built or tested" after a run-level abort, at the one
/// place every build and test process goes through: once the run's monitor
/// has tripped, `ProcessSupervisor.run` refuses to launch. Only teardown
/// (deleting the simulators the run cloned) may still launch.
@Suite("ProcessSupervisor: no launch after the run-level abort", .subprocessExclusive)
struct ProcessSupervisorAbortGateTests {
    @Test("A tripped monitor refuses the launch and the process never runs")
    func trippedMonitorRefusesLaunch() async throws {
        let marker = Self.markerURL()
        let monitor = RunContainmentMonitor()
        monitor.recordUnverifiedCleanup("injected trip")

        await #expect(throws: RunAbortedError.self) {
            try await RunContainmentMonitor.$current.withValue(monitor) { try await Self.touch(marker) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the refused process must never start")
    }

    @Test("Control: an untripped monitor launches the process")
    func untrippedMonitorLaunches() async throws {
        let marker = Self.markerURL()
        let monitor = RunContainmentMonitor()

        let result = try await RunContainmentMonitor.$current.withValue(monitor) { try await Self.touch(marker) }
        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A teardown launch still runs after the trip")
    func teardownLaunchRunsAfterTheTrip() async throws {
        let marker = Self.markerURL()
        let monitor = RunContainmentMonitor()
        monitor.recordUnverifiedCleanup("injected trip")

        let result = try await RunContainmentMonitor.$current.withValue(monitor) {
            try await RunContainmentMonitor.permittingTeardownLaunches { try await Self.touch(marker) }
        }
        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Deleting a cloned simulator is teardown: it still launches after the trip")
    func simulatorDeleteRunsAfterTheTrip() async throws {
        let launched = LaunchLog()
        let pool = SimulatorPool(
            workingDirectory: FileManager.default.temporaryDirectory,
            processRunner: { _, arguments, directory, timeout in
                // A real supervised launch, so the abort gate applies.
                let result = try await ProcessSupervisor.run(
                    executable: "/usr/bin/true", arguments: [], workingDirectory: directory, timeoutSeconds: timeout
                )
                await launched.append(arguments)
                return result
            }
        )
        let monitor = RunContainmentMonitor()
        monitor.recordUnverifiedCleanup("injected trip")

        try await RunContainmentMonitor.$current.withValue(monitor) {
            try await pool.deleteDevice(udid: "CLONE-UDID")
        }
        #expect(await launched.entries == [["simctl", "shutdown", "CLONE-UDID"], ["simctl", "delete", "CLONE-UDID"]])
    }

    private actor LaunchLog {
        private(set) var entries: [[String]] = []
        func append(_ arguments: [String]) { entries.append(arguments) }
    }

    private static func markerURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-abort-gate-\(UUID().uuidString)")
    }

    private static func touch(_ marker: URL) async throws -> ProcessResult {
        try await ProcessSupervisor.run(
            executable: "/usr/bin/touch", arguments: [marker.path],
            workingDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 30
        )
    }
}
