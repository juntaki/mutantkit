@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// P8 (CI Safe-Skip Policy): relocated from `XcodeConfigDetectorTests.swift`
/// (a unit suite). These two tests make a real `xcrun simctl` call through
/// `XcodeConfigDetector`'s own real destination discovery — that makes them
/// integration/acceptance tests, not deterministic unit tests, and they do
/// not belong in a suite CI runs unconditionally with no simulator
/// dependency declared. `Acceptance.simulatorEnabled` gates them exactly
/// the way every other real-Xcode/simulator suite in this directory is
/// gated, and the CI matrix entry that runs this suite explicitly declares
/// `simulator: "1"` (see `ci.yml`'s `xcode-config-detector` fixture).
///
/// `selectDestination(from:)`'s pure selection logic and the XML-parsing
/// tests stayed in the unit suite — they take a hand-built device list or
/// hand-written XML and never touch a real tool, so they belong exactly
/// where deterministic, always-run unit coverage lives.
@Suite("Acceptance: Xcode config real destination detection", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeConfigDetectorAcceptanceTests {
    @Test("detectDestination finds a real, currently-available iPhone simulator on this machine", .subprocessExclusive)
    func detectsRealDestination() async throws {
        let destination = await XcodeConfigDetector.detectDestination(projectRoot: Acceptance.packageRoot)
        let resolved = try #require(destination, "expected at least one real iOS Simulator on this machine")
        #expect(resolved.hasPrefix("platform=iOS Simulator,name=iPhone"))
    }

    /// Regression test for a real bug caught by manual end-to-end testing,
    /// not by the unit tests alone: `detect()`'s first version computed the
    /// destination only *after* confirming exactly one scheme existed, so
    /// an ambiguous-scheme project (the common case for anything beyond a
    /// single-target toy -- `Fixtures/XcodeProject` itself has 4 real
    /// schemes) silently lost the destination suggestion too, even though a
    /// destination has nothing to do with scheme resolution.
    /// `Fixtures/XcodeProject` is exactly this real, ambiguous case --
    /// confirmed still ambiguous below to make sure this test is actually
    /// exercising the multi-scheme path, not one that happens to have
    /// shrunk to one scheme since this was written.
    @Test("A real destination is still detected even when the scheme is ambiguous", .subprocessExclusive)
    func destinationIsDetectedIndependentlyOfSchemeAmbiguity() async {
        let projectFile = Acceptance.packageRoot.appendingPathComponent("Fixtures/XcodeProject/Checkout.xcodeproj")
        let detection = await XcodeConfigDetector.detect(
            kind: .xcodeProject, projectFile: projectFile, projectRoot: projectFile.deletingLastPathComponent()
        )

        #expect(detection.scheme == nil)
        #expect(detection.schemeCandidates.count > 1, "expected this fixture to still have more than one scheme")
        #expect(detection.testTargets.isEmpty, "test targets genuinely cannot be resolved without knowing which scheme")
        #expect(
            detection.destination?.hasPrefix("platform=iOS Simulator,name=") == true,
            "a destination must still be found despite the scheme ambiguity"
        )
        #expect(
            !detection.destinationDiscoveryFailed,
            "a real, available simulator was found -- this must not also report a discovery failure"
        )
    }
}
