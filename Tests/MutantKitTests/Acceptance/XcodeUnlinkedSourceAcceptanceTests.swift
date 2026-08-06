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
/// passes — and the run still has to refuse a score.
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
    /// fail the run closed, by name, rather than being silently scored as an
    /// ordinary survivor.
    @Test("A mutation outside every target's Compile Sources fails the run closed")
    func unlinkedMutationIsCaughtByIntegrity() throws {
        let run = try self.run()

        #expect(!run.report.integrity.passed)
        #expect(run.exitCode != 0)
        #expect(run.report.score == nil)

        let violations = run.report.integrity.violations.filter { $0.kind == .mutationNotActivated }
        #expect(!violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")
        #expect(violations.allSatisfy { $0.detail.contains("Unused.swift") })
        #expect(violations.count == 2, "both mutants on the unlinked function should be flagged")
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
