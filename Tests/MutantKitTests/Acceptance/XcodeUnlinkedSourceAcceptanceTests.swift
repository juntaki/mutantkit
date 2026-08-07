import Foundation
import MutationModel
import Testing

/// A source file `sources.include` discovers but no Xcode target ever
/// compiles — the True Negative for activation evidence, driven by a real
/// `xcodebuild` rather than a fabricated `ActivationEvidence`.
///
/// `IntegrityCheckerTests.inactiveMutationIsFlagged` already proves the
/// classifier reacts correctly to `.buildProductIdenticalToBaseline`, but it
/// hand-constructs that evidence — it never proves a *real* build actually
/// produces it for a mutation that never reached the compiler. This suite
/// closes that gap: `Sources/Unlinked/Unused.swift` sits outside every
/// target's Compile Sources phase (see the fixture's `project.yml`), so
/// mutating it changes the source tree, the build succeeds, every test still
/// passes — and the two mutants on it still must never be credited as a kill.
///
/// ADR-0006 Stage 1 moved this check upstream, into
/// `MutationVerdictVerifier.classify`'s own `unprovenActivation` gate: an
/// unproven-activation result is classified `.infrastructureFailure` (and
/// excluded from the score, never scored as a survivor) the moment the
/// verdict is produced, rather than reaching `IntegrityChecker.check` as an
/// ordinary scorable result for a separate pass to flag after the fact as
/// `.mutationNotActivated`. `IntegrityReport.violations` reports a *broken
/// invariant* in the run's own bookkeeping (a result that vanished, a count
/// that does not reconcile) — a correctly-excluded infrastructure failure is
/// not one of those, so `integrity.passed` and `run.exitCode` are expected to
/// stay green here; what this suite actually proves is that the exclusion
/// happened, by name, for both mutants on `Unused.swift`.
@Suite("Acceptance: source excluded from every built target", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeUnlinkedSourceAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: UnlinkedSource
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [UnlinkedSourceTests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 2
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeUnlinkedSource", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    /// The baseline itself has nothing to say about the unlinked file — it
    /// only distinguishes reachable mutants from unreachable ones once
    /// mutated. This just confirms the fixture's linked half is healthy.
    @Test("The baseline passes and both files are discovered")
    func baselineIsHealthy() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)
        #expect(run.report.integrity.discovered == 4)
        #expect(run.report.integrity.planned == 4)
    }

    /// The whole point of the fixture: a mutation with nowhere to go must
    /// never be credited as a kill, by name, rather than being silently
    /// scored as an ordinary survivor — see the suite's own doc comment for
    /// why this is `.infrastructureFailure`/excluded rather than an
    /// `IntegrityReport` violation under the current (ADR-0006 Stage 1)
    /// architecture.
    @Test("A mutation outside every target's Compile Sources is excluded, never credited as a kill")
    func unlinkedMutationIsExcludedFromTheScore() throws {
        let run = try self.run()

        #expect(run.report.integrity.passed, "\(run.report.integrity.violations.map(\.detail))")
        #expect(run.exitCode == 0)

        let unlinked = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "isOverLimit(count:)"
        }
        #expect(unlinked.count == 2)
        for result in unlinked {
            #expect(result.outcome == .infrastructureFailure, "\(result.point.displayLocation): \(result.outcome)")
            #expect(
                result.diagnosis.contains("build product is identical to the baseline's"),
                "\(result.point.displayLocation): \(result.diagnosis)"
            )
        }

        let score = try #require(run.report.score)
        #expect(score.excluded["infrastructureFailure"] == 2)
    }

    /// The linked file's mutants are a control group: if activation evidence
    /// stopped working entirely, they would fail closed too, and this
    /// assertion is what would catch that rather than the whole suite just
    /// looking like it is testing the right thing.
    @Test("The linked file's mutants are still proven active")
    func linkedMutationsAreUnaffected() throws {
        let run = try self.run()

        let linked = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "isInStock(count:)"
        }
        #expect(linked.count == 2)
        for result in linked {
            let activation = try #require(result.evidence?.applicationEvidence?.isolatedActivation)
            #expect(activation.provesActivation, "\(result.point.displayLocation)")
        }
    }
}
