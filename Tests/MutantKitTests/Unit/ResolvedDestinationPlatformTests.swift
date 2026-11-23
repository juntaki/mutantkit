@testable import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// `ResolvedDestination.destinationArgument` must label the device by its own
/// runtime platform (recorded at resolve time from the catalog), never by what
/// the user's `requested` string says — it is also the run-lock key.
@Suite("Resolved destination platform label")
struct ResolvedDestinationPlatformTests {
    private static let main = """
    {"requested":"platform=iOS Simulator,name=iPhone 17 Pro","device":{"udid":"UDID-1","name":"iPhone 17 Pro",\
    "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","state":"Booted"}}
    """

    @Test("The platform=… in the destination is read as a field: a watchOS destination for a device named `iOS Simulator Lab` is watchOS")
    func platformIsReadFromTheField() throws {
        let watch = SimctlFixtures.device(
            "iOS Simulator Lab", udid: "W", identifier: SimctlFixtures.prefix + "watchOS-11-0", platform: "watchOS", version: "11.0"
        )
        let phone = SimctlFixtures.device("iOS Simulator Lab", udid: "I", version: "26.0")
        let resolved = try DestinationResolver.resolve("platform=watchOS Simulator,name=iOS Simulator Lab", against: [phone, watch])
        #expect(resolved.device?.udid == "W")
        #expect(resolved.destinationArgument == "platform=watchOS Simulator,id=W")
    }

    @Test("A stale label for an id= destination is replaced by the device's real platform")
    func staleLabelIsReplaced() throws {
        let ios = SimctlFixtures.device("iPhone", udid: "U", version: "26.0")
        for requested in ["platform=iOS Simulator,id=U", "platform=tvOS Simulator,id=U"] {
            #expect(try DestinationResolver.resolve(requested, against: [ios]).destinationArgument == "platform=iOS Simulator,id=U")
        }
    }

    @Test("A main-format record has no platform, decodes, and re-encodes with main's four device keys")
    func mainFormatDecodes() throws {
        let decoded = try JSONDecoder().decode(ResolvedDestination.self, from: Data(Self.main.utf8))
        #expect(decoded.platform == nil)
        #expect(decoded.device?.udid == "UDID-1")
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(Set(try #require(encoded["device"] as? [String: Any]).keys) == ["udid", "name", "runtimeIdentifier", "state"])
        #expect(encoded["platform"] == nil, "an absent platform is not written, so main-format bytes round-trip")
    }

    private func pool(devices: [String: [(udid: String, name: String)]]) -> SimulatorPool {
        SimulatorPool(workingDirectory: FileManager.default.temporaryDirectory, processRunner: { _, arguments, _, _ in
            let body = arguments.contains("runtimes")
                ? SimctlFixtures.runtimesJSON([.init(SimctlFixtures.prefix + "iOS-26-0", "26.0", "iOS")])
                : SimctlFixtures.devicesJSON(devices)
            return ProcessResult(
                exitCode: 0, standardOutput: Data(body.utf8), standardError: Data(),
                durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
            )
        })
    }

    private func writeMainFormatManifest() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-manifest-\(UUID().uuidString).json")
        let device = SimulatorDevice(
            udid: "UDID-1", name: "iPhone 17 Pro", runtimeIdentifier: SimctlFixtures.prefix + "iOS-26-0", state: "Booted"
        )
        // `platform` is nil, so `RunManifest.write` (main's `.sortedKeys`, `.prettyPrinted`, iso8601 encoder)
        // emits exactly the bytes main wrote for this record.
        try RunManifest(
            planID: "plan", workUnitID: "wu", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            resolvedDestination: ResolvedDestination(requested: "platform=iOS Simulator,name=iPhone 17 Pro", device: device),
            scheme: nil, testTargets: [], extraTestArguments: [], mutantTimeoutSeconds: 30, baselineTimeoutSeconds: 600,
            toolchain: makeToolchain(), configurationHash: "hash", resourceSnapshot: nil, simulatorPreparation: nil
        ).write(to: url)
        return url
    }

    @Test("Replaying a main-format manifest takes the platform from the live catalog")
    func replayLooksUpThePlatform() async throws {
        let url = try writeMainFormatManifest()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\"platform\""), "main-format: no platform key on disk")

        let recorded = try #require(try RunManifest.read(from: url).resolvedDestination)
        #expect(recorded.destinationArgument == "id=UDID-1", "never guessed from `requested` while the platform is unknown")
        let completed = try await DestinationResolver.completingForReplay(
            recorded, using: pool(devices: [SimctlFixtures.prefix + "iOS-26-0": [("UDID-1", "iPhone 17 Pro")]])
        )
        #expect(completed.destinationArgument == "platform=iOS Simulator,id=UDID-1")
    }

    @Test("Replaying fails closed, with a clear message, when the recorded simulator is gone")
    func replayFailsClosedWhenTheDeviceIsGone() async throws {
        let url = try writeMainFormatManifest()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorded = try #require(try RunManifest.read(from: url).resolvedDestination)
        let error = await #expect(throws: DestinationResolutionError.self) {
            try await DestinationResolver.completingForReplay(
                recorded, using: pool(devices: [SimctlFixtures.prefix + "iOS-26-0": [("OTHER", "iPhone 16")]])
            )
        }
        #expect(error?.description.contains("UDID-1") == true)
        #expect(error?.description.contains("cannot be replayed") == true)
    }

    @Test("A branch-format record (platform present) is replayed only if its UDID is still in the live catalog")
    func branchFormatReplayFailsClosedWhenTheDeviceIsGone() async throws {
        let device = SimulatorDevice(
            udid: "UDID-1", name: "iPhone 17 Pro", runtimeIdentifier: SimctlFixtures.prefix + "iOS-26-0", state: "Booted"
        )
        let recorded = ResolvedDestination(requested: "platform=iOS Simulator,name=iPhone 17 Pro", device: device, platform: "iOS")
        let error = await #expect(throws: DestinationResolutionError.self) {
            try await DestinationResolver.completingForReplay(
                recorded, using: pool(devices: [SimctlFixtures.prefix + "iOS-26-0": [("OTHER", "iPhone 16")]])
            )
        }
        #expect(error?.description.contains("cannot be replayed") == true)
        let kept = try await DestinationResolver.completingForReplay(
            recorded, using: pool(devices: [SimctlFixtures.prefix + "iOS-26-0": [("UDID-1", "iPhone 17 Pro")]])
        )
        #expect(kept.destinationArgument == "platform=iOS Simulator,id=UDID-1")
    }
}
