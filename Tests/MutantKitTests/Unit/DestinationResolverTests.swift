@testable import AppleBuildAdapters
import Foundation
import Testing

/// Pins `DestinationResolver`'s decision logic against a hand-built device
/// list — no real simulator or `simctl` call involved, so the ambiguity and
/// "latest runtime" rules this exists to enforce are testable without a
/// machine-specific simulator inventory.
@Suite("Destination resolver")
struct DestinationResolverTests {
    private static func device(_ name: String, runtime: String, udid: String? = nil) -> SimulatorDevice {
        SimulatorDevice(
            udid: udid ?? "\(name)-\(runtime)".replacingOccurrences(of: " ", with: "-"),
            name: name,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-\(runtime)",
            state: "Shutdown"
        )
    }

    // MARK: - Non-simulator destinations pass through untouched

    @Test("A macOS destination is not resolved, and has no device")
    func macOSDestinationPassesThrough() throws {
        let resolved = try DestinationResolver.resolve("platform=macOS", against: [])
        #expect(resolved.device == nil)
        #expect(resolved.destinationArgument == "platform=macOS")
    }

    @Test("A generic placeholder is not resolved, and has no device")
    func genericPlaceholderPassesThrough() throws {
        let resolved = try DestinationResolver.resolve("generic/platform=iOS", against: [
            Self.device("iPhone 16", runtime: "26-5")
        ])
        #expect(resolved.device == nil)
    }

    // MARK: - Already pinned to id=

