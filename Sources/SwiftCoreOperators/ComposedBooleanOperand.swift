import MutationModel
import SwiftSyntax

/// Shared, deliberately narrow acceptance rule for an operand that is itself
/// a composed boolean/comparison expression (`a == b`, `x < y`, `p && q`,
/// `!flag`, nested to a bounded size) whose every leaf is already accepted
/// by the calling lowerer's own `unsafetyReason` — not a general purity or
/// symbol analysis.
///
/// Why this is semantically safe for the lowerers that call it: they all
/// lower to `(isActive ? (A) : (B))` where `A` and `B` are each the *whole*
/// original expression text with only the mutated operator/branch changed.
/// Exactly one arm runs, and that arm evaluates its operands in the
/// original source order with the original `&&`/`||` short-circuiting, so
/// accepting a composed operand never duplicates an evaluation or changes
/// order. The remaining hazards are compile-time ones (operator overload
/// resolution, type-checker cost of a ternary holding two copies of the
/// text), which is why only the built-in comparison/logical spellings below
/// are accepted and the operand size is capped; assignments, custom or
/// arithmetic operators, `??`, ranges, calls, closures, `try`/`await`,
/// optional chaining and `&x` all keep falling back, each with its own
/// reason text.
enum ComposedBooleanOperand {
    /// Comparison and short-circuit logical spellings only.
    static let acceptedInfixOperators: Set<String> = ["&&", "||", "==", "!=", "<", "<=", ">", ">="]
    /// Upper bound on infix/prefix operator nodes inside one operand
    /// (counting the operand itself): keeps the duplicated text, and the
    /// ternary the compiler must type-check, small.
    static let maxOperatorNodes = 8

    /// Whether `unwrapped` (parentheses already removed) is an infix or
    /// prefix operator expression, i.e. handled by this rule at all.
    static func isComposed(_ unwrapped: ExprSyntax) -> Bool {
        unwrapped.is(InfixOperatorExprSyntax.self) || unwrapped.is(PrefixOperatorExprSyntax.self)
    }

    /// `nil` when the composed operand is acceptable, otherwise the distinct
    /// fallback reason. `recurse` is the caller's own `unsafetyReason`, so
    /// every leaf is judged by exactly the rule the caller already applies.
    static func unsafetyReason(
        for unwrapped: ExprSyntax, recurse: (ExprSyntax) -> SchemataUnsupportedReason?
    ) -> SchemataUnsupportedReason? {
        let count = operatorNodeCount(in: unwrapped)
        if count > maxOperatorNodes {
            return .unsupportedOperand(
                reason: "composed operand too large: \(count) operators (limit \(maxOperatorNodes)): \(unwrapped.trimmedDescription)"
            )
        }
        return check(unwrapped, recurse: recurse)
    }

    private static func check(
        _ unwrapped: ExprSyntax, recurse: (ExprSyntax) -> SchemataUnsupportedReason?
    ) -> SchemataUnsupportedReason? {
        if let infix = unwrapped.as(InfixOperatorExprSyntax.self) {
            guard let op = infix.operator.as(BinaryOperatorExprSyntax.self) else {
                return .unsupportedOperand(
                    reason: "non-binary infix operand (assignment/cast/ternary-like): \(unwrapped.trimmedDescription)"
                )
            }
            let text = op.operator.text
            guard acceptedInfixOperators.contains(text) else {
                return .unsupportedOperand(
                    reason: "infix operand with operator '\(text)' outside comparison/logical set: \(unwrapped.trimmedDescription)"
                )
            }
            return recurse(infix.leftOperand) ?? recurse(infix.rightOperand)
        }
        if let prefix = unwrapped.as(PrefixOperatorExprSyntax.self) {
            let text = prefix.operator.text
            guard text == "!" else {
                return .unsupportedOperand(
                    reason: "prefix operand with operator '\(text)' other than '!': \(unwrapped.trimmedDescription)"
                )
            }
            return recurse(prefix.expression)
        }
        return nil
    }

    private static func operatorNodeCount(in expr: ExprSyntax) -> Int {
        final class Counter: SyntaxVisitor {
            var count = 0
            override func visit(_: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                count += 1
                return .visitChildren
            }

            override func visit(_: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                count += 1
                return .visitChildren
            }
        }
        let counter = Counter(viewMode: .sourceAccurate)
        counter.walk(expr)
        return counter.count
    }
}
