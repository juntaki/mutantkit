import Foundation
import MutationModel
import Testing

/// Split out of `CLICommandsAcceptanceTests` (v0.5 Stable Contracts) purely
/// to keep that suite under its own type-body-length limit — not a
/// difference in what is being pinned, and this test needs none of that
/// suite's shared fixture (it stages its own, deliberately-misconfigured
/// project).
@Suite("Acceptance: plan zero-discovery warning", .enabled(if: Acceptance.isEnabled))
struct PlanZeroDiscoveryAcceptanceTests {
    /// A real-project discovery pass found that `plan` against a
    /// `sources.include` glob matching zero real files exits 0 with a
    /// plausible-looking "discovered: 0" summary and no indication
    /// anything is wrong — a config whose source layout doesn't match the
    /// `setup`-generated SwiftPM-shaped default silently produces an
    /// empty, useless plan. Pins that a warning is now surfaced.
    @Test("plan against a non-matching sources.include warns about zero discovered mutations")
    func planWithNonMatchingSourcesWarnsOnZeroDiscovery() throws {
        let staged = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: staged) }

        let badConfiguration = """
        version: 1
        project:
          kind: swiftPackageMacOS
        sources:
          include: [ThisDirectoryDoesNotExist/**]
        operators:
          profile: default
        """
        try Data(badConfiguration.utf8).write(to: staged.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let result = try Acceptance.run(["plan", "--output", "empty-plan.json"], in: staged)

        #expect(result.exitCode == 0, "an empty discovery is not itself an error")
        #expect(result.output.contains("discovered: 0"))
        #expect(result.output.contains("warning: zero mutations discovered"), "expected the new zero-discovery warning, got: \(result.output)")
    }
}
