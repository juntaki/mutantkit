@testable import CLI
import MutationModel
import Testing

/// A round-4 review gap: `PlanCommand` used to take only `.fingerprint` from
/// `ToolchainProbe`'s result and discard `identityEvidenceComplete`
/// entirely, so `plan.json`'s toolchain field could not be distinguished as
/// "provably unknown" from "the probe was incomplete/failed when this plan
/// was made." `PlanCommand.toolchainForPlanning(from:)` is the fix: it
/// refuses to hand back a fingerprint at all once the evidence behind it is
/// incomplete, so `run()`'s own `guard let` fails the command outright
/// rather than silently writing an under-evidenced plan.
@Suite("PlanCommand: refuses to plan from an under-evidenced toolchain probe")
struct PlanCommandToolchainEvidenceTests {
    @Test("A complete probe's fingerprint is handed back unchanged")
    func completeProbeYieldsItsFingerprint() {
        let fingerprint = makeToolchain()
        let probe = ToolchainProbeResult(fingerprint: fingerprint, identityEvidenceComplete: true)

        #expect(PlanCommand.toolchainForPlanning(from: probe) == fingerprint)
    }

    /// The exact regression: before this fix, `run()` read `.fingerprint`
    /// directly and never even looked at `identityEvidenceComplete`, so an
    /// incomplete probe's "unknown"-shaped fingerprint would have been
    /// written into plan.json without complaint.
    @Test("An incomplete probe yields no fingerprint at all, not merely an unusual one")
    func incompleteProbeYieldsNilNotAFingerprint() {
        let probe = ToolchainProbeResult(fingerprint: makeToolchain(), identityEvidenceComplete: false)

        #expect(PlanCommand.toolchainForPlanning(from: probe) == nil)
    }
}
