import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes a boolean prefix negation, `!x` → `x`.
///
/// Only the boolean-negation prefix operator — never unary minus (a distinct
/// operator, `swift.core.unary-minus-removal`'s eventual concern, not this
/// one's), never force-unwrap (`value!`, a *postfix* operator on a different
/// node kind entirely), never optional chaining (`value?.count`, likewise a
/// different node kind).
///
/// A suite that never asserts on both sides of a negated guard
/// (`if !isReady`) will not notice the negation is gone: the mutant simply
/// takes the branch the original condition's *complement* would have taken.
///
/// A double negation (`!!flag`) lexes as a single `PrefixOperatorExprSyntax`
/// whose operator token is the two-character `"!!"` — Swift's lexer combines
/// consecutive operator characters into one maximal token, so there is no
/// nested `!` node here to walk into. That token is matched *exactly*
/// against `"!"`, never against "every character is `!`": `"!!"` is not
/// provably two stacked built-in negations just because it looks that way —
/// nothing rules out a user-defined `prefix operator !!` with entirely
/// different semantics (Swift allows exactly that), and this operator has no
/// symbol resolution to check which one it is. A real double negation
/// written as two genuine, separate `!` tokens (`!(!flag)`, the parenthesis
/// breaking the lexer's maximal munch) is unaffected by this and is found as
/// two independent sites, same as any other nesting.
///
/// **`defaultEnabled: true`, provisional.** A targeted 50-mutant corpus run
/// against a real project measured a healthy 40.0% kill rate, 0 unviable —
/// no signal-density concern found. Still only one project's data, not yet
/// the multiple project shapes the operator catalog's promotion bar calls
/// for; see the internal corpus-validation notes (not part of this public
/// repo).
public struct UnaryNotRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.unary-not-removal",
        version: 1,
        category: "conditional",
        summary: "Removes a boolean prefix negation (`!x` → `x`).",
        defaultEnabled: true,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            A dropped `!` on a guard or early-return condition (`if !isValid` silently \
            becoming `if isValid`) inverts exactly which branch runs — a one-character \
            regression that type-checks identically and is easy to miss in review, which a \
            suite that only exercises one polarity of the condition will not catch either.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            // Exact match only: `"!!"`, `"!!!"`, or any other run of `!`
            // characters is a single lexed token that could just as well be
            // a user-defined `prefix operator !!` as two stacked built-in
            // negations — this operator cannot tell which, and guessing
            // wrong would silently mutate a custom operator's semantics
            // instead of removing a negation.
            guard node.operator.text == "!" else { return .visitChildren }
            guard !OperatorExclusions.isExcluded(node) else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: node.expression.trimmedDescription,
                note: "Boolean negation `!` removed."
            ))

            // An independent `!` nested inside this one's expression
            // (`!(a && !b)`'s inner `!b`, or a genuine double negation
            // written as `!(!flag)`, say) is a distinct site and must still
            // be found.
            return .visitChildren
        }
    }
}
