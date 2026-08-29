@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `XcodeBuildAdapter.prepareSimulatorForRun()` used to drop its result with
/// `try?`, leaving no record of whether the simulator came warm, cold, or
/// failed readiness. It now returns a `SimulatorPreparationRecord`. These
/// tests pin the four outcomes against a scripted `SimulatorPool`, using the
/// adapter's internal pool-injection initializer — the only seam that lets
/// the mapping run without a real simulator.
@Suite("XcodeBuildAdapter simulator preparation")
struct XcodeBuildAdapterSimulatorPreparationTests {
    private static let udid = "C0FFEE-0000-0000-0000-000000000002"
    private static let workingDirectory = FileManager.default.temporaryDirectory

    private static let shutdownDeviceJSON = """
    {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "\(udid)", "name": "iPhone 16", "state": "Shutdown", "isAvailable": true}
    ]}}
    """

    private static let bootedDeviceJSON = """
    {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "\(udid)", "name": "iPhone 16", "state": "Booted", "isAvailable": true}
    ]}}
    """

    private func makeAdapter(
        device: SimulatorDevice?,
        deviceJSON: String = shutdownDeviceJSON,
        respond: @escaping @Sendable ([String]) throws -> ProcessResult
    ) -> XcodeBuildAdapter {
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: { _, arguments, _, _ in
                if arguments.contains("list") {
                    return ProcessResult(
                        exitCode: 0,
                        standardOutput: Data(deviceJSON.utf8),
                        standardError: Data(),
                        durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
                    )
                }
                return try respond(arguments)
            }
        )
        let destination = ResolvedDestination(
            requested: "platform=iOS Simulator,name=iPhone 16",
            device: device
        )
        return XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: Self.workingDirectory,
            resolvedDestination: destination,
            simulators: pool
        )
    }

    private func success() -> ProcessResult {
        ProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data(),
                      durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true)
    }

    private func failure(_ stderr: String) -> ProcessResult {
        ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data(stderr.utf8),
                      durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true)
    }

    private var device: SimulatorDevice {
        SimulatorDevice(udid: Self.udid, name: "iPhone 16",
                        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", state: "Shutdown")
    }

    @Test("A nil destination yields notApplicable")
    func nilDestinationIsNotApplicable() async {
        let adapter = XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .swiftPackageMacOS,
            projectFile: nil,
            projectRoot: Self.workingDirectory,
            resolvedDestination: nil,
            simulators: SimulatorPool(workingDirectory: Self.workingDirectory)
        )

        let record = await adapter.prepareSimulatorForRun()

        #expect(record.outcome == .notApplicable)
        #expect(record.udid == nil)
    }

    @Test("A cold device that verifies ready is reported as prepared")
    func coldDeviceIsPrepared() async {
        let adapter = makeAdapter(device: device) { _ in self.success() }

        let record = await adapter.prepareSimulatorForRun()

        #expect(record.outcome == .prepared)
        #expect(record.udid == Self.udid)
        #expect(record.name == "iPhone 16")
        #expect(record.detail == nil)
    }

    @Test("A warm device is reported as alreadyBooted even though boot exits non-zero")
    func warmDeviceIsAlreadyBooted() async {
        let adapter = makeAdapter(device: device, deviceJSON: Self.bootedDeviceJSON) { arguments in
            // `simctl boot` is non-zero for an already-booted device; readiness
            // still comes from bootstatus, which succeeds.
            if arguments.contains("bootstatus") {
                return self.success()
            }
            return self.failure("Unable to boot device in current state: Booted")
        }

        let record = await adapter.prepareSimulatorForRun()

        #expect(record.outcome == .alreadyBooted)
        #expect(record.detail == nil)
    }

    @Test("A device that fails bootstatus is reported as failed, with the detail")
    func failedReadinessIsRecordedNotSwallowed() async {
        let adapter = makeAdapter(device: device) { arguments in
            // bootstatus failing is what makes readiness fail.
            if arguments.contains("bootstatus") {
                return self.failure("Device never became ready")
            }
            return self.success()
        }

        let record = await adapter.prepareSimulatorForRun()

        #expect(record.outcome == .failed)
        #expect(record.udid == Self.udid)
        #expect(record.detail?.contains("never became ready") == true)
    }
}
