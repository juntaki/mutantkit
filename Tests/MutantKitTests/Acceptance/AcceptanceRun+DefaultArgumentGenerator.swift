import Foundation
import MutationModel

extension AcceptanceRun {
    /// The fixture's default-argument mutation: `init(loyaltyDiscountEnabled: Bool = true)`.
    static let unreferencedDefaultArgument = Mutation(
        declaration: "init(loyaltyDiscountEnabled:)", original: "true", replacement: "false"
    )

    /// Whether this run's toolchain linked the fixture's tests without the
    /// default-argument generator.
    ///
    /// Both tests pass the flag explicitly, so nothing references the
    /// generator. A toolchain whose debug link passes `-dead_strip` (Swift
    /// 6.4) removes it, the test image is then identical to the baseline's,
    /// and the run reports the mutation as an infrastructure failure whose
    /// activation evidence is `buildProductIdenticalToBaseline`. A toolchain
    /// that keeps it (Swift 6.3) lets the mutant run and survive.
    ///
    /// True only when the result carries exactly that evidence, so any other
    /// way this mutation can fail still fails the calling assertion.
    var unreferencedDefaultArgumentWasStripped: Bool {
        report.results.contains(where: Self.isStrippedDefaultArgument)
    }

    /// Whether `result` is the default-argument mutation reported as having
    /// left the test image identical to the baseline's.
    static func isStrippedDefaultArgument(_ result: MutationResult) -> Bool {
        guard result.outcome == .infrastructureFailure,
              result.point.enclosingDeclaration.path.last == unreferencedDefaultArgument.declaration,
              result.point.originalText == unreferencedDefaultArgument.original,
              result.point.replacementText == unreferencedDefaultArgument.replacement,
              case .buildProductIdenticalToBaseline? = result.evidence?.applicationEvidence?.isolatedActivation
        else { return false }
        return true
    }

    /// 1 when the generator was stripped, else 0: the number of mutants that
    /// are neither scored nor executed in a run of the fixture.
    var strippedCount: Int { unreferencedDefaultArgumentWasStripped ? 1 : 0 }

    /// `expected` with the default-argument mutation removed when this run's
    /// linker stripped its generator.
    func expectedSurvivors(_ expected: Set<Mutation>) -> Set<Mutation> {
        unreferencedDefaultArgumentWasStripped ? expected.subtracting([Self.unreferencedDefaultArgument]) : expected
    }
}
