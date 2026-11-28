@testable import AppleBuildAdapters
import Testing

/// Destination resolution picks only among devices the scheme's
/// `-showdestinations` lists, and fails explicitly when there are none.
@Suite("Scheme-compatible simulator selection")
struct SchemeDestinationsTests {
    private static let p = SimctlFixtures.prefix
    private static let generic = p + "iOS-27-2"
    private static let specific = p + "iOS-27-2-iPhone19-4"

    private static let output = """
    Command line invocation:
        xcodebuild -showdestinations -scheme App

    Available destinations for the "App" scheme:
        { platform:iOS Simulator, arch:arm64, id:U-SPECIFIC, OS:27.2, name:iPhone 17 }
        { platform:iOS Simulator, id:dvtdevice-placeholder:placeholder, name:Any iOS Simulator Device }

    Ineligible destinations for the "App" scheme:
        { platform:iOS Simulator, id:U-OLD, OS:15.0, name:iPhone 8, error:iOS 15.0 is not supported }
    """

    @Test("Only the Available section's device ids are read")
    func parsesAvailableOnly() throws {
        let parsed = try #require(SchemeDestinations.parse(scheme: "App", output: Self.output))
        #expect(parsed.supports(udid: "u-specific"))
        #expect(!parsed.supports(udid: "U-OLD"))
        #expect(!parsed.supports(udid: "U-GENERIC"))
    }

    @Test("Same name under two same-version runtimes: the scheme's device wins over the identifier tiebreak")
    func schemeBeatsTiebreak() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.specific, "27.2", "iOS"), .init(Self.generic, "27.2", "iOS")],
            devices: [Self.specific: [("U-SPECIFIC", "iPhone 17")], Self.generic: [("U-GENERIC", "iPhone 17")]]
        )
        let scheme = try #require(SchemeDestinations.parse(scheme: "App", output: Self.output))
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 17", against: catalog.devices, schemeDestinations: scheme
        )
        #expect(resolved.device?.udid == "U-SPECIFIC")
        // Without the scheme's list the old deterministic tiebreak still applies.
        let unchecked = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone 17", against: catalog.devices)
        #expect(unchecked.device?.udid == "U-GENERIC")
    }

    @Test("The newest runtime is chosen among scheme-supported devices")
    func newestAmongSupported() throws {
        let newer = Self.p + "iOS-28-0"
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.generic, "27.2", "iOS"), .init(newer, "28.0", "iOS")],
            devices: [Self.generic: [("U-27", "iPhone 17")], newer: [("U-28", "iPhone 17")]]
        )
        let scheme = SchemeDestinations(scheme: "App", identifiers: ["U-27"])
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 17", against: catalog.devices, schemeDestinations: scheme
        )
        #expect(resolved.device?.udid == "U-27")
    }

    @Test("No scheme-supported device for the name is an explicit failure, never an incompatible pick")
    func incompatibleFailsExplicitly() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.generic, "27.2", "iOS")],
            devices: [Self.generic: [("U-GENERIC", "iPhone 17")]]
        )
        let scheme = SchemeDestinations(scheme: "App", identifiers: ["U-OTHER"])
        for requested in ["platform=iOS Simulator,name=iPhone 17", "platform=iOS Simulator,name=iPhone 17,OS=27.2",
                          "platform=iOS Simulator,id=U-GENERIC"] {
            expectNotSupported(requested, catalog.devices, scheme)
        }
    }

    @Test("OS= on an unsupported runtime and a newest runtime the name is unsupported on both say 'not supported by the scheme'")
    func mixedVersionsReportScheme() throws {
        let newer = Self.p + "iOS-28-0"
        let runtimes: [SimctlFixtures.Runtime] = [.init(Self.generic, "27.2", "iOS"), .init(newer, "28.0", "iOS")]
        // OS=27.2 names a device the scheme refuses, though 28.0's iPhone 17 is supported.
        let osCase = try SimctlFixtures.catalog(
            runtimes: runtimes, devices: [Self.generic: [("U-27", "iPhone 17")], newer: [("U-28", "iPhone 17")]]
        )
        expectNotSupported(
            "platform=iOS Simulator,name=iPhone 17,OS=27.2", osCase.devices,
            SchemeDestinations(scheme: "App", identifiers: ["U-28"]), expectNoneSupported: false
        )
        // Unconstrained, iPhone 17 would resolve to 28.0's (refused) device; the newest
        // supported runtime is 28.0 too (iPhone 19), so only 27.2's iPhone 17 is usable.
        let latestCase = try SimctlFixtures.catalog(
            runtimes: runtimes,
            devices: [Self.generic: [("U-27", "iPhone 17")], newer: [("U-28", "iPhone 17"), ("U-28-B", "iPhone 19")]]
        )
        expectNotSupported(
            "platform=iOS Simulator,name=iPhone 17", latestCase.devices,
            SchemeDestinations(scheme: "App", identifiers: ["U-27", "U-28-B"]), expectNoneSupported: false
        )
        // No usable iPhone 17 at all, and the newest supported runtime lacks the name.
        let noneCase = try SimctlFixtures.catalog(
            runtimes: runtimes, devices: [Self.generic: [("U-27", "iPhone 17")], newer: [("U-28-B", "iPhone 19")]]
        )
        expectNotSupported(
            "platform=iOS Simulator,name=iPhone 17", noneCase.devices, SchemeDestinations(scheme: "App", identifiers: ["U-28-B"])
        )
    }

    @Test("Output without an Available destinations section is unknown, not empty")
    func unrecognisedOutputIsUnknown() {
        #expect(SchemeDestinations.parse(scheme: "App", output: "something else entirely") == nil)
        #expect(SchemeDestinations.parse(scheme: "App", output: "Available destinations for the \"App\" scheme:\n") != nil)
    }

    private func expectNotSupported(
        _ requested: String, _ devices: [CatalogDevice], _ scheme: SchemeDestinations, expectNoneSupported: Bool = true
    ) {
        do {
            _ = try DestinationResolver.resolve(requested, against: devices, schemeDestinations: scheme)
            Issue.record("\(requested) resolved to an incompatible device")
        } catch let DestinationResolutionError.notSupportedByScheme(name, _, supported, unsupported) {
            #expect(name == "App")
            #expect(!unsupported.isEmpty)
            #expect(supported.isEmpty == expectNoneSupported, "\(requested): supported=\(supported)")
        } catch {
            Issue.record("\(requested): expected notSupportedByScheme, got \(error)")
        }
    }

    @Test("A non-simulator destination is not checked against the scheme")
    func macOSUnaffected() throws {
        let scheme = SchemeDestinations(scheme: "App", identifiers: [])
        let resolved = try DestinationResolver.resolve("platform=macOS", against: [], schemeDestinations: scheme)
        #expect(resolved.device == nil)
    }
}
