import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces an arithmetic operator with another.
///
/// v1 covers only `+ <-> -` and `* <-> /`. `%` and the overflow operators
/// (`&+`, `&-`, ...) are deliberately left for a later version: each needs
/// its own validation this slice does not yet have.
///
/// **Not proven safe to compile by default.** This operator has no symbol
/// resolution, so it cannot tell whether a site's type actually supports the
/// replacement operator — only that it supports the original one. Swift's
/// arithmetic protocols do not guarantee a matched set: `Numeric` requires
/// `+`/`-`/`*` but not `/` (so `lhs * rhs` on a bare `T: Numeric` mutates to
/// `lhs / rhs`, which does not compile), `String`/`Array` support `+` but
/// not `-`, and a type overloading only one side of a pair (a custom `+`
/// with no matching `-`) is entirely legal Swift. `defaultEnabled` stays
/// `false` until a real project corpus's actual compile-failure rate for
/// this operator has been measured — see
/// `CoreOperatorCompileViabilityAcceptanceTests` for exactly this gap made
/// concrete and empirically confirmed, not merely asserted.
///
/// A targeted 50-mutant corpus run against a real project (see the internal
/// corpus-validation notes, not part of this public repo) measured **0 unviable** —
/// this codebase's actual arithmetic usage didn't happen to hit the
/// fixture-demonstrated failure patterns above. That does not retire those
/// patterns as real risk; it means this one corpus's sample didn't exercise
/// them. The same run originally reported a much larger flaky/infra count
/// than any other operator; `investigation/arithmetic-batch-timeout-cluster`
/// found most of that was a batch-timeout attribution bug (fixed in
/// `ResultClassifier.confirmTimeout`), not genuine instability — 7 of 9
/// "flaky" mutants were fast, deterministic kills/survivors on isolated
/// rebuild. **2 genuine, reproducible hangs remain** (confirmed on a fully
/// isolated, unbatched rebuild), clustered in loop/index-arithmetic code,
/// consistent with (not proven to be) an arithmetic swap turning a
/// terminating computation into one that hangs — see the internal
/// corpus-validation notes' arithmetic batch-timeout investigation (not
/// part of this public repo) for the full classification. `defaultEnabled` should stay `false`
/// pending that runtime-stability question, not just a compile-failure
/// rate.
public struct ArithmeticOperatorReplacementOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.arithmetic-operator-replacement",
        version: 1,
        category: "arithmetic",
        summary: "Replaces an arithmetic operator with another (`+` <-> `-`, `*` <-> `/`).",
        defaultEnabled: false,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            A swapped arithmetic operator (an off-by-operator typo, or a refactor that \
            silently changed `+` to `-`) is a classic source of numeric-logic bugs that a \
            suite asserting only on structure — not on a specific computed value — will \
            never catch. Off by default: this operator's replacement is not guaranteed to \
            compile for every type the original operator works on (see the type's doc \
            comment) — enable explicitly, or via `experimental`, until a real project \
            corpus's compile-failure rate has been measured.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    /// v1's fixed pairing: each operator maps to exactly the other operator
    /// in its pair, never to a third option.
    private static let replacements: [String: String] = [
        "+": "-",
        "-": "+",
        "*": "/",
        "/": "*"
    ]

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .skipChildren }

            let original = node.operator.text
            guard let replacement = ArithmeticOperatorReplacementOperator.replacements[original] else {
                return .skipChildren
            }

            record(MutationCandidate(
                node: node,
                replacementText: replacement,
                note: "Arithmetic operator `\(original)` replaced with `\(replacement)`."
            ))

            return .skipChildren
        }
    }
}
