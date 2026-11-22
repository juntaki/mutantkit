@testable import AppleBuildAdapters
import Foundation
import Testing

/// `Acceptance.iPhoneDestination` is what every simulator-backed acceptance job
/// feeds `xcodebuild`. On GitHub's `xcode-27-arm64` image it built
/// `…,OS=27.2.4` from `iOS-27-2-iPhone19-4`, a destination no simulator has,
/// and all 13 jobs failed. These drive its pure selection with runner-shaped
/// `simctl` payloads.
@Suite("Acceptance iPhone destination selection")
struct AcceptanceIPhoneDestinationTests {
    private static let p = SimctlFixtures.prefix
    private static let deviceSpecific = p + "iOS-27-2-iPhone19-4"
    private static let generic = p + "iOS-27-1"

    private static func destination(_ devices: [String: [(udid: String, name: String)]]) throws -> String {
        try Acceptance.iPhoneDestination(
            runtimesJSON: Data(SimctlFixtures.runtimesJSON([
                .init(generic, "27.1", "iOS"), .init(deviceSpecific, "27.2", "iOS")
            ]).utf8),
            devicesJSON: Data(SimctlFixtures.devicesJSON(devices).utf8)
        )
    }

    @Test("Devices only under iOS-27-1 (the CI listing): a resolvable id= destination, no phantom 27.2.4")
    func devicesOnlyUnderTheGenericRuntime() throws {
        let result = try Self.destination([Self.generic: [("UDID-271-DUO", "iPhone Duo")], Self.deviceSpecific: []])
        #expect(result == "platform=iOS Simulator,id=UDID-271-DUO")
        #expect(!result.contains("27.2.4"))
    }

    @Test("A device under iOS-27-2-iPhone19-4 is OS 27.2: it wins, addressed by UDID")
    func deviceUnderTheSpecificRuntime() throws {
        let result = try Self.destination([
            Self.generic: [("UDID-271-DUO", "iPhone Duo")], Self.deviceSpecific: [("UDID-272-DUO", "iPhone Duo")]
        ])
        #expect(result == "platform=iOS Simulator,id=UDID-272-DUO")
        #expect(!result.contains("OS="))
    }

    @Test("No iPhone at all throws noSimulator")
    func noIPhone() {
        #expect(throws: AcceptanceError.self) { try Self.destination([Self.generic: [("U", "iPad Pro")]]) }
    }

    @Test("The accepted detector destinations require a non-empty UDID after `id=`")
    func emptyUDIDIsRejected() {
        let prefix = "platform=iOS Simulator,id="
        #expect(Acceptance.isDetectedIOSSimulatorDestination(prefix + "UDID-1"))
        #expect(!Acceptance.isDetectedIOSSimulatorDestination(prefix))
        #expect(!Acceptance.isDetectedIOSSimulatorDestination(prefix + ",name=x"))
        #expect(Acceptance.containsDetectedDestination("destination: ", in: "destination: " + prefix + "UDID-1\n"))
        #expect(!Acceptance.containsDetectedDestination("destination: ", in: "destination: " + prefix + "\n"))
    }
}
