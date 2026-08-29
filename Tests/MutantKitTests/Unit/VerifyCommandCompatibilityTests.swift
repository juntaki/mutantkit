@testable import CLI
import Foundation
import MutationModel
import Testing

/// A round-4 review gap: `VerifyCommand` could print a "✓ Compatibility ...
/// match" success line purely because two independently incomplete/failed
/// toolchain probes both collapsed onto the same "unknown" placeholder —
/// a compatibility claim built from evidence that was never actually
/// gathered. `VerifyCommand.compatibilityOutcome` is the fix: it reports
/// `.unproven`, never `.match`, whenever the current probe's evidence is
/// incomplete.
@Suite("VerifyCommand: never claims a compatibility match on unproven evidence")
struct VerifyCommandCompatibilityTests {
    private func describe(_ outcome: VerifyCommand.PlanCompatibilityOutcome) -> String {
        switch outcome {
        case .match: "match"
        case let .differences(issues): "differences(\(issues.count))"
        case .unproven: "unproven"
        }
    }

    @Test("A matching plan against a complete probe reports .match")
    func matchingPlanWithCompleteProbeReportsMatch() {
        let plan = makePlan(mutations: [])
        let probe = ToolchainProbeResult(fingerprint: makeToolchain(), identityEvidenceComplete: true)

        let outcome = VerifyCommand.compatibilityOutcome(plan: plan, configuration: Configuration(), toolchainProbe: probe)

        #expect(outcome == .match)
    }

    @Test("A genuinely different toolchain against a complete probe reports .differences, never .match")
    func differingToolchainWithCompleteProbeReportsDifferences() {
        let plan = makePlan(mutations: [])
        let differentFingerprint = ToolchainFingerprint(
            toolVersion: "9.9.9",
            toolCommitSHA: nil,
            swiftVersion: makeToolchain().swiftVersion,
            swiftSyntaxVersion: makeToolchain().swiftSyntaxVersion,
            xcodeVersion: nil
        )
        let probe = ToolchainProbeResult(fingerprint: differentFingerprint, identityEvidenceComplete: true)

        let outcome = VerifyCommand.compatibilityOutcome(plan: plan, configuration: Configuration(), toolchainProbe: probe)

        guard case .differences = outcome else {
            Issue.record("expected .differences, got \(describe(outcome))")
            return
        }
    }

    /// The exact regression: a plan and an incomplete current-run probe
    /// whose fingerprints are byte-identical (both "unknown"-shaped) must
    /// still never report `.match` — the identical bytes prove nothing was
    /// actually compared.
    @Test("An incomplete probe reports .unproven, never .match, even when the fingerprints are byte-identical")
    func incompleteProbeReportsUnprovenEvenOnIdenticalFingerprints() {
        let identicalFingerprint = makeToolchain()
        let plan = MutationPlan(
            planID: "plan-0001",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projectRoot: "/tmp/project",
            toolchain: identicalFingerprint,
            configurationHash: Configuration().configurationHash,
            sourceFileHashes: [:],
            mutations: [],
            skipped: [],
            operators: []
        )
        let probe = ToolchainProbeResult(fingerprint: identicalFingerprint, identityEvidenceComplete: false)

        let outcome = VerifyCommand.compatibilityOutcome(plan: plan, configuration: Configuration(), toolchainProbe: probe)

        #expect(outcome == .unproven)
    }

    @Test("An incomplete probe reports .unproven even when the plan's own toolchain genuinely differs")
    func incompleteProbeReportsUnprovenEvenOnADifferingPlan() {
        let plan = makePlan(mutations: [])
        let differentFingerprint = ToolchainFingerprint(
            toolVersion: "9.9.9",
            toolCommitSHA: nil,
            swiftVersion: makeToolchain().swiftVersion,
            swiftSyntaxVersion: makeToolchain().swiftSyntaxVersion,
            xcodeVersion: nil
        )
        let probe = ToolchainProbeResult(fingerprint: differentFingerprint, identityEvidenceComplete: false)

        let outcome = VerifyCommand.compatibilityOutcome(plan: plan, configuration: Configuration(), toolchainProbe: probe)

        #expect(outcome == .unproven)
    }
}
