import SwiftOperators
import SwiftSyntax

/// Resolves `SequenceExprSyntax` nodes into their precedence-folded form.
///
/// SwiftParser's raw parse leaves every operator-shaped expression — a
/// comparison, an arithmetic chain, a ternary — as a flat sequence of
/// operands and unresolved operator tokens; only folding turns `a ? b : c`
/// into a real `TernaryExprSyntax` with `condition`/`thenExpression`/
/// `elseExpression` children (an `UnresolvedTernaryExprSyntax` otherwise, with
/// no reference to either the condition or the else-expression at all — both
/// are separate elements of the surrounding, still-flat sequence). An
/// operator whose candidate spans more than the single unfolded token it
/// matched (unlike `RelationalOperatorReplacementOperator`'s
/// `BinaryOperatorExprSyntax`, which is unchanged by folding) needs the
/// resolved shape to find its boundaries at all.
///
/// `SourceAnchorVerifier` folds the same way when it re-parses to confirm an
/// anchor, so a mutation discovered against the folded tree re-verifies
/// against the same tree shape rather than the raw, unfolded one.
public enum SyntaxFolding {
    /// A site that fails to fold (a genuinely ambiguous or malformed operator
    /// sequence) is left unfolded rather than aborting the whole file: the
    /// error is silently dropped, the same "miss rather than crash" contract
    /// every operator in this codebase already has for input it does not
    /// recognize.
    public static func fold(_ node: some SyntaxProtocol) -> Syntax {
        OperatorTable.standardOperators.foldAll(node) { _ in }
    }
}
