@testable import AppleBuildAdapters
import Foundation
import Testing

/// Pins `DestinationResolver`'s decision logic against a hand-built device
/// list — no real simulator or `simctl` call involved, so the ambiguity and
/// "latest runtime" rules this exists to enforce are testable without a
/// machine-specific simulator inventory.
@Suite("Destination resolver")
struct DestinationResolverTests {
    /// An iOS device on a runtime of `version` ("26.5"); the identifier is an
    /// arbitrary opaque key, never read for a version.
    private static func device(_ name: String, version: String, udid: String? = nil) -> CatalogDevice {
        SimctlFixtures.device(name, udid: udid, identifier: SimctlFixtures.prefix + "iOS-\(version)", version: version)
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
            Self.device("iPhone 16", version: "26.5")
        ])
        #expect(resolved.device == nil)
    }

    // MARK: - Already pinned to id=

    @Test("An id= destination resolves to the matching device")
    func idDestinationResolvesDirectly() throws {
        let target = Self.device("iPhone 16", version: "26.5", udid: "ABCD")
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
                "platform=iOS Simulator,id=NOPE", against: [Self.device("iPhone 16", version: "26.5")]
            )
        }
    }

    @Test("Built-in default literal missing: the error says no project.destination is configured")
    func builtInDefaultNotFoundMessage() {
        let defaultLiteral = DestinationResolver.defaultDestination(for: .xcodeProject)
        do {
            _ = try DestinationResolver.resolve(
                defaultLiteral, against: [Self.device("Example iPad mini", version: "26.5")], isBuiltInDefault: true
            )
            Issue.record("expected resolution to fail")
        } catch let error as DestinationResolutionError {
            let message = error.description
            #expect(message.contains("No `project.destination` is configured"))
            #expect(message.contains("built-in default \"iPhone 16\""))
            #expect(message.contains("mutantkit setup"))
            #expect(message.contains("Example iPad mini"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Explicit destination missing keeps the plain not-found message")
    func explicitDestinationNotFoundKeepsOldMessage() {
        do {
            _ = try DestinationResolver.resolve(
                "platform=iOS Simulator,name=iPhone 16", against: [Self.device("Example iPad mini", version: "26.5")]
            )
            Issue.record("expected resolution to fail")
        } catch let error as DestinationResolutionError {
            #expect(error.description == "No simulator named \"iPhone 16\" is available. Known device names: Example iPad mini.")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - name=, no explicit OS: resolves to the highest installed runtime overall

    @Test("A unique name resolves cleanly")
    func uniqueNameResolves() throws {
        let target = Self.device("Example iPad mini", version: "26.5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=Example iPad mini", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    @Test("A name matching devices under two runtimes resolves to the higher-version one")
    func nameUnderTwoRuntimesResolvesToLatest() throws {
        let older = Self.device("iPhone 16e", version: "26.3.1")
        let latest = Self.device("iPhone 16e", version: "26.5")
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
        let oldOnly = Self.device("Example iPad mini", version: "26.3.1")
        let somethingElseIsLatest = Self.device("Other Device", version: "26.5")

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
                "platform=iOS Simulator,name=Does Not Exist", against: [Self.device("iPhone 16", version: "26.5")]
            )
        }
    }

    // MARK: - name= with an explicit OS

    @Test("An explicit OS resolves to that runtime specifically, even if it is not latest")
    func explicitOSResolvesToNamedRuntime() throws {
        let older = Self.device("iPhone 16e", version: "26.3.1")
        let latest = Self.device("iPhone 16e", version: "26.5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=26.3.1", against: [older, latest]
        )
        #expect(resolved.device?.udid == older.udid)
    }

    @Test("A configured OS in the older hyphen spelling (OS=26-3-1) still resolves")
    func hyphenatedConfiguredOSResolves() throws {
        let older = Self.device("iPhone 16e", version: "26.3.1")
        let latest = Self.device("iPhone 16e", version: "26.5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=26-3-1", against: [older, latest]
        )
        #expect(resolved.device?.udid == older.udid)
    }

    @Test("OS matching is exact and numeric: 26.3 equals 26.3.0 but does not match 26.3.1")
    func explicitOSIsExactNumeric() throws {
        let patch = Self.device("iPhone 16e", version: "26.3.1")
        let minor = Self.device("iPhone 16e", version: "26.3")
        let exact = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone 16e,OS=26.3.0", against: [patch, minor])
        #expect(exact.device?.udid == minor.udid)
        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone 16e,OS=26.3", against: [patch])
        }
    }

    @Test("An explicit OS written in xcodebuild's own dot-separated syntax resolves by numeric version")
    func explicitOSAcceptsXcodebuildDotSyntax() throws {
        let older = Self.device("iPhone 16e", version: "26.3.1")
        let latest = Self.device("iPhone 16e", version: "26.5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=26.3.1", against: [older, latest]
        )
        #expect(resolved.device?.udid == older.udid)
    }

    @Test("OS=latest is treated the same as no explicit OS")
    func osLatestIsTreatedAsImplicit() throws {
        let older = Self.device("iPhone 16e", version: "26.3.1")
        let latest = Self.device("iPhone 16e", version: "26.5")
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
        let nine = Self.device("iPhone 16e", version: "26.9")
        let ten = Self.device("iPhone 16e", version: "26.10")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e", against: [nine, ten]
        )
        #expect(resolved.device?.udid == ten.udid)
    }

    // MARK: - Round trip

    @Test("A resolved destination survives JSON encoding")
    func resolvedDestinationRoundTrips() throws {
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=X", against: [Self.device("X", version: "26.5")]
        )
        let data = try JSONEncoder().encode(resolved)
        let decoded = try JSONDecoder().decode(ResolvedDestination.self, from: data)
        #expect(decoded == resolved)
    }

    // MARK: - tvOS/watchOS/visionOS (Phase C10, competitive-parity program)

    /// Built through the catalog from a runtime whose `platform` field says `xrOS`
    /// and whose identifier uses the `xrOS-` segment, as `simctl` reports it.
    private static func xrOSDevice(_ name: String) throws -> CatalogDevice {
        try #require(SimctlFixtures.catalog(
            runtimes: [.init(SimctlFixtures.prefix + "xrOS-2-0", "2.0", "xrOS")],
            devices: [SimctlFixtures.prefix + "xrOS-2-0": [("XR-UDID", name)]]
        ).devices.first)
    }

    private static func device(_ name: String, platform: String, version: String, udid: String? = nil) -> CatalogDevice {
        SimctlFixtures.device(
            name, udid: udid, identifier: SimctlFixtures.prefix + "\(platform)-\(version)", platform: platform, version: version
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
        let target = Self.device("Apple TV 4K (3rd generation)", platform: "tvOS", version: "18.0")
        let resolved = try DestinationResolver.resolve(
            "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    @Test("A watchOS Simulator destination is now pinned by name, exactly like iOS")
    func watchOSDestinationIsPinned() throws {
        let target = Self.device("Apple Watch Series 10 (46mm)", platform: "watchOS", version: "11.0")
        let resolved = try DestinationResolver.resolve(
            "platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    /// visionOS's runtime is named `xrOS` by Apple (its `platform` field and its
    /// identifier); the catalog must translate that to `visionOS`, not a typo
    /// either direction.
    @Test("A visionOS Simulator destination resolves against a runtime whose platform field says xrOS")
    func visionOSDestinationIsPinnedDespiteXROSRuntimeToken() throws {
        let target = try Self.xrOSDevice("Apple Vision Pro")
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
        let iphone = Self.device("iPhone 16", platform: "iOS", version: "18.0")
        let appleTV = Self.device("Apple TV 4K (3rd generation)", platform: "tvOS", version: "26.0")

        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16", against: [iphone, appleTV]
        )

        #expect(resolved.device?.udid == iphone.udid,
                """
                a numerically-newer tvOS runtime must never be selected as "latest" for an iOS request
                """)
    }

    /// The mirror of the test above, from the tvOS side: resolving an
    /// unqualified tvOS destination among two tvOS runtime versions must
    /// pick the newer tvOS one, not be confused by a coexisting iOS runtime
    /// of either version.
    @Test("Latest-runtime resolution for a tvOS destination picks the newer tvOS runtime, ignoring iOS runtimes entirely")
    func latestRuntimeForTVOSIgnoresCoexistingIOSRuntimes() throws {
        let oldAppleTV = Self.device("Apple TV 4K (3rd generation)", platform: "tvOS", version: "17.0")
        let newAppleTV = Self.device("Apple TV 4K (3rd generation)", platform: "tvOS", version: "18.0")
        let iphone = Self.device("Apple TV 4K (3rd generation)", platform: "iOS", version: "26.5")

        let resolved = try DestinationResolver.resolve(
            "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)", against: [oldAppleTV, newAppleTV, iphone]
        )

        #expect(resolved.device?.udid == newAppleTV.udid)
    }

    @Test("CatalogDevice.destination reports the device's own real platform, not a hardcoded iOS Simulator")
    func destinationStringReportsRealPlatform() throws {
        #expect(Self.device("Apple TV", platform: "tvOS", version: "18.0").destination.hasPrefix("platform=tvOS Simulator,id="))
        let watch = Self.device("Apple Watch", platform: "watchOS", version: "11.0")
        #expect(watch.destination.hasPrefix("platform=watchOS Simulator,id="))
        #expect((try Self.xrOSDevice("Vision Pro")).destination.hasPrefix("platform=visionOS Simulator,id="))
        #expect(Self.device("iPhone", platform: "iOS", version: "26.5").destination.hasPrefix("platform=iOS Simulator,id="))
    }
}

/// Which destination a settings-only `xcodebuild` invocation is given.
///
/// `resolveSchemataBuildReceipt` used to read back its own chunk's product
/// location with the run's fully resolved `platform=iOS Simulator,id=<udid>`.
/// That query fails outright (exit 64, "Unable to find a device matching the
/// provided destination specifier") once the UDID stops resolving, which in
/// CI degraded an already-built, already-tested chunk to isolated with
/// `.buildReceiptUnavailable` — for a reason that had nothing to do with the
/// build. Nothing this settings reader consults varies by device, so the
/// device is dropped and the platform kept.
@Suite("Destination resolver: the settings-only destination drops the device")
struct BuildSettingsDestinationTests {
    @Test("Every simulator platform loses its device selector and keeps its platform")
    func simulatorDestinationsBecomeGeneric() {
        #expect(DestinationResolver.buildSettingsDestination(
            for: "platform=iOS Simulator,id=75EF742A-E1F8-4BB4-A0A9-2BB0EDA1D68F"
        ) == "generic/platform=iOS Simulator")
        #expect(DestinationResolver.buildSettingsDestination(
            for: "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0"
        ) == "generic/platform=iOS Simulator")
        #expect(DestinationResolver.buildSettingsDestination(for: "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)")
            == "generic/platform=tvOS Simulator")
        #expect(DestinationResolver.buildSettingsDestination(for: "platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)")
            == "generic/platform=watchOS Simulator")
        #expect(DestinationResolver.buildSettingsDestination(for: "platform=visionOS Simulator,name=Apple Vision Pro")
            == "generic/platform=visionOS Simulator")
    }

    /// The rewrite is keyed on the parsed `platform=` field, not on the
    /// destination string containing a platform name somewhere: a physical
    /// `platform=iOS` device is not a simulator and is not silently turned
    /// into one, and a specifier that never named a device is already what
    /// this function would produce.
    @Test("Anything without a simulator device to drop is returned unchanged")
    func nonSimulatorDestinationsPassThrough() {
        for destination in [
            "platform=macOS",
            "platform=macOS,arch=arm64",
            "platform=iOS,id=00008120-000A1C2E3D4F001E",
            "generic/platform=iOS",
            "generic/platform=iOS Simulator"
        ] {
            #expect(DestinationResolver.buildSettingsDestination(for: destination) == destination)
        }
    }

    /// The whole point of the rewrite: whatever a run resolved its
    /// destination to, the settings query derived from it never names a
    /// device — so no device disappearing between build and receipt can make
    /// the receipt unreadable.
    @Test("A resolved destination's settings query never carries an id=")
    func aResolvedDestinationNeverYieldsADevicePin() throws {
        let device = SimctlFixtures.device(
            "iPhone 17 Pro", udid: "75EF742A-E1F8-4BB4-A0A9-2BB0EDA1D68F",
            identifier: SimctlFixtures.prefix + "iOS-26-0", version: "26.0"
        )
        let resolved = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone 17 Pro", against: [device])

        #expect(resolved.destinationArgument.contains("id="), "the run itself must still address the one resolved device")
        #expect(!DestinationResolver.buildSettingsDestination(for: resolved.destinationArgument).contains("id="))
    }
}
