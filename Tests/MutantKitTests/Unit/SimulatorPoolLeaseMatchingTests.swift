@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

@Suite("Simulator pool: lease(matching:)")
struct SimulatorPoolLeaseMatchingTests {
    private static let list = """
    {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "AAAA0000-0000-0000-0000-000000000001", "name": "iPhone 16", "state": "Shutdown", "isAvailable": true},
        {"udid": "AAAA0000-0000-0000-0000-000000000002", "name": "iPad Air", "state": "Shutdown", "isAvailable": true}
    ]}}
    """

    private func pool() -> SimulatorPool {
        SimulatorPool(
            workingDirectory: FileManager.default.temporaryDirectory,
            processRunner: { _, _, _, _ in
                ProcessResult(
                    exitCode: 0, standardOutput: Data(Self.list.utf8), standardError: Data(),
                    durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
                )
            }
        )
    }

    @Test("Without a hint any available device is leased")
    func noHintLeasesAnyDevice() async throws {
        let lease = try await pool().lease(matching: nil)
        #expect(["iPhone 16", "iPad Air"].contains(lease.device.name))
    }

    @Test("A hint narrows the lease by device name or runtime")
    func hintNarrowsTheLease() async throws {
        #expect(try await pool().lease(matching: "iPad").device.name == "iPad Air")
        #expect(try await pool().lease(matching: "iOS-18").device.name.isEmpty == false)
    }

    @Test("A hint that matches nothing is reported as none available")
    func unmatchedHintThrows() async {
        await #expect(throws: SimulatorPoolError.self) {
            _ = try await pool().lease(matching: "watchOS")
        }
    }
}
