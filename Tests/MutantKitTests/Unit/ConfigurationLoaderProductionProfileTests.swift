@testable import CLI
import MutationModel
import Testing

/// Phase C13 (competitive-parity program): a real 4-way local benchmark
/// against a real, large production iOS app found `mutantkit init`'s own
/// generated template — the config a brand-new user actually runs with,
/// zero manual tuning — was the *slowest* of the four profiles measured
/// (no incrementalBuild/selectCoveringTests/simulatorPool at all, ~80.6s
/// per mutant), slower even than the most basic tuned profile (N=1,
/// ~56.2s/mutant), let alone the production-grade N=2 `simulatorPool`
/// profile the same real corpus already proved (2.17x speedup vs. that
/// tuned N=1 reference, 100/100 outcome parity with it, 0 integrity
/// violations — see `PROGRESS.md`'s C4 entry). This pins that decision at
/// the code level: `init`'s own template now ships the measured
/// production-grade profile for every kind that actually leases a real
/// Simulator, not the untuned defaults that measured worst.
@Suite("ConfigurationLoader: production profile (Phase C13)")
struct ConfigurationLoaderProductionProfileTests {
    @Test("A Simulator-backed kind's init template ships the measured production-grade profile")
    func simulatorBackedKindsShipTheMeasuredProfile() {
        for kind: ProjectKind in [.xcodeProject, .xcodeWorkspace, .swiftPackageApple] {
            let template = ConfigurationLoader.template(for: kind, scheme: nil, destination: nil, testTargets: [])
            #expect(template.contains("workers: 2"), "expected \(kind) to ship workers: 2, the measured production-grade count")
            #expect(template.contains("simulatorPool: true"), "expected \(kind) to enable simulatorPool")
            #expect(template.contains("incrementalBuild: true"), "expected \(kind) to enable incrementalBuild")
            #expect(template.contains("selectCoveringTests: true"), "expected \(kind) to enable selectCoveringTests")
            #expect(!template.contains("workers: auto"), "expected \(kind) not to fall back to the untuned auto default")
        }
    }

    /// `simulatorPool` provisions real device clones — meaningless, and
    /// never proven, for a host-only macOS run. Left untouched by this
    /// decision, matching the existing Gate 3 Phase H18 guard's own
    /// framing ("unchanged by this decision") for `swiftPackageMacOS`.
    @Test("A host-only SwiftPM (macOS) kind is unaffected by the Simulator-specific production profile")
    func hostOnlyKindKeepsItsOwnDefaults() {
        let template = ConfigurationLoader.template(for: .swiftPackageMacOS, scheme: nil, destination: nil, testTargets: [])
        #expect(template.contains("workers: auto"))
        #expect(!template.contains("simulatorPool: true"))
        #expect(!template.contains("workers: 2"))
    }

    @Test("An auto-detected (not yet resolved) kind keeps the untuned default, since the real kind is unknown at generation time")
    func autoKindKeepsUntunedDefault() {
        let template = ConfigurationLoader.template(for: .auto, scheme: nil, destination: nil, testTargets: [])
        #expect(template.contains("workers: auto"))
        #expect(!template.contains("simulatorPool: true"))
    }

    @Test("Every generated template still declares strategy: isolated explicitly, regardless of the production profile")
    func stillDeclaresIsolatedExplicitly() {
        for kind: ProjectKind in [.auto, .swiftPackageMacOS, .swiftPackageApple, .xcodeProject, .xcodeWorkspace] {
            let template = ConfigurationLoader.template(for: kind, scheme: nil, destination: nil, testTargets: [])
            #expect(template.contains("strategy: isolated"))
            #expect(!template.contains("strategy: schemata"))
        }
    }
}
