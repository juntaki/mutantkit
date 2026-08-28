@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// Phase C13 (competitive-parity program): `mutantkit init`'s Xcode/
/// workspace auto-detection used to leave `tests.targets: []`, `scheme:
/// nil`, and a hardcoded `iPhone 16` destination for every non-SwiftPM
/// project -- the exact gap the C0-C12 closeout review correctly rejected
/// as "not Xcode-competitive."
///
/// This suite is deterministic unit coverage only: `.xcscheme` XML
/// parsing against real, committed fixture data; `selectDestination(from:)`'s
/// pure selection logic against hand-built device lists; and
/// `detectDestinationOutcome`'s `.detected`/`.unavailable`/`.discoveryFailed`
/// classification against an injected fake device provider -- never a real
/// `simctl` call. Real, machine-dependent destination discovery (an actual
/// `simctl` call finding an actual simulator) is an integration concern and
/// lives in `XcodeConfigDetectorAcceptanceTests.swift` instead, gated on
/// `Acceptance.simulatorEnabled` with its own explicit CI matrix entry.
@Suite("Xcode config auto-detection (Phase C13)")
struct XcodeConfigDetectorTests {
    // MARK: - Test-target extraction from a real .xcscheme

    /// The real, committed `Checkout.xcscheme` -- read directly, not
    /// reconstructed by hand, so a real Xcode-authored document (with
    /// every attribute and ordering quirk Xcode itself writes) is what
    /// this parser is actually tested against.
    private static var checkoutSchemeURL: URL {
        Acceptance.packageRoot
            .appendingPathComponent("Fixtures/XcodeProject/Checkout.xcodeproj/xcshareddata/xcschemes/Checkout.xcscheme")
    }

    @Test("parseTestableBlueprintNames finds CheckoutTests in the real Checkout.xcscheme")
    func parsesRealSchemeFile() throws {
        let data = try Data(contentsOf: Self.checkoutSchemeURL)
        let names = XcodeConfigDetector.parseTestableBlueprintNames(from: data)
        #expect(names == ["CheckoutTests"])
    }

