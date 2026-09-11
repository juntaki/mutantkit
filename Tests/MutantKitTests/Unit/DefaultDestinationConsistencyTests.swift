@testable import AppleBuildAdapters
import MutationModel
import Testing

/// Lane D external-proof discovery, root-caused 2026-09-11: a real Xcode
/// project (iOS-only, no `mutantkit.yml` yet) got two different last-resort
/// destination guesses from two different entry points. `doctor` run with
/// no config at all reached `AppleAdapterFactory.resolveDestinationIfNeeded`,
/// whose own literal only special-cased `.swiftPackageApple` — every other
/// kind, `.xcodeProject`/`.xcodeWorkspace` included, fell back to
/// `platform=macOS`, which then failed outright on a provisioning-profile
/// error for an app with no macOS signing story. `setup`, moments later on
/// the identical project, correctly picked a real iOS Simulator, because
/// `ProjectDetectionPlan.defaultDestination(for:)` already included
/// `.xcodeProject`/`.xcodeWorkspace` in its own iOS Simulator default.
///
/// `DestinationResolver.defaultDestination(for:)` is now the one function both
/// `destination()` and `AppleAdapterFactory.resolveDestinationIfNeeded` call
/// — this pins that it matches `ProjectDetectionPlan`'s own policy for every
/// kind, so the two entry points cannot drift apart again undetected.
@Suite("Default destination guess: consistent across doctor/run and setup/init")
struct DefaultDestinationConsistencyTests {
    @Test("Every Xcode-building kind's last-resort default matches ProjectDetectionPlan's own policy")
    func matchesProjectDetectionPlanPolicy() {
        for kind: ProjectKind in [.swiftPackageApple, .xcodeProject, .xcodeWorkspace] {
            #expect(
                DestinationResolver.defaultDestination(for: kind) == "platform=iOS Simulator,name=iPhone 16",
                "\(kind) should default to a real iOS Simulator destination, not platform=macOS"
            )
        }
    }

    @Test("swiftPackageMacOS still defaults to platform=macOS — this fix is additive, not a blanket iOS default")
    func swiftPackageMacOSUnaffected() {
        #expect(DestinationResolver.defaultDestination(for: .swiftPackageMacOS) == "platform=macOS")
    }
}
