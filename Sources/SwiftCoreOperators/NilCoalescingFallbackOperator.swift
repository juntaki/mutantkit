import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces a nil-coalescing expression with its fallback, `a ?? b` → `b`.
///
/// The whole expression is replaced, not just narrowed to one side — this
/// removes the left-hand optional's involvement entirely rather than
/// substituting a different fallback value, matching the "operator deletion"
/// mutation family (the same shape `UnaryNotRemovalOperator` and
/// `TernaryBranchSwapOperator` belong to: remove or transpose a piece of
/// control flow, don't invent a plausible new value for it).
///
/// **What surviving actually proves.** The original and the mutant agree
/// exactly when `a` is `nil` — both evaluate to `b` — and can only possibly
/// differ when `a` is *non-nil*, where the original yields `a`'s unwrapped
/// value and the mutant always yields `b` regardless. So a surviving mutant
/// does not mean "the nil path is untested" (the nil path is where mutant
/// and original are indistinguishable, not where they diverge) — it means
/// the suite never proved that a non-nil left-hand value is actually
/// preferred over the fallback. Exercising only the `nil` case, or the
/// non-nil case with a left-hand value that happens to equal `b`, both let
/// this mutant survive.
///
/// Never `a!` (a force-unwrap is a distinct, more dangerous mutation — it
/// crashes on `nil` instead of substituting the fallback, and is
/// deliberately out of scope for this operator).
///
/// SwiftParser's raw parse never produces a resolved `InfixOperatorExprSyntax`
/// for `??` any more than it does for `?:` — `??` sits one precedence group
/// below ternary and needs the same folding (see `SyntaxFolding` and
/// `TernaryBranchSwapOperator`'s doc comment) before its left/right operands
/// are real children instead of separate elements of a flat sequence.
///
/// **`defaultEnabled: false` (demoted from default) as of the
/// `validation/core-operator-corpus` run against a real project.** Not a
/// compile-viability problem — every candidate built and ran cleanly (0 unviable).
/// The issue is signal density: `??` defensive-default idioms
/// (`UserDefaults... ?? false`, `cache.object(...) ?? nil`,
/// `visiblePage ?? 0`) are extremely common in real code, and this operator
/// alone occupied half of a 100-mutant stratified sample while killing only
/// ~8% of its buildable mutants — the rest re-stated the same known,
/// low-value "no test distinguishes non-nil-preferred-over-fallback" gap
/// dozens of times over. A default-profile (nightly) run pays that budget
/// and review cost on every run for very little new signal. Available via
/// `experimental` or an explicit `enable` until survivor data from more
/// corpora either justifies re-promotion or motivates a targeted exclusion
/// heuristic — not yet added, since one corpus is too little evidence to
/// risk overfitting an exclusion rule that could hide a genuinely valuable
/// `??` mutant.
public struct NilCoalescingFallbackOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.nil-coalescing-fallback",
        version: 1,
        category: "optional",
        summary: "Replaces a nil-coalescing expression with its fallback (`a ?? b` → `b`).",
        defaultEnabled: false,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Replacing `a ?? b` with `b` forces the fallback path unconditionally. A \
            surviving mutant means the suite does not prove that a non-nil left-hand value \
            is preferred over the fallback - only exercising the case where the left-hand \
            side is `nil` (where the mutant and the original agree) leaves this exact defect \
            - a `??` that always falls back regardless of its left-hand side - undetected. \
            Not proven safe to run by default: a corpus run against a real project found this \
            operator, though always compile-viable, dominates the mutant budget with mostly \
            low-value survivors restating the same defensive-default gap (see \
            CoreOperatorRegistryExpansionTests and the operator catalog for the corpus evidence).
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let folded = SyntaxFolding.fold(context.sourceFile)
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(folded)
        return visitor.candidates
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard let binaryOperator = node.operator.as(BinaryOperatorExprSyntax.self),
                  binaryOperator.operator.text == "??"
            else {
                return .visitChildren
            }
            guard !OperatorExclusions.isExcluded(node) else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: node.rightOperand.trimmedDescription,
                note: "Nil-coalescing expression replaced with its fallback; " +
                    "survives unless a test proves a non-nil left-hand value is preferred over the fallback."
            ))

            return .visitChildren
        }
    }
}