    @Test("parseTestableBlueprintNames finds every Testable when a scheme tests more than one target")
    func parsesMultipleTestables() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
           <TestAction>
              <Testables>
                 <TestableReference skipped = "NO">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "AAA"
                       BuildableName = "UnitTests.xctest"
                       BlueprintName = "UnitTests"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
                 <TestableReference skipped = "NO">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "BBB"
                       BuildableName = "UITests.xctest"
                       BlueprintName = "UITests"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
        </Scheme>
        """
        let names = XcodeConfigDetector.parseTestableBlueprintNames(from: Data(xml.utf8))
        #expect(names == ["UnitTests", "UITests"])
    }

    /// A `BuildableReference` inside `<BuildAction>` (the app/framework
    /// target itself, or a target this scheme merely builds) must never be
    /// mistaken for a *test* target -- only `BuildableReference`s that are
    /// actually nested inside `<Testables>` count.
    @Test("A BuildableReference outside <Testables> is never mistaken for a test target")
    func ignoresNonTestableBuildableReferences() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
           <BuildAction>
              <BuildActionEntries>
                 <BuildActionEntry>
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "CCC"
                       BuildableName = "App.app"
                       BlueprintName = "App"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction>
              <Testables>
                 <TestableReference skipped = "NO">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "AAA"
                       BuildableName = "UnitTests.xctest"
                       BlueprintName = "UnitTests"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
        </Scheme>
        """
        let names = XcodeConfigDetector.parseTestableBlueprintNames(from: Data(xml.utf8))
        #expect(names == ["UnitTests"])
    }

    @Test("A scheme with no <Testables> at all yields no test targets")
    func noTestablesYieldsEmpty() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
           <BuildAction>
           </BuildAction>
        </Scheme>
        """
        #expect(XcodeConfigDetector.parseTestableBlueprintNames(from: Data(xml.utf8)).isEmpty)
    }

    @Test("Malformed XML yields no test targets rather than crashing")
    func malformedXMLYieldsEmpty() {
        #expect(XcodeConfigDetector.parseTestableBlueprintNames(from: Data("not xml at all".utf8)).isEmpty)
    }

    /// Regression test for a real bug caught by Codex review before this
    /// was committed as done: a `<TestableReference skipped = "YES">` is a
    /// real, common Xcode scheme state (a disabled UI/integration test
    /// bundle within an otherwise-enabled scheme) — `xcodebuild` would
    /// never actually run it, so it must never be suggested into
    /// `tests.targets`.
    @Test("A skipped TestableReference is never suggested as a test target")
    func skippedTestableIsExcluded() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
           <TestAction>
              <Testables>
                 <TestableReference skipped = "NO">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "AAA"
                       BuildableName = "UnitTests.xctest"
                       BlueprintName = "UnitTests"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
                 <TestableReference skipped = "YES">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "BBB"
                       BuildableName = "UITests.xctest"
                       BlueprintName = "UITests"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
        </Scheme>
        """
        let names = XcodeConfigDetector.parseTestableBlueprintNames(from: Data(xml.utf8))
        #expect(names == ["UnitTests"])
    }

    // MARK: - testTargets(forScheme:projectRoot:) -- finds the file itself

    @Test("testTargets(forScheme:) locates the real .xcscheme by name under the project root")
    func findsRealSchemeFileByName() async {
        let projectRoot = Acceptance.packageRoot.appendingPathComponent("Fixtures/XcodeProject")
        let names = await XcodeConfigDetector.testTargets(forScheme: "Checkout", projectRoot: projectRoot)
        #expect(names == ["CheckoutTests"])
    }

    @Test("testTargets(forScheme:) returns empty for a scheme name with no matching file")
    func unknownSchemeNameYieldsEmpty() async {
        let projectRoot = Acceptance.packageRoot.appendingPathComponent("Fixtures/XcodeProject")
        let names = await XcodeConfigDetector.testTargets(forScheme: "NoSuchScheme", projectRoot: projectRoot)
        #expect(names.isEmpty)
    }

    // MARK: - Destination detection, against a real simctl device list

    //
    // Real, machine-dependent detectDestination()/detect() acceptance
    // coverage (a real simctl call, a real ambiguous-scheme project) lives
    // in XcodeConfigDetectorAcceptanceTests.swift, gated behind
    // Acceptance.simulatorEnabled — see that file's own header comment for
    // why (P8, CI Safe-Skip Policy: these are integration tests, not
    // deterministic unit tests, and belong in a suite CI explicitly
    // declares a simulator dependency for).

    private static func device(_ name: String, runtime: String, state: String = "Shutdown") -> SimulatorDevice {
        SimulatorDevice(udid: UUID().uuidString, name: name, runtimeIdentifier: runtime, state: state)
    }

    /// Regression test for a real bug caught by Codex review before this
    /// was committed as done: comparing `runtimeIdentifier` as raw strings
    /// sorts `iOS-9-*` ahead of `iOS-26-*` (`"9" > "2"` lexicographically
    /// is false, i.e. `iOS-26` sorted as *older*) and `iOS-26-10` behind
    /// `iOS-26-9` — wrong once any version component reaches two digits.
    @Test("selectDestination compares iOS runtime versions numerically, not lexicographically")
    func selectsNumericallyLatestRuntime() {
        let devices = [
            Self.device("iPhone 15", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-9-0"),
            Self.device("iPhone 16", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-9"),
            Self.device("iPhone 17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-10")
        ]
        #expect(XcodeConfigDetector.selectDestination(from: devices) == "platform=iOS Simulator,name=iPhone 17")
    }

    /// Regression test for a real bug caught by Codex review before this
    /// was committed as done: falling back to *any* device (not just iOS
    /// ones) once no `iPhone`-named device existed, then unconditionally
    /// labeling the result `platform=iOS Simulator` — wrong for a machine
    /// with only tvOS/watchOS/visionOS runtimes installed.
    @Test("selectDestination never picks a non-iOS device, even as a fallback")
    func neverSelectsNonIOSDevice() {
        let devices = [
            Self.device("Apple TV 4K", runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-17-0"),
            Self.device("Apple Watch Series 9", runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-10-0")
        ]
        #expect(XcodeConfigDetector.selectDestination(from: devices) == nil)
    }

    @Test("selectDestination falls back to a non-iPhone iOS device when no iPhone is installed")
    func fallsBackToNonIPhoneIOSDevice() {
        let devices = [
            Self.device("iPad Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
            Self.device("Apple TV 4K", runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-17-0")
        ]
        #expect(XcodeConfigDetector.selectDestination(from: devices) == "platform=iOS Simulator,name=iPad Pro")
    }

    @Test("selectDestination returns nil for an empty device list")
    func selectDestinationEmptyListYieldsNil() {
        #expect(XcodeConfigDetector.selectDestination(from: []) == nil)
    }

    // MARK: - detect(kind:projectFile:projectRoot:) -- non-Xcode kinds are a no-op

    @Test("detect() is an immediate no-op for SwiftPM and unknown kinds, never touching xcodebuild or simctl")
    func nonXcodeKindsAreNoOp() async {
        for kind: ProjectKind in [.swiftPackageMacOS, .swiftPackageApple, .auto] {
            let detection = await XcodeConfigDetector.detect(kind: kind, projectFile: nil, projectRoot: Acceptance.packageRoot)
            #expect(detection.scheme == nil)
            #expect(detection.schemeCandidates.isEmpty)
            #expect(detection.testTargets.isEmpty)
            #expect(detection.destination == nil)
        }
    }

    @Test("detect() with an Xcode kind but no projectFile is a no-op")
    func xcodeKindWithNoProjectFileIsNoOp() async {
        let detection = await XcodeConfigDetector.detect(kind: .xcodeProject, projectFile: nil, projectRoot: Acceptance.packageRoot)
        #expect(detection.scheme == nil)
        #expect(detection.destination == nil)
    }

    // MARK: - detectDestinationOutcome, with an injected fake device provider

    //
    // Pure, deterministic unit coverage for the typed distinction itself —
    // no real simctl call. The real-machine acceptance coverage (a real
    // simctl call actually finding a real destination) lives in
    // XcodeConfigDetectorAcceptanceTests.swift.

    private struct FakeDevicesProvider: XcodeConfigDetector.AvailableDevicesProviding {
        let result: Result<[SimulatorDevice], Error>
        func availableDevices() async throws -> [SimulatorDevice] { try result.get() }
    }

    private struct FakeDiscoveryFailure: Error {}

    @Test("A known device list resolves to the correct .detected destination")
    func knownDeviceListResolvesToDetected() async {
        let devices = [Self.device("iPhone 16", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0")]
        let outcome = await XcodeConfigDetector.detectDestinationOutcome(
            projectRoot: Acceptance.packageRoot,
            poolFactory: { _ in FakeDevicesProvider(result: .success(devices)) }
        )
        #expect(outcome == .detected("platform=iOS Simulator,name=iPhone 16"))
    }

    @Test("No iOS device in a successfully-fetched list resolves to .unavailable, not .discoveryFailed")
    func noIOSDeviceResolvesToUnavailable() async {
        let devices = [Self.device("Apple TV 4K", runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-17-0")]
        let outcome = await XcodeConfigDetector.detectDestinationOutcome(
            projectRoot: Acceptance.packageRoot,
            poolFactory: { _ in FakeDevicesProvider(result: .success(devices)) }
        )
        #expect(outcome == .unavailable)
    }

    @Test("An empty device list resolves to .unavailable, not .discoveryFailed")
    func emptyDeviceListResolvesToUnavailable() async {
        let outcome = await XcodeConfigDetector.detectDestinationOutcome(
            projectRoot: Acceptance.packageRoot,
            poolFactory: { _ in FakeDevicesProvider(result: .success([])) }
        )
        #expect(outcome == .unavailable)
    }

    /// The regression this whole typed distinction exists for: a real CI
    /// run showed a `simctl` call that failed to complete (a cold
    /// CoreSimulator subsystem timing out) collapsing into the exact same
    /// `nil` as "no simulator installed" — this proves an injected
    /// discovery failure is reported as `.discoveryFailed`, distinguishably
    /// from `.unavailable`, never silently masquerading as "no simulator."
    @Test("An injected discovery failure resolves to .discoveryFailed, never .unavailable")
    func injectedFailureResolvesToDiscoveryFailed() async {
        let outcome = await XcodeConfigDetector.detectDestinationOutcome(
            projectRoot: Acceptance.packageRoot,
            poolFactory: { _ in FakeDevicesProvider(result: .failure(FakeDiscoveryFailure())) }
        )
        #expect(outcome == .discoveryFailed)
    }
}