    @Test("An id= destination resolves to the matching device")
    func idDestinationResolvesDirectly() throws {
        let target = Self.device("iPhone 16", runtime: "26-5", udid: "ABCD")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,id=ABCD", against: [target]
        )
        #expect(resolved.device?.udid == "ABCD")
        #expect(resolved.destinationArgument == "platform=iOS Simulator,id=ABCD")
    }

    @Test("An id= destination naming a UDID nothing has is rejected")
    func idDestinationUnknownUDIDIsRejected() {
        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve(
                "platform=iOS Simulator,id=NOPE", against: [Self.device("iPhone 16", runtime: "26-5")]
            )
        }
    }

    // MARK: - name=, no explicit OS: resolves to the highest installed runtime overall

    @Test("A unique name resolves cleanly")
    func uniqueNameResolves() throws {
        let target = Self.device("Example iPad mini", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=Example iPad mini", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    @Test("A name matching devices under two runtimes resolves to the higher-version one")
    func nameUnderTwoRuntimesResolvesToLatest() throws {
        let older = Self.device("iPhone 16e", runtime: "26-3-1")
        let latest = Self.device("iPhone 16e", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e", against: [older, latest]
        )
        #expect(resolved.device?.udid == latest.udid)
    }

    /// The exact bug this exists to prevent: a name that only exists under
    /// an older runtime, while a *different* device name exists under the
    /// actual latest — silently picking the old-runtime device (what
    /// `SimulatorPool`'s own name-substring matching used to risk) would
    /// have been wrong. This must error, not guess.
    @Test("A name that exists only under an old runtime is a hard error, not a silent fallback")
    func nameOnlyUnderOldRuntimeIsRejected() {
        let oldOnly = Self.device("Example iPad mini", runtime: "26-3-1")
        let somethingElseIsLatest = Self.device("Other Device", runtime: "26-5")

        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve(
                "platform=iOS Simulator,name=Example iPad mini", against: [oldOnly, somethingElseIsLatest]
            )
        }
    }

    @Test("A name matching no device at all is a hard error")
    func nameNotFoundIsRejected() {
        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve(
                "platform=iOS Simulator,name=Does Not Exist", against: [Self.device("iPhone 16", runtime: "26-5")]
            )
        }
    }

    // MARK: - name= with an explicit OS

    @Test("An explicit OS resolves to that runtime specifically, even if it is not latest")
    func explicitOSResolvesToNamedRuntime() throws {
        let older = Self.device("iPhone 16e", runtime: "26-3-1")
        let latest = Self.device("iPhone 16e", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=26-3-1", against: [older, latest]
        )
        #expect(resolved.device?.udid == older.udid)
    }

    @Test("OS=latest is treated the same as no explicit OS")
    func osLatestIsTreatedAsImplicit() throws {
        let older = Self.device("iPhone 16e", runtime: "26-3-1")
        let latest = Self.device("iPhone 16e", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=latest", against: [older, latest]
        )
        #expect(resolved.device?.udid == latest.udid)
    }

    // MARK: - Runtime version comparison is numeric, not lexicographic

    /// `iOS-26-10` must sort after `iOS-26-9` — a plain string comparison of
    /// the identifiers gets this backwards (`'1' < '9'`).
    @Test("Runtime version comparison is numeric: iOS-26-10 is newer than iOS-26-9")
    func versionComparisonIsNumericNotLexicographic() throws {
        let nine = Self.device("iPhone 16e", runtime: "26-9")
        let ten = Self.device("iPhone 16e", runtime: "26-10")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e", against: [nine, ten]
        )
        #expect(resolved.device?.udid == ten.udid)
    }

    // MARK: - Round trip

    @Test("A resolved destination survives JSON encoding")
    func resolvedDestinationRoundTrips() throws {
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=X", against: [Self.device("X", runtime: "26-5")]
        )
        let data = try JSONEncoder().encode(resolved)
        let decoded = try JSONDecoder().decode(ResolvedDestination.self, from: data)
        #expect(decoded == resolved)
    }

    // MARK: - tvOS/watchOS/visionOS (Phase C10, competitive-parity program)

    private static func device(_ name: String, platformRuntimeIdentifier: String, udid: String? = nil) -> SimulatorDevice {
        SimulatorDevice(
            udid: udid ?? "\(name)-\(platformRuntimeIdentifier)".replacingOccurrences(of: " ", with: "-"),
            name: name,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.\(platformRuntimeIdentifier)",
            state: "Shutdown"
        )
    }

    /// Before this phase, a `tvOS Simulator`/`watchOS Simulator`/`visionOS
    /// Simulator` destination never reached this type's name/UDID pinning
    /// logic at all -- `isSimulatorDestination` only recognized `"iOS
    /// Simulator"`, so every one of these fell through to `device: nil`,
    /// silently reintroducing the exact per-invocation "OS:latest" ambiguity
    /// this type exists to eliminate for iOS.
    @Test("A tvOS Simulator destination is now pinned by name, exactly like iOS")
    func tvOSDestinationIsPinned() throws {
        let target = Self.device("Apple TV 4K (3rd generation)", platformRuntimeIdentifier: "tvOS-18-0")
        let resolved = try DestinationResolver.resolve(
            "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    @Test("A watchOS Simulator destination is now pinned by name, exactly like iOS")
    func watchOSDestinationIsPinned() throws {
        let target = Self.device("Apple Watch Series 10 (46mm)", platformRuntimeIdentifier: "watchOS-11-0")
        let resolved = try DestinationResolver.resolve(
            "platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    /// visionOS's own `SimRuntime` identifier segment is `xrOS`, not
    /// `visionOS` -- real Apple naming this resolver must translate, not a
    /// typo either direction.
    @Test("A visionOS Simulator destination resolves against its xrOS-prefixed runtime identifier")
    func visionOSDestinationIsPinnedDespiteXROSRuntimeToken() throws {
        let target = Self.device("Apple Vision Pro", platformRuntimeIdentifier: "xrOS-2-0")
        let resolved = try DestinationResolver.resolve(
            "platform=visionOS Simulator,name=Apple Vision Pro", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    /// The core soundness fix: "latest installed runtime" must be scoped to
    /// the *requested platform*, not computed across every simulator
    /// platform installed on the machine. A tvOS 26 runtime numerically
    /// outranks an iOS 18 one, but resolving an unqualified iOS destination
    /// must never let that tvOS runtime win "latest" and produce an
    /// `ambiguousAcrossRuntimes`/wrong-device result for a plain iOS ask.
    @Test("Latest-runtime resolution for an iOS destination ignores a numerically newer tvOS runtime")
    func latestRuntimeIsScopedToRequestedPlatformNotGlobalMax() throws {
        let iphone = Self.device("iPhone 16", platformRuntimeIdentifier: "iOS-18-0")
        let appleTV = Self.device("Apple TV 4K (3rd generation)", platformRuntimeIdentifier: "tvOS-26-0")

        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16", against: [iphone, appleTV]
        )

        #expect(resolved.device?.udid == iphone.udid, "a numerically-newer tvOS runtime must never be selected as \"latest\" for an iOS request")
    }

    /// The mirror of the test above, from the tvOS side: resolving an
    /// unqualified tvOS destination among two tvOS runtime versions must
    /// pick the newer tvOS one, not be confused by a coexisting iOS runtime
    /// of either version.
    @Test("Latest-runtime resolution for a tvOS destination picks the newer tvOS runtime, ignoring iOS runtimes entirely")
    func latestRuntimeForTVOSIgnoresCoexistingIOSRuntimes() throws {
        let oldAppleTV = Self.device("Apple TV 4K (3rd generation)", platformRuntimeIdentifier: "tvOS-17-0")
        let newAppleTV = Self.device("Apple TV 4K (3rd generation)", platformRuntimeIdentifier: "tvOS-18-0")
        let iphone = Self.device("Apple TV 4K (3rd generation)", platformRuntimeIdentifier: "iOS-26-5")

        let resolved = try DestinationResolver.resolve(
            "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)", against: [oldAppleTV, newAppleTV, iphone]
        )

        #expect(resolved.device?.udid == newAppleTV.udid)
    }

    @Test("SimulatorDevice.destination reports the device's own real platform, not a hardcoded iOS Simulator")
    func destinationStringReportsRealPlatform() {
        #expect(Self.device("Apple TV", platformRuntimeIdentifier: "tvOS-18-0").destination.hasPrefix("platform=tvOS Simulator,id="))
        #expect(Self.device("Apple Watch", platformRuntimeIdentifier: "watchOS-11-0").destination.hasPrefix("platform=watchOS Simulator,id="))
        #expect(Self.device("Vision Pro", platformRuntimeIdentifier: "xrOS-2-0").destination.hasPrefix("platform=visionOS Simulator,id="))
        #expect(Self.device("iPhone", platformRuntimeIdentifier: "iOS-26-5").destination.hasPrefix("platform=iOS Simulator,id="))
    }
}
