@testable import AppleBuildAdapters
import Testing

@Suite("Diagnostics: -showdestinations parsing")
struct DiagnosticsParseDestinationsTests {
    private static let output = """
    Command line invocation:
        /usr/bin/xcodebuild -scheme App -showdestinations

    \tAvailable destinations for the "App" scheme:
    \t\t{ platform:iOS Simulator, id:11111111-AAAA, OS:18.0, name:iPhone 16 }
    \t\t{ platform:macOS, arch:arm64, variant:Designed for [iPad,iPhone], id:00008112-X, name:My Mac }

    \tIneligible destinations for the "App" scheme:
    \t\t{ platform:iOS, id:dvtdevice-placeholder, name:Any iOS Device }
    """

    @Test("Each destination line keeps its platform, OS and name, and drops the rest")
    func keepsPlatformOSAndName() {
        #expect(Diagnostics.parseDestinations(Self.output) == [
            "platform:iOS Simulator OS:18.0 name:iPhone 16",
            "platform:macOS name:My Mac",
            "platform:iOS name:Any iOS Device"
        ])
    }

    @Test("Lines that are not destinations are ignored")
    func ignoresOtherLines() {
        #expect(Diagnostics.parseDestinations("no destinations here\n{ id:only-an-id }").isEmpty)
    }
}
