import MutationModel

/// Checks a loaded plan's recorded toolchain and configuration identity
/// against the current run's, so a plan produced by a different tool
/// version, SwiftSyntax version, or configuration is reported rather than
/// silently executed as if nothing had changed.
///
/// The configuration comparison is against `planningHash`, not
/// `configurationHash`: the question here is "would re-planning produce a
/// different plan", and only the settings planning actually reads can change
/// that answer. Comparing the whole configuration — which this did until
/// `Configuration.planningHash` existed — reported a mismatch for any
/// execution-only edit made between `plan` and `run`, including turning on
/// `execution.selectCoveringTests`, raising `workers`, or adding a report
/// format. Confirmed in the field as a false positive that reads like a
/// trust problem and has no action attached to it.
///
/// Still a warning rather than an error, and `verify`'s anchor check remains
/// the authoritative test of whether a plan still applies to the source:
/// this compares settings, and settings are not the only thing that can move
/// under a plan.
enum PlanCompatibilityValidator {
    static func check(
        _ plan: MutationPlan,
        against configuration: Configuration,
        toolchain: ToolchainFingerprint
    ) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        if plan.toolchain.toolVersion != toolchain.toolVersion {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "plan.toolchain.toolVersion",
                message: """
                Plan was produced by MutantKit \(plan.toolchain.toolVersion); this run is \
                \(toolchain.toolVersion). Re-plan if the two versions' discovery or plan schema differ.
                """
            ))
        }

        if plan.toolchain.swiftSyntaxVersion != toolchain.swiftSyntaxVersion {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "plan.toolchain.swiftSyntaxVersion",
                message: """
                Plan was discovered with SwiftSyntax \(plan.toolchain.swiftSyntaxVersion); this run \
                resolves \(toolchain.swiftSyntaxVersion). A SwiftSyntax version change can shift byte \
                anchors — run `mutantkit verify` to check the plan's anchors still match the source.
                """
            ))
        }

        if plan.planningHash != configuration.planningHash {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "plan.planningHash",
                message: """
                A setting that decides what gets planned — source scope, operators, budget, or diff \
                base — has changed since this plan was produced, so re-planning now would not produce \
                this plan. Run `mutantkit verify` to check the plan's anchors still match the source, \
                and re-plan to pick up the new scope. (Execution-only settings are deliberately not \
                compared here: changing workers, report format or test selection does not change what \
                was planned.)
                """
            ))
        }

        return issues
    }
}
