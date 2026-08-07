import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Codex review finding: `RunCommand`'s `RunIsolationLock` was keyed on the
/// raw, as-configured `mutantkit.yml` destination string
/// (`settings.project.destination ?? "auto"`), not on the destination as
/// actually *resolved* to a concrete simulator. Two independent MutantKit
/// processes whose configs spelled the same physical device differently —
/// one leaving `destination` unset, the other spelling out
/// `platform=iOS Simulator,name=<that same auto-picked device>` — took
/// different lock keys and could both boot/prepare/test that one simulator
/// concurrently: exactly the race `RunIsolationLock` exists to prevent.
///
/// `RunCommand.lockIdentity(for:configuredDestination:)` is the pure
/// extraction of that key computation, testable without a real Xcode
/// project or simulator.
@Suite("RunCommand: lock identity keyed on resolved destination")
struct RunCommandLockIdentityTests {
    private func device(udid: String, name: String = "iPhone 17 Pro") -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: name, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2", state: "Shutdown")
    }

    private func xcodeAdapter(resolvedDestination: ResolvedDestination?) -> XcodeBuildProjectAdapter {
        XcodeBuildProjectAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-need-to-exist"),
            resolvedDestination: resolvedDestination
        )
    }

    @Test("Two differently-spelled destinations that resolve to the same device produce the same lock identity")
    func sameDeviceDifferentRawStringsProduceSameKey() {
        let sameDevice = device(udid: "AAAA-BBBB")

        let unset = xcodeAdapter(resolvedDestination: ResolvedDestination(requested: "auto", device: sameDevice))
        let explicit = xcodeAdapter(
            resolvedDestination: ResolvedDestination(
                requested: "platform=iOS Simulator,name=iPhone 17 Pro", device: sameDevice
            )
        )

        let unsetKey = RunCommand.lockIdentity(for: unset, configuredDestination: nil)
        let explicitKey = RunCommand.lockIdentity(
            for: explicit, configuredDestination: "platform=iOS Simulator,name=iPhone 17 Pro"
        )

        #expect(unsetKey == explicitKey, "both resolve to the same device and must collide on one lock key")
        #expect(unsetKey == sameDevice.destination, "the key should be the resolved device's own destination argument")
    }

    @Test("A name and a UDID for the same device produce the same lock identity")
    func nameAndUDIDForSameDeviceProduceSameKey() {
        let sameDevice = device(udid: "CCCC-DDDD")

        let byName = xcodeAdapter(
            resolvedDestination: ResolvedDestination(
                requested: "platform=iOS Simulator,name=iPhone 17 Pro", device: sameDevice
            )
        )
        let byUDID = xcodeAdapter(
            resolvedDestination: ResolvedDestination(
                requested: "platform=iOS Simulator,id=CCCC-DDDD", device: sameDevice
            )
        )

        let nameKey = RunCommand.lockIdentity(for: byName, configuredDestination: "platform=iOS Simulator,name=iPhone 17 Pro")
        let udidKey = RunCommand.lockIdentity(for: byUDID, configuredDestination: "platform=iOS Simulator,id=CCCC-DDDD")

        #expect(nameKey == udidKey)
    }

    @Test("A destination that never resolved to a concrete device falls back to the raw configured string")
    func unresolvedDestinationFallsBackToRawString() {
        let unresolved = xcodeAdapter(
            resolvedDestination: ResolvedDestination(requested: "generic/platform=iOS", device: nil)
        )

        let key = RunCommand.lockIdentity(for: unresolved, configuredDestination: "generic/platform=iOS")

        #expect(key == "generic/platform=iOS")
    }

    @Test("No resolution performed at all falls back to the raw configured string, or \"auto\" when unset")
    func noResolutionFallsBackToConfiguredStringOrAuto() {
        let neverResolved = xcodeAdapter(resolvedDestination: nil)

        #expect(RunCommand.lockIdentity(for: neverResolved, configuredDestination: "platform=macOS") == "platform=macOS")
        #expect(RunCommand.lockIdentity(for: neverResolved, configuredDestination: nil) == "auto")
    }

    @Test("A non-Xcode adapter with no destination concept does not crash and falls back sensibly")
    func nonXcodeAdapterFallsBackWithoutCrashing() {
        let swiftPackage = SwiftPackageMacOSProjectAdapter(configuration: Configuration())

        #expect(RunCommand.lockIdentity(for: swiftPackage, configuredDestination: nil) == "auto")
        #expect(RunCommand.lockIdentity(for: swiftPackage, configuredDestination: "platform=macOS") == "platform=macOS")
    }
}
