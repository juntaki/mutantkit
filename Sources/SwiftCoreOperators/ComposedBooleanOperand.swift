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
/// text), which is why only the built-in comparison/logical/arithmetic
/// spellings below are accepted and the operand size is capped; assignments,
/// custom operators, ranges, closures, `try`/`await` and `&x` all keep
/// falling back, each with its own reason text. A plain call, subscript,
/// optional chain or force unwrap is accepted by `isAcceptedCall`.
enum ComposedBooleanOperand {
    /// Upper bound on the source length of a call operand, for the same reason as `maxOperatorNodes`:
    /// the text is duplicated into both arms of the ternary the compiler must type-check.
    static let maxCallOperandCharacters = 160

    /// Whether `unwrapped` is a plain call, subscript, optional-chaining or force-unwrap expression the
    /// lowerers may duplicate into both arms.
    ///
    /// The lowering selects exactly one arm, so the expression runs at most once and in its original
    /// order, as for any other operand, and the operand text (hence the extent of an optional chain, the
    /// trap of a `!`, the arguments of a subscript) is unchanged in both arms; what is left is the
    /// compile-time cost of the duplicated text.
    /// Expressions containing `try`, `await` or a macro expansion keep falling back, as does a long one
    /// and an immediately invoked closure (`{ ... }()`), which stays a closure operand.
    static func isAcceptedCall(_ unwrapped: ExprSyntax) -> Bool {
        guard isAccessKind(unwrapped), unwrapped.trimmedDescription.count <= maxCallOperandCharacters else { return false }
        let scanner = CallHazardScanner(viewMode: .sourceAccurate)
        scanner.walk(unwrapped)
        return !scanner.foundHazard
    }

    private static func isAccessKind(_ unwrapped: ExprSyntax) -> Bool {
        if let call = unwrapped.as(FunctionCallExprSyntax.self) { return !call.calledExpression.is(ClosureExprSyntax.self) }
        return unwrapped.is(SubscriptCallExprSyntax.self) || unwrapped.is(OptionalChainingExprSyntax.self)
            || unwrapped.is(ForceUnwrapExprSyntax.self)
    }

    private final class CallHazardScanner: SyntaxVisitor {
        var foundHazard = false

        override func visit(_: TryExprSyntax) -> SyntaxVisitorContinueKind { mark() }
        override func visit(_: AwaitExprSyntax) -> SyntaxVisitorContinueKind { mark() }
        override func visit(_: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { mark() }

        private func mark() -> SyntaxVisitorContinueKind {
            foundHazard = true
            return .skipChildren
        }
    }

    /// Comparison, short-circuit logical, standard arithmetic and nil-coalescing spellings only. A custom
    /// operator may be overloaded to anything, so it keeps falling back; the operand-count cap keeps
    /// arithmetic from making the duplicated expression expensive to type-check.
    static let acceptedInfixOperators: Set<String> = [
        "&&", "||", "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "&+", "&-", "&*", "??"
    ]
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
