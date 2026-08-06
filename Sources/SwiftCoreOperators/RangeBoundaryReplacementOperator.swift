import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Swaps a binary range operator's boundary inclusivity: `a..<b` becomes
/// `a...b`, and `a...b` becomes `a..<b`.
///
/// This is the range-specific twin of `RelationalOperatorReplacementOperator`'s
/// boundary form (`<` → `<=`): a suite that only ever exercises values well
/// inside a range, never its exact upper edge, will not notice whether that
/// edge is included or excluded. Array slicing, date windows, and loop bounds
/// are the classic places this class of off-by-one bug hides.
///
/// **v1 covers only the binary infix form** (`a..<b`, `a...b`) — never the
/// one-sided forms (`a...`, `..<b`, `...b`), which parse as
/// `PrefixOperatorExprSyntax`/`PostfixOperatorExprSyntax`, a different node
/// kind with its own distinct risk profile not evaluated here. Both `..<`
/// and `...` lex as a single operator token, exactly like every other binary
/// operator this catalog mutates — no precedence folding is needed, for the
/// same reason `RelationalOperatorReplacementOperator` does not need it: a
/// `BinaryOperatorExprSyntax` token is itself unchanged by folding, only its
/// surrounding tree shape is.
///
/// **Not proven safe to compile or run by default**, for two separate
/// reasons neither of which this operator has symbol resolution to rule
/// out — the same posture `ArithmeticOperatorReplacementOperator` takes for
/// its own unmeasured compile/runtime risk:
///
/// - **Compile risk**: `a..<b` and `a...b` produce different concrete types
///   (`Range<Bound>` vs. `ClosedRange<Bound>`). Most consumers (`Array`
///   slicing, `switch` range patterns, `for`-in) accept either generically,
///   but a call site or parameter explicitly typed to one specific range
///   type — not `RangeExpression`, not the other range type — will not
///   compile after the swap. This operator cannot see a callee's parameter
///   types, so this surfaces honestly as `unviable`, not guessed at here.
/// - **Runtime risk, asymmetric between the two directions**: `..<` → `...`
///   *adds* the upper bound to the range. The single most common place this
///   matters is exactly the idiom this mutation is meant to test —
///   `array[0..<array.count]` or `for i in 0..<array.count { array[i] }` —
///   where including `array.count` is an out-of-bounds index, a genuine
///   runtime crash, not merely a wrong result a suite might silently miss.
///   `...` → `..<` has no equivalent risk in that direction (it only
///   *removes* the upper bound, which cannot create an out-of-bounds access
///   that valid original code did not already have).
///
/// Both directions are otherwise safe against the "invalid bounds" trap
/// (`Range`/`ClosedRange` both already require `lowerBound <= upperBound`
/// in the *original* code; the swap does not change whether that
/// precondition holds, only what happens at the shared boundary value).
///
/// **`defaultEnabled: false`, `confidence: .experimental`.** No real-project
/// corpus measurement yet — held to the same bar every other unvalidated
/// operator in this catalog is (see `Research/operator-catalog/README.md`'s
/// quality gate, which calls for exactly this operator to have "a syntax
/// fixture corpus first" before promotion).
public struct RangeBoundaryReplacementOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.range-boundary-replacement",
        version: 1,
        category: "conditional",
        summary: "Swaps a range operator's boundary inclusivity (`..<` ↔ `...`).",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            An off-by-one range boundary (a slice, loop, or date window that should have \
            excluded — or included — its upper edge) is a classic source of index and \
            fencepost bugs. A suite that only exercises values well inside the range, never \
            the exact boundary, cannot distinguish `..<` from `...`. Off by default: swapping \
            produces a different concrete range type (`Range` vs. `ClosedRange`), which is not \
            guaranteed to compile everywhere the original did, and `..<` -> `...` specifically \
            risks a genuine out-of-bounds runtime crash in the common `array[0..<count]` idiom \
            — enable explicitly, or via `experimental`, until a real project corpus's \
            compile-failure and runtime-stability rate has been measured.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    /// v1's fixed pairing: each operator maps to exactly the other operator
    /// in the pair, never to a third option.
    private static let replacements: [String: String] = [
        "..<": "...",
        "...": "..<"
    ]

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .skipChildren }

            let original = node.operator.text
            guard let replacement = RangeBoundaryReplacementOperator.replacements[original] else {
                return .skipChildren
            }

            record(MutationCandidate(
                node: node,
                replacementText: replacement,
                note: "Range boundary `\(original)` replaced with `\(replacement)`."
            ))

            return .skipChildren
        }
    }
}
