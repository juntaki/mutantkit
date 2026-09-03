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
        // 14, not the 12 an earlier version of this test expected: besides
        // the 9 sites each operator's own doc comment in Ops.swift names
        // directly, `experimental` profile discovery also (correctly)
        // finds 3 incidental `relational-operator-replacement` candidates
        // (`label`'s own `score >= 60`, two replacement directions, and
        // `bonus`'s own `tier == 3`) and, not accounted for by any prior
        // version of this count, 2 incidental `side-effect-call-removal`
        // candidates inside `validate`'s own two `notes.append(...)` calls
        // — a real, independently-matched operator finding real
        // side-effecting calls that happen to live inside the function
        // added to demonstrate `else-clause-deletion`, not a dedicated
        // fixture site of their own. Verified empirically (`mutantkit plan`
        // + `mutantkit run` against this exact fixture) before updating
        // this number: all 14 are genuine, correctly-classified candidates
        // — 13 `killedByAssertion`, 1 `unviable` — not a discovery bug. See
        // `sideEffectCallRemovalCandidatesInsideValidate` and
        // `incidentalRelationalCandidates` below for the pinned shapes.
        #expect(integrity.discovered == 14)
        #expect(integrity.planned == 14)
        #expect(integrity.sourceApplied == 14)
        // One mutant (the generic-`Numeric` arithmetic replacement) never
        // builds -- see `arithmeticReplacementOnANumericGenericFailsToBuild`.
        #expect(integrity.buildObserved == 13)
        #expect(integrity.classified == 14)
        #expect(integrity.reported == 14)

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

    /// `Ops.validate` is `else-clause-deletion`'s own dedicated fixture
    /// function, not `side-effect-call-removal`'s — but its two branches
    /// each call a real, side-effecting `notes.append(...)`, and
    /// `side-effect-call-removal` independently matches both. This is a
    /// genuine, correctly-caught incidental candidate, not a dedicated site
    /// the way `newOperatorIDs`' own seven are; pinned separately here
    /// (shape and outcome, not just a count) so a future discovery-logic
    /// regression that silently drops or misclassifies either one is
    /// caught, the same way `runIsInternallyConsistent`'s own `14` would
    /// have caught the reverse (a phantom addition).
    @Test("side-effect-call-removal independently catches both of validate's own notes.append(...) calls")
    func sideEffectCallRemovalCandidatesInsideValidate() throws {
        let run = try self.run()

        let matches = run.report.results.filter { $0.point.operatorID == "swift.core.side-effect-call-removal" }
        #expect(matches.count == 2, "expected exactly validate's own two notes.append(...) calls, got \(matches.count)")
        #expect(matches.allSatisfy { $0.outcome == .killedByAssertion })

        let originals = Set(matches.map(\.point.originalText))
        #expect(originals == ["notes.append(\"ok\")", "notes.append(\"warning\")"])
    }

    /// Two functions this fixture added for a *different* operator each
    /// also contain a real relational comparison `relational-operator-
    /// replacement` independently matches: `label`'s own `score >= 60`
    /// (two replacement directions — `<` and `>` — from the same `>=`
    /// site) and `bonus`'s own `tier == 3`. Genuine incidental candidates,
    /// same reasoning as the side-effect-call-removal pair above.
    @Test("relational-operator-replacement independently catches label's >= and bonus's ==")
    func incidentalRelationalCandidates() throws {
        let run = try self.run()

        let matches = run.report.results.filter { $0.point.operatorID == "swift.core.relational-operator-replacement" }
        #expect(matches.count == 3)
        #expect(matches.allSatisfy { $0.outcome == .killedByAssertion })

        // `label`'s own `>=` produces two candidates (one per replacement
        // direction); `bonus`'s own `==` produces one.
        let shapes = matches.map { "\($0.point.originalText)->\($0.point.replacementText)" }.sorted()
        #expect(shapes == ["==->!=", ">=-><", ">=->>"].sorted())
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
