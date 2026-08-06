import Foundation
import MutationModel
import Testing

/// The full plan -> sandbox -> apply -> build -> test -> classify pipeline,
/// against a real Swift package, for the six operators PR #6 added, plus two
/// later-stage additions (`else-clause-deletion` and
/// `range-boundary-replacement`) -- distinct from
/// `CoreOperatorCompileViabilityAcceptanceTests` and
/// `NilCoalescingFallbackSemanticsAcceptanceTests`, which each drive a raw
/// `swiftc` invocation against a hand-written snippet outside MutantKit
/// entirely. This suite instead asks the real CLI to discover, build, test
/// and classify real mutants of a real project, with `operators.profile:
/// experimental` so the four `defaultEnabled: false` operators
/// (arithmetic/assignment replacement, else-clause-deletion,
/// range-boundary-replacement) are included alongside the four
/// default-profile ones.
///
/// The assertions name the exact mutations expected to live, die, or fail to
/// build, the same calibrated-fixture discipline `SwiftPackageMacOSAcceptanceTests`
/// uses — a score alone cannot distinguish a correct run from one that quietly
/// mutated nothing.
@Suite("Acceptance: core operator expansion, real pipeline", .enabled(if: Acceptance.isEnabled))
struct CoreOperatorExpansionAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: experimental
    execution:
      strategy: isolated
      workers: 2
    reports: [console, json]
    """

    /// Safe to share across this suite's tests for the same reason
    /// `SwiftPackageMacOSAcceptanceTests.sharedRun` is: a real build+test
    /// cycle is too slow to pay once per assertion, and every test here only
    /// reads the resulting report.
    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "CoreOperatorExpansion", configuration: configuration)
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("The run reconciles: every mutant reaches the source, the compiler, and a verdict")
    func runIsInternallyConsistent() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.discovered == 12)
        #expect(integrity.planned == 12)
        #expect(integrity.sourceApplied == 12)
        // One mutant (the generic-`Numeric` arithmetic replacement) never
        // builds -- see `arithmeticReplacementOnANumericGenericFailsToBuild`.
        #expect(integrity.buildObserved == 11)
        #expect(integrity.classified == 12)
        #expect(integrity.reported == 12)

        #expect(run.exitCode == 0)
    }

    /// Per-operator discovered/build-success/build-failure/killed counts —
    /// the concrete evidence the second review round asked for, from a real
    /// pipeline run rather than an isolated `swiftc` call.
    @Test("Every new operator's mutant is discovered, and every buildable one is killed")
    func perOperatorCountsMatchExpectations() throws {
        let run = try self.run()

        func results(for operatorID: String) -> [MutationResult] {
            run.report.results.filter { $0.point.operatorID == operatorID }
        }

        let newOperatorIDs = [
            "swift.core.ternary-branch-swap",
            "swift.core.unary-not-removal",
            "swift.core.nil-coalescing-fallback",
            "swift.core.return-value-replacement",
            "swift.core.assignment-operator-replacement",
            "swift.core.else-clause-deletion",
            "swift.core.range-boundary-replacement"
        ]
        // Each of these seven operators has exactly one mutation site in the
        // fixture, fully covered, so it must be discovered, must build, and
        // must be killed -- never left unproven.
        for operatorID in newOperatorIDs {
            let matches = results(for: operatorID)
            #expect(matches.count == 1, "\(operatorID): expected exactly one mutant, got \(matches.count)")
            #expect(matches.first?.outcome == .killedByAssertion, "\(operatorID) did not die as expected")
        }

        // Arithmetic replacement has two sites: `Ops.sum`'s plain `Int` `+`
        // (builds and is killed) and `Ops.scale`'s generic-`Numeric` `*`
        // (never type-checks, so it is `.unviable`, not killed or survived).
        let arithmetic = results(for: "swift.core.arithmetic-operator-replacement")
        #expect(arithmetic.count == 2)
        #expect(arithmetic.filter { $0.outcome == .killedByAssertion }.count == 1)
        #expect(arithmetic.filter { $0.outcome == .unviable }.count == 1)
    }

    /// The concrete evidence that arithmetic/assignment replacement's
    /// `defaultEnabled: false` is protecting against a real, not merely
    /// hypothetical, build failure — reached through the actual CLI
    /// pipeline (plan, sandbox, apply, `swift build`), not an isolated
    /// `swiftc -typecheck` call.
    @Test("The generic-Numeric arithmetic replacement mutant fails to build, not merely to type-check in isolation")
    func arithmeticReplacementOnANumericGenericFailsToBuild() throws {
        let run = try self.run()

        let scaleMutant = try #require(
            run.report.results.first {
                $0.point.operatorID == "swift.core.arithmetic-operator-replacement"
                    && $0.point.originalText == "*"
            }
        )
        #expect(scaleMutant.outcome == .unviable)
    }

    @Test("Every reported mutant carries evidence that it reached the source")
    func everyMutantHasASourceDiff() throws {
        let run = try self.run()

        for result in run.report.results {
            let evidence = try #require(result.evidence, "\(result.point.displayLocation) has no evidence")
            #expect(evidence.provesSourceApplication, "\(result.point.displayLocation)")
            #expect(evidence.sourceBeforeHash != evidence.sourceAfterHash)
        }
    }
}
