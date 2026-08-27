@testable import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationModel
import Testing

/// Real, subprocess-backed tests for `ToolchainProbe`'s two P4 (cache-
/// soundness gap 2) fields — `buildSDKIdentity`/`destinationRuntimeIdentity`
/// — run against this machine's actual `xcrun`/`xcodebuild`, the same
/// "ask the real environment" convention `ToolchainProbe` itself already
/// follows for `swiftVersion`/`xcodeVersion`. See `Research/mutation-
/// testing-hardening-2026-08/PROGRESS.md`'s P4 gap 2 entry for the
/// real-machine evidence (two iOS simulator runtimes/SDK builds coexisting
/// under one Xcode install) this closes.
@Suite("ToolchainProbe: build SDK / destination runtime identity")
struct ToolchainProbeTests {
    private func fingerprint(for resolvedDestination: ResolvedDestination?) async -> ToolchainFingerprint {
        await ToolchainProbe.fingerprint(workingDirectory: FileManager.default.temporaryDirectory, resolvedDestination: resolvedDestination)
    }

    private func simulator(udid: String, runtimeIdentifier: String = "com.apple.CoreSimulator.SimRuntime.iOS-26-5") -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: "iPhone 16e", runtimeIdentifier: runtimeIdentifier, state: "Booted")
    }

    /// Adversarial test C: two clones under the *identical* runtime, only
    /// their UDIDs differing, must resolve to the identical
    /// `destinationRuntimeIdentity`. This tool's own isolation design
    /// already guarantees identical-runtime clones produce identical
    /// verdicts — keying on UDID would hide a real isolation defect behind
    /// a cache miss instead of surfacing it, so the UDID must never even
    /// reach the identity string in the first place.
    @Test("Two clones under one runtime, different UDIDs, resolve to the identical destinationRuntimeIdentity")
    func identicalRuntimeDifferentUDIDsProduceTheIdenticalIdentity() async throws {
        let requested = "platform=iOS Simulator,name=iPhone 16e"
        let cloneA = ResolvedDestination(requested: requested, device: simulator(udid: "AAAAAAAA-0000-0000-0000-000000000000"))
        let cloneB = ResolvedDestination(requested: requested, device: simulator(udid: "BBBBBBBB-1111-1111-1111-111111111111"))

        let fingerprintA = await fingerprint(for: cloneA)
        let fingerprintB = await fingerprint(for: cloneB)

        #expect(fingerprintA.destinationRuntimeIdentity == fingerprintB.destinationRuntimeIdentity)
        #expect(fingerprintA.destinationRuntimeIdentity == "simulator:com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    }

    @Test("A resolved simulator device's runtime identifier becomes destinationRuntimeIdentity, verbatim and prefixed")
    func resolvedDeviceRuntimeBecomesDestinationRuntimeIdentity() async throws {
        let resolved = ResolvedDestination(
            requested: "platform=iOS Simulator,name=iPhone 16e", device: simulator(udid: "12345678-0000-0000-0000-000000000000")
        )

        let fingerprint = await fingerprint(for: resolved)

        #expect(fingerprint.destinationRuntimeIdentity == "simulator:com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    }

    @Test("A macOS destination with no simulator device produces a macosx buildSDKIdentity and no destinationRuntimeIdentity")
    func macOSDestinationProducesBuildSDKIdentityNoRuntimeIdentity() async throws {
        let resolved = ResolvedDestination(requested: "platform=macOS", device: nil)

        let fingerprint = await fingerprint(for: resolved)

        #expect(fingerprint.destinationRuntimeIdentity == nil, "a macOS destination has no simulator runtime to report")
        // Only asserted when a real toolchain is actually present (this
        // suite's own machine has one) — `firstLine` already treats an
        // unreadable probe as `nil` rather than a thrown error, matching
        // `xcodeVersion`'s own convention, so this is a soft check, not a
        // hard requirement of the type itself.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            #expect(fingerprint.buildSDKIdentity?.hasPrefix("sdk:macosx:") == true)
        }
    }

    @Test("An iOS Simulator destination produces both a real iphonesimulator buildSDKIdentity and a destinationRuntimeIdentity")
    func iOSSimulatorDestinationProducesBothIdentities() async throws {
        let resolved = ResolvedDestination(
            requested: "platform=iOS Simulator,name=iPhone 16e", device: simulator(udid: "12345678-0000-0000-0000-000000000000")
        )

        let fingerprint = await fingerprint(for: resolved)

        #expect(fingerprint.destinationRuntimeIdentity == "simulator:com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            #expect(fingerprint.buildSDKIdentity?.hasPrefix("sdk:iphonesimulator:") == true)
        }
    }

    @Test("No resolved destination at all (plan time) reports neither identity, never a guess")
    func noResolvedDestinationReportsNeitherIdentity() async throws {
        let fingerprint = await fingerprint(for: nil)

        #expect(fingerprint.buildSDKIdentity == nil)
        #expect(fingerprint.destinationRuntimeIdentity == nil)
    }

    @Test("A destination platform value this catalog does not model an SDK name for reports no buildSDKIdentity, never a guess")
    func unmodeledPlatformValueReportsNoBuildSDKIdentity() async throws {
        // `platform=macOS,variant=Mac Catalyst` is a real, legal destination
        // this codebase already knows is not interchangeable with plain
        // macOS (`SchemataRuntimePlatform`'s own doc comment) — deliberately
        // unmodeled here too, on the same fail-closed footing, rather than
        // guessing it means plain `macosx`.
        let resolved = ResolvedDestination(requested: "platform=macOS,variant=Mac Catalyst", device: nil)

        let fingerprint = await fingerprint(for: resolved)

        #expect(fingerprint.buildSDKIdentity == nil)
    }
}
