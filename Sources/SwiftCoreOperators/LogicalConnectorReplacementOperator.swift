import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces short-circuit boolean connectors (`&&` ↔ `||`).
///
/// This is one of Muter's established operators and is also part of the common
/// operator set in Stryker and Mull. It is deliberately syntax-only: if `&&`
/// compiled at the original site, both operands are valid boolean expressions,
/// and `||` has the same result type (and vice versa). That gives this operator
/// a much better compile-success profile than general arithmetic replacement.
///
/// The mutation is semantically strong but still local. It exposes tests that
/// exercise a compound condition without proving that *all* required clauses
/// (for `&&`) or *any* sufficient clause (for `||`) actually matter.
public struct LogicalConnectorReplacementOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.logical-connector-replacement",
        version: 1,
        category: "conditional",
        summary: "Replaces short-circuit boolean connectors (`&&` ↔ `||`).",
        defaultEnabled: true,
        confidence: .high,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Muter ships Change Logical Connector as a core Swift mutation operator; Stryker and \
            Mull likewise include logical AND/OR replacement in their standard operator catalogs. \
            The mutation models a common weakening/strengthening error in compound guards and \
            validation predicates.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private static let replacements: [String: String] = [
        "&&": "||",
        "||": "&&"
    ]

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .skipChildren }

            let original = node.operator.text
            guard let replacement = LogicalConnectorReplacementOperator.replacements[original] else {
                return .skipChildren
            }

            record(MutationCandidate(
                node: node,
                replacementText: replacement,
                note: "Logical connector `\(original)` replaced with `\(replacement)`. " +
                    "A survivor means the suite does not prove the compound condition's full semantics."
            ))

            return .skipChildren
        }
    }
}
