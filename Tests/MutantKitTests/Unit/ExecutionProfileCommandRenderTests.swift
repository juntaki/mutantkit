@testable import CLI
import Foundation
import MutationModel
import Testing

/// Pure tests for `ExecutionProfileCommand.render` — the text the
/// `execution-profile` command prints — with no plan, no project, and no
/// toolchain involved.
@Suite("ExecutionProfileCommand.render")
struct ExecutionProfileCommandRenderTests {
    @Test("an empty plan (zero mutations) renders without a division-by-zero crash and without a fraction line")
    func emptyPlanRendersSafely() {
        let characteristics = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 0, totalMutationCount: 0, schemataEligibleOperatorIDs: [],
            sharedModuleCacheSupported: false, perTestCoverageAdapterCapable: false
        )
        let rendered = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: ExecutionSettings(), characteristics: characteristics
        )
        #expect(!rendered.contains("Schemata-eligible (operator-level):"))
        #expect(rendered.contains("would change nothing"))
    }

    @Test("a schemata-eligible project with profileCoverageSkip set reports [enable] for both features and lists every changed field")
    func fullyEligibleProjectReportsEveryChange() {
        let characteristics = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 6, totalMutationCount: 6,
            schemataEligibleOperatorIDs: ["swift.core.bool-literal-inversion"],
            sharedModuleCacheSupported: true, perTestCoverageAdapterCapable: true
        )
        var current = ExecutionSettings()
        current.profileCoverageSkip = true
        let rendered = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: current, characteristics: characteristics
        )
        #expect(rendered.contains("[enable] preferSchemataExecution"))
        #expect(rendered.contains("[enable] perTestCoverageSelection"))
        #expect(rendered.contains("execution.strategy: isolated → schemata"))
        #expect(rendered.contains("execution.selectCoveringTests: false → true"))
        #expect(rendered.contains("execution.measureCoverage: false → true"))
        #expect(rendered.contains("Schemata-eligible (operator-level): 6/6 (100%)"))
        // sharedModuleCache is never a `resolve()` change, regardless of
        // configuration — see `fieldChanges`'s own comment — so the
        // "Concretely... would change" block must list exactly the three
        // lines above and never a fourth `execution.sharedModuleCache: ... →
        // ...` line, even though this project's characteristics say it is
        // supported and (mentioned below, in a different, informational
        // sentence) the report does still name the setting by name.
        #expect(!rendered.contains("execution.sharedModuleCache: false → true"))
        #expect(rendered.contains("never enabled by optimized/experimental"))
    }

    @Test("perTestCoverageSelection reports [skip] and names the missing profileCoverageSkip opt-in, even on a fully-capable adapter")
    func perTestCoverageSelectionSkippedWithoutOptIn() {
        let characteristics = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 0, totalMutationCount: 4, schemataEligibleOperatorIDs: [],
            sharedModuleCacheSupported: false, perTestCoverageAdapterCapable: true
        )
        let rendered = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: ExecutionSettings(), characteristics: characteristics
        )
        #expect(rendered.contains("[skip]   perTestCoverageSelection"))
        #expect(rendered.contains("execution.profileCoverageSkip: true (not set)"))
        #expect(!rendered.contains("execution.selectCoveringTests:"))
    }

    @Test("a fully-ineligible project reports [skip] for every feature and no changes")
    func fullyIneligibleProjectReportsNoChanges() {
        let characteristics = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 0, totalMutationCount: 4, schemataEligibleOperatorIDs: [],
            sharedModuleCacheSupported: false, perTestCoverageAdapterCapable: false
        )
        let rendered = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: ExecutionSettings(), characteristics: characteristics
        )
        // "[skip]" is two characters shorter than "[enable]", so its own
        // fixed-width padding plus the format string's separating space
        // puts three spaces before the feature name here where the
        // `[enable]` case (above) shows only one — both align the feature
        // name to the same column, which is the point.
        #expect(rendered.contains("[skip]   preferSchemataExecution"))
        #expect(rendered.contains("[skip]   perTestCoverageSelection"))
        #expect(rendered.contains("Switching to `execution.profile: optimized` would change nothing"))
    }

    @Test("an already-optimized config with everything eligible and profileCoverageSkip set reports nothing left to change")
    func alreadyOptimizedReportsNothingLeftToChange() {
        let characteristics = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 2, totalMutationCount: 2, schemataEligibleOperatorIDs: ["x"],
            sharedModuleCacheSupported: true, perTestCoverageAdapterCapable: true
        )
        var current = ExecutionSettings(profile: .optimized)
        current.strategy = .schemata
        current.selectCoveringTests = true
        current.measureCoverage = true
        current.profileCoverageSkip = true

        let rendered = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .optimized, currentExecution: current, characteristics: characteristics
        )
        #expect(rendered.contains("Already resolved: nothing about the currently-configured execution settings would change."))
    }

    @Test("shared module cache support is reported informationally, with the CI multi-destination risk named")
    func sharedModuleCacheReportedInformationally() {
        let supported = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 0, totalMutationCount: 0, schemataEligibleOperatorIDs: [],
            sharedModuleCacheSupported: true, perTestCoverageAdapterCapable: false
        )
        let renderedSupported = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: ExecutionSettings(), characteristics: supported
        )
        #expect(renderedSupported.contains("this project's build shape supports it"))
        #expect(renderedSupported.contains("concurrent destinations"))

        let unsupported = ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: 0, totalMutationCount: 0, schemataEligibleOperatorIDs: [],
            sharedModuleCacheSupported: false, perTestCoverageAdapterCapable: false
        )
        let renderedUnsupported = ExecutionProfileCommand.render(
            projectRoot: URL(fileURLWithPath: "/tmp/does-not-matter"), planPath: "plan.json",
            configuredProfile: .reference, currentExecution: ExecutionSettings(), characteristics: unsupported
        )
        #expect(renderedUnsupported.contains("not supported here"))
    }
}
