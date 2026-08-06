@testable import CLI
import MutationModel
import Testing

/// `PlanCompatibilityValidator` reports a plan whose recorded toolchain or
/// configuration identity no longer matches the current run's, rather than
/// silently executing it as if nothing had changed. Deliberately warnings,
/// not errors — `configurationHash` currently covers execution-only settings
/// too (see the type's own doc comment), so a mismatch is not proof the plan
/// itself is stale; `verify`'s anchor check is the authoritative test of that.
@Suite("Plan compatibility validation")
struct PlanCompatibilityValidatorTests {
    @Test("A plan whose recorded toolchain and configuration match is clean")
    func matchingPlanIsClean() {
        let configuration = Configuration()
        let toolchain = makeToolchain()
        let plan = makePlan(mutations: [])

        let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: toolchain)

        #expect(issues.isEmpty)
    }

    @Test("A tool version mismatch is reported as a warning")
    func toolVersionMismatchIsReported() {
        let configuration = Configuration()
        let plan = makePlan(mutations: [])
        let differentToolchain = ToolchainFingerprint(
            toolVersion: "9.9.9",
            toolCommitSHA: nil,
            swiftVersion: makeToolchain().swiftVersion,
            swiftSyntaxVersion: makeToolchain().swiftSyntaxVersion,
            xcodeVersion: nil
        )

        let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: differentToolchain)

        #expect(issues.contains { $0.path == "plan.toolchain.toolVersion" && $0.severity == .warning })
    }

    @Test("A SwiftSyntax version mismatch is reported as a warning")
    func swiftSyntaxVersionMismatchIsReported() {
        let configuration = Configuration()
        let plan = makePlan(mutations: [])
        let differentToolchain = ToolchainFingerprint(
            toolVersion: makeToolchain().toolVersion,
            toolCommitSHA: nil,
            swiftVersion: makeToolchain().swiftVersion,
            swiftSyntaxVersion: "999.0.0",
            xcodeVersion: nil
        )

        let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: differentToolchain)

        #expect(issues.contains { $0.path == "plan.toolchain.swiftSyntaxVersion" && $0.severity == .warning })
    }

    @Test("A configuration hash mismatch is reported as a warning, not an error")
    func configurationHashMismatchIsReported() {
        var configuration = Configuration()
        configuration.execution.workers = 4
        let plan = makePlan(mutations: []) // built from the default `Configuration()`'s hash

        let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: makeToolchain())

        let hashIssue = issues.first { $0.path == "plan.configurationHash" }
        #expect(hashIssue?.severity == .warning)
    }
}
