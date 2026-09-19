@testable import CLI
import MutationModel
import Testing

/// `PlanCompatibilityValidator` reports a plan whose recorded toolchain or
/// configuration identity no longer matches the current run's, rather than
/// silently executing it as if nothing had changed. Deliberately warnings,
/// not errors: settings are not the only thing that can move under a plan, so
/// a match here is not proof the plan still applies — `verify`'s anchor check
/// is the authoritative test of that.
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

    /// The false positive this check was found to produce in the field:
    /// adding `execution.selectCoveringTests: true` to `mutantkit.yml`
    /// between `plan` and `run` warned that the plan no longer matched the
    /// configuration. It changes which tests each mutant runs against and
    /// nothing about which mutants exist, so there is nothing to report.
    @Test("An execution-only change is not a plan mismatch")
    func executionOnlyChangeIsClean() {
        let plan = makePlan(mutations: []) // built from the default `Configuration()`

        for change: (String, (inout Configuration) -> Void) in [
            ("selectCoveringTests", { $0.execution.selectCoveringTests = true }),
            ("workers", { $0.execution.workers = 4 }),
            ("strategy", { $0.execution.strategy = .schemata }),
            ("reports", { $0.reports = [.console] }),
            ("timeouts", { $0.timeouts.baselineSeconds = 1234 })
        ] {
            var configuration = Configuration()
            change.1(&configuration)

            let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: makeToolchain())

            #expect(issues.isEmpty, "changing \(change.0) does not change what was planned")
        }
    }

    /// The other half, and the reason the check exists at all: a setting
    /// planning really does read must still be reported, or a plan executed
    /// under a scope it was never built for passes unremarked.
    @Test("A planning-affecting change is reported as a warning, not an error")
    func planningAffectingChangeIsReported() {
        let plan = makePlan(mutations: []) // built from the default `Configuration()`

        for change: (String, (inout Configuration) -> Void) in [
            ("sources", { $0.sources.include = ["Sources/Only/**"] }),
            ("operators", { $0.operators.profile = .experimental }),
            ("budget", { $0.execution.budget = BudgetSettings(maxMutants: 25, seed: 7) }),
            ("diffBase", { $0.execution.diffBase = "origin/main" })
        ] {
            var configuration = Configuration()
            change.1(&configuration)

            let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: makeToolchain())

            let hashIssue = issues.first { $0.path == "plan.planningHash" }
            #expect(hashIssue?.severity == .warning, "changing \(change.0) changes what would be planned")
        }
    }
}
