import AppleBuildAdapters
import Testing

/// Every destination-string shape `SchemataRuntimePlatform.resolve(destination:)`
/// must classify correctly, including the two that are easiest to get
/// wrong and were both caught by adversarial review before this shipped:
/// `platform=macOS,variant=Mac Catalyst` must NOT resolve to `.macOS` (a
/// Catalyst binary is `-macabi`, not plain macOS — same class of linker
/// mismatch, different words), and `generic/platform=macOS` must NOT
/// silently regress to `nil` the way a naive `platform=` key lookup does
/// (an earlier draft handled `generic/platform=iOS Simulator` via a
/// whole-string substring test but left generic macOS unhandled).
@Suite("SchemataRuntimePlatform.resolve(destination:)")
struct SchemataRuntimePlatformTests {
    @Test(
        "Destination string shapes resolve to the expected platform",
        arguments: [
            ("platform=macOS", SchemataRuntimePlatform.macOS),
            ("platform=macOS,arch=arm64", .macOS),
            ("generic/platform=macOS", .macOS), // regression case: the generic macOS gap
            ("platform=iOS Simulator,name=iPhone 16", .iOSSimulator),
            ("platform=iOS Simulator,id=8B23C9A1-0000-4000-8000-000000000000", .iOSSimulator),
            ("generic/platform=iOS Simulator", .iOSSimulator)
        ] as [(String, SchemataRuntimePlatform)]
    )
    func resolvesSupportedDestinations(destination: String, expected: SchemataRuntimePlatform) {
        #expect(SchemataRuntimePlatform.resolve(destination: destination) == expected)
    }

    @Test(
        "Destination string shapes with no MutantKitSchemataRuntime archive resolve to nil, never a guess",
        arguments: [
            "platform=macOS,variant=Mac Catalyst", // Catalyst is -macabi, not interchangeable with plain macOS
            "platform=iOS,id=8B23C9A1-0000-4000-8000-000000000000", // real device
            "generic/platform=iOS", // real-device build-only placeholder
            "platform=tvOS Simulator,name=Apple TV",
            "platform=watchOS Simulator,name=Apple Watch",
            "generic/platform=visionOS Simulator",
            "not a destination at all"
        ]
    )
    func resolvesUnsupportedDestinationsToNil(destination: String) {
        #expect(SchemataRuntimePlatform.resolve(destination: destination) == nil)
    }
}
