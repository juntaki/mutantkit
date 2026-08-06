import Foundation
import MutationModel
import Testing

/// The coverage-enabled acceptance run, against the same fixture as the
/// default-mode suite.
///
/// The fixture's survivors are deliberately on lines the tests do not reach.
/// That is what makes it a calibration tool: with coverage off, those mutants
/// are `survived`; with coverage on, they should be `noCoverage`. The two
/// suites together prove the Effective Mutation Score did not change shape —
/// the same mutants still enter its denominator — while the Tested score
/// becomes honest about *why* a mutant got through.
///
/// This is also the empirical proof the HANDOVER demanded: instrumentation
/// changes the baseline binary, and the activation evidence that compares a
/// mutant's hash against the baseline's has to keep working under that change.
/// If this suite fails the "every scored mutant is proven active" check, the
/// `MachOCodeHash` allow-list is no longer sufficient on this toolchain.
@Suite(
    "Acceptance: Swift package on macOS with coverage",
    .enabled(if: Acceptance.isEnabled)
)
struct SwiftPackageMacOSCoverageAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 2
      measureCoverage: true
    reports: [console, json]
    """

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SwiftPackageMacOS", configuration: configuration)
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    /// The headline change: with coverage on, mutants on lines the suite never
    /// reached are `noCoverage` rather than `survived`.
    ///
    /// Line coverage is not mutation detection: a line that was executed may
    /// still carry a mutant the suite does not catch. `init(loyalty...)` at
    /// line 9 and `bulkDiscountRate`'s boundary at line ~23 are both covered
    /// (tests pass explicit values), but the default value change and the
    /// off-by-one are not caught. They remain `survived`. Only `isFreeShipping`
    /// at line 31 is truly unreached — its two mutants become `noCoverage`.
    @Test("Survivors and noCoverage reflect what line coverage can and cannot say")
    func survivorsAndNoCoverage() throws {
        let run = try self.run()

        // Only the truly unreached function is noCoverage.
        #expect(run.mutations(withOutcome: .noCoverage) == [
            .init(declaration: "isFreeShipping(total:)", original: ">=", replacement: ">"),
            .init(declaration: "isFreeShipping(total:)", original: ">=", replacement: "<")
        ])

        // Covered lines whose mutations still go undetected.
        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "init(loyaltyDiscountEnabled:)", original: "true", replacement: "false"),
            .init(declaration: "bulkDiscountRate(itemCount:)", original: ">", replacement: ">=")
        ])

        // The kills are unchanged.
        #expect(run.killed == [
            .init(declaration: "qualifiesForSeniorRate(age:)", original: ">=", replacement: ">"),
            .init(declaration: "qualifiesForSeniorRate(age:)", original: ">=", replacement: "<"),
            .init(declaration: "bulkDiscountRate(itemCount:)", original: ">", replacement: "<=")
        ])
    }

    /// Activation evidence has to keep working under instrumentation. This is
    /// the load-bearing empirical check the HANDOVER demanded: every covered
    /// mutant — the ones that were actually built and tested — must still be
    /// proven active in the build product, otherwise `MachOCodeHash`'s
    /// allow-list is letting coverage sections into the comparison and every
    /// mutant looks activated for the wrong reason.
    @Test("Every built mutant is proven active in the build product")
    func builtMutantsAreProvenActive() throws {
        let run = try self.run()

        // noCoverage mutants are not built, so they carry no activation evidence
        // by design. The remaining mutants — killed — were built and tested,
        // and every one of them must carry proof the mutation reached the binary.
        for result in run.report.results where result.outcome != .noCoverage {
            let activation = try #require(
                result.evidence?.applicationEvidence?.isolatedActivation,
                "\(result.point.displayLocation) has no activation evidence"
            )
            #expect(activation.provesActivation, "\(result.point.displayLocation)")
        }
    }

    /// A `noCoverage` mutant still carries the source diff. Activation evidence
    /// is correctly absent (we never built it), and the run does not flag the
    /// result as a phantom — `isReportable` is satisfied by the source diff
    /// alone, which is exactly what the model promised.
    @Test("A noCoverage mutant carries a source diff but no activation evidence")
    func noCoverageEvidenceShape() throws {
        let run = try self.run()

        let noCoverage = run.report.results.filter { $0.outcome == .noCoverage }
        #expect(!noCoverage.isEmpty)

        for result in noCoverage {
            let evidence = try #require(result.evidence, "\(result.point.displayLocation)")
            #expect(evidence.provesSourceApplication, "noCoverage mutant lost its source diff")
            #expect(evidence.buildProductHash == nil, "noCoverage mutant was not built")
            #expect(evidence.applicationEvidence == nil, "noCoverage mutant has spurious activation")
        }
    }

    /// The integrity check still passes. The fast path that produces
    /// `noCoverage` without building has to keep the run reconciled: every
    /// discovered mutant is still accounted for, every covered mutant is still
    /// built and tested.
    @Test("Integrity reconciles across the coverage fast path")
    func integrityReconciles() throws {
        let run = try self.run()
        let integrity = run.report.integrity

        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.discovered == 7)
        #expect(integrity.planned == 7)
        // Every mutant has a source diff — the fast path applies the edit even
        // when it skips the build.
        #expect(integrity.sourceApplied == 7)
        // The two noCoverage mutants skipped the build; the other five did not.
        #expect(integrity.buildObserved == 5)
        #expect(integrity.executed == 5)
        #expect(integrity.classified == 7)
        #expect(integrity.reported == 7)

        #expect(run.report.score != nil)
        #expect(run.exitCode == 0)
    }

    /// The Effective Mutation Score is unchanged from the default-mode suite:
    /// the same mutants enter its denominator. The Tested Mutation Score is
    /// now higher — `noCoverage` is excluded from its denominator, and two of
    /// the four former survivors were on uncovered lines. The new Tested score
    /// reflects how well the suite catches mutants *that it actually reached*.
    @Test("Effective score is stable; Tested score improves with noCoverage")
    func scoresAreHonest() throws {
        let run = try self.run()
        let score = try #require(run.report.score)

        // 3 killed, 2 survived, 2 noCoverage.
        #expect(score.killed == 3)
        #expect(score.survived == 2)
        #expect(score.noCoverage == 2)
        // tested  = 3 / (3+2) = 0.6
        // effective = 3 / (3+2+2) = 0.4286...
        #expect(score.tested == 0.6)
        #expect(score.effective == 3.0 / 7.0)
    }
}
