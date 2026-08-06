import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces relational and equality operators.
///
/// Emits two mutations per comparison, for two different reasons:
///
/// - **Boundary** (`<` → `<=`): catches off-by-one. This is the mutation that
///   finds the bug where a test only ever passes values well inside the range
///   and never the edge itself. PIT keeps this as a default operator for the
///   same reason.
/// - **Negation** (`<` → `>=`): catches a comparison that is never actually
///   asserted on — if reversing the condition changes nothing, no test depends
///   on it.
///
/// Both replacements stay within the protocol that provided the original
/// operator (`Comparable` supplies all four; `Equatable` supplies both `==` and
/// `!=`), so the mutants compile for any conforming type. A hand-rolled operator
/// that defines `<` without `<=` will not compile — that surfaces honestly as
/// `unviable` rather than being guessed at here.
public struct RelationalOperatorReplacementOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.relational-operator-replacement",
        version: 1,
        category: "conditional",
        summary: "Replaces a comparison with its boundary and negated forms (e.g. `<` → `<=`, `>=`).",
        defaultEnabled: true,
        confidence: .high,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Off-by-one boundary errors in index, count and date comparisons are among the \
            most common defects reachable from unit tests; a suite that never exercises the \
            boundary cannot distinguish `<` from `<=`.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    /// Boundary shift and logical negation for each supported operator.
    ///
    /// Equality has no meaningful boundary form, so it contributes negation only.
    private static let replacements: [String: (boundary: String?, negation: String)] = [
        "<": ("<=", ">="),
        "<=": ("<", ">"),
        ">": (">=", "<="),
        ">=": (">", "<"),
        "==": (nil, "!="),
        "!=": (nil, "==")
    ]

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .skipChildren }

            let original = node.operator.text
            guard let forms = RelationalOperatorReplacementOperator.replacements[original] else {
                return .skipChildren
            }

            if let boundary = forms.boundary {
                record(MutationCandidate(
                    node: node,
                    replacementText: boundary,
                    note: "Boundary shift: `\(original)` widened/narrowed to `\(boundary)`. " +
                        "Survives only if no test exercises the boundary value."
                ))
            }

            record(MutationCandidate(
                node: node,
                replacementText: forms.negation,
                note: "Negation: `\(original)` reversed to `\(forms.negation)`. " +
                    "Survives only if no test asserts on the outcome of this comparison."
            ))

            return .skipChildren
        }
    }
}
