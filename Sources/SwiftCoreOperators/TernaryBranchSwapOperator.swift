import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Swaps a ternary expression's true and false branches.
///
/// `a ? b : c` becomes `a ? c : b` — the condition and the `?`/`:` tokens are
/// untouched, only the two result expressions trade places. This is the
/// conditional-expression twin of `RelationalOperatorReplacementOperator`'s
/// negation form: a suite that never asserts on the ternary's actual result
/// (only that it returns *some* value, or that the condition was evaluated at
/// all) will not notice its branches are backwards.
///
/// SwiftParser's raw parse never produces a resolved `TernaryExprSyntax` on
/// its own: `?:`, like every other operator, starts out as an element of a
/// flat `SequenceExprSyntax` (here, an `UnresolvedTernaryExprSyntax` sitting
/// between its condition and else-expression siblings) and only becomes a
/// real `TernaryExprSyntax` — with `condition`/`thenExpression`/`elseExpression`
/// as actual children — after precedence folding. `RelationalOperatorReplacementOperator`
/// gets away without folding because a `BinaryOperatorExprSyntax` token is
/// itself unchanged by folding; a ternary's boundaries are not, so this
/// operator folds the tree itself before walking it.
///
/// **`defaultEnabled: true`, validated with a recorded caveat (v0.4 Trust
/// Closure).** Corpus-measured on two real, independently-shaped iOS apps
/// (internal, not part of this public repo): always compile-viable (0 unviable in either
/// project), and a consistently modest-but-real kill rate (13.3% -> 20.8%
/// -> 26.5% across three runs) — never a compile-safety or correctness
/// concern, and never contradicted (unlike `NilCoalescingFallbackOperator`,
/// whose own second-project measurement went the *other* direction). Kept
/// `defaultEnabled` rather than demoted: this is a genuine fault pattern
/// with zero infrastructure risk, and the modest yield has a specific,
/// plausible, non-alarming explanation already identified (SwiftUI
/// view-layer ternaries thinly covered relative to model/service code) —
/// not a signal that the mutation itself is low-value. The one thing this
/// evidence cannot yet rule out is that both measured projects share that
/// same SwiftUI-heavy shape, so the low-yield pattern could still be
/// project-shape-specific rather than general; resolving that needs a
/// non-UI-heavy real project (e.g. a macOS Swift Package), which is
/// deferred, non-blocking future corpus work, not a v0.4 correctness gap.
/// See the internal corpus-validation notes (not part of this public repo)
/// and the operator catalog's item 7 for full tables.
public struct TernaryBranchSwapOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.ternary-branch-swap",
        version: 1,
        category: "conditional",
        summary: "Swaps a ternary expression's true and false branches (`a ? b : c` → `a ? c : b`).",
        defaultEnabled: true,
        confidence: .high,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            A ternary with its branches transposed (`isValid ? errorMessage : successMessage`) \
            reads as plausible at a glance and type-checks identically to the correct form — a \
            suite that checks only "a string was returned", not which specific string, will not \
            catch it.
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
        override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: Self.swapped(node),
                note: "Ternary branches swapped: the true and false result values are reversed."
            ))

            // Unlike a relational/logical operator token or a stacked unary
            // negation, an inner ternary nested in an outer one's branch is
            // an independent site with an independent result — swapping the
            // outer's branches does not touch the inner one's text, and vice
            // versa, so both are genuinely distinct mutations and must both
            // be found.
            return .visitChildren
        }

        /// Swaps only the two branches' own core text (excluding each
        /// branch's own leading/trailing trivia), leaving everything else —
        /// the condition, the `?`/`:` tokens, and every byte of trivia in
        /// between, including comments — exactly where it already is.
        ///
        /// Rebuilding the whole ternary from `trimmedDescription`d pieces
        /// joined by a fixed `" ? "`/`" : "` would silently drop any comment
        /// attached to the `?`, the `:`, or either branch (`flag ? /* true
        /// */ 1 : /* false */ 2` would lose both comments entirely) — a
        /// mutation is supposed to change exactly the one thing it claims
        /// to, not incidentally erase unrelated source text next to it.
        private static func swapped(_ node: TernaryExprSyntax) -> String {
            let nodeStart = node.positionAfterSkippingLeadingTrivia.utf8Offset
            let nodeEnd = node.endPositionBeforeTrailingTrivia.utf8Offset
            let fullText = Array(node.trimmedDescription.utf8)

            let thenStart = node.thenExpression.positionAfterSkippingLeadingTrivia.utf8Offset - nodeStart
            let thenEnd = node.thenExpression.endPositionBeforeTrailingTrivia.utf8Offset - nodeStart
            let elseStart = node.elseExpression.positionAfterSkippingLeadingTrivia.utf8Offset - nodeStart
            let elseEnd = node.elseExpression.endPositionBeforeTrailingTrivia.utf8Offset - nodeStart

            let prefix = fullText[0 ..< thenStart]
            let thenCore = fullText[thenStart ..< thenEnd]
            let middle = fullText[thenEnd ..< elseStart]
            let elseCore = fullText[elseStart ..< elseEnd]
            let suffix = fullText[elseEnd ..< (nodeEnd - nodeStart)]

            return String(decoding: prefix, as: UTF8.self)
                + String(decoding: elseCore, as: UTF8.self)
                + String(decoding: middle, as: UTF8.self)
                + String(decoding: thenCore, as: UTF8.self)
                + String(decoding: suffix, as: UTF8.self)
        }
    }
}
