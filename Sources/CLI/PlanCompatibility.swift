import Foundation
import MutationModel

/// Checks a loaded plan's recorded toolchain and configuration identity
/// against the current run's, so a plan produced by a different tool
/// version, SwiftSyntax version, or configuration is reported rather than
/// silently executed as if nothing had changed.
///
/// Deliberately conservative: `configurationHash` today covers the whole
/// resolved configuration, including execution-only settings (worker count,
/// report format) that do not affect what was planned. A mismatch is
/// reported as a warning, not an error, until the hash is split into a
/// planning-affecting component and an execution-only one — `verify`'s
/// anchor check remains the authoritative test of whether a plan still
/// applies to the source.
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

        if plan.configurationHash != configuration.configurationHash {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "plan.configurationHash",
                message: """
                This run's configuration hash does not match the one recorded in the plan. This may be \
                an execution-only setting (workers, report format) that does not affect what was \
                planned, or a planning-affecting change (operators, source scope) that does — run \
                `mutantkit verify` to check the plan's anchors still match, and re-plan if they do not.
                """
            ))
        }

        return issues
    }
}
