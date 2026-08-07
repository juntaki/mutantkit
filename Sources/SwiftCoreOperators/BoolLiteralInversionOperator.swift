import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Inverts `true` and `false` literals.
///
/// The simplest operator that exists, chosen for v0.1 precisely because it is
/// uninteresting: it exercises the whole pipeline — plan, anchor, apply, build,
/// run, classify, prove — without the operator itself ever being the reason
/// something failed.
public struct BoolLiteralInversionOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.bool-literal-inversion",
        version: 1,
        category: "literal",
        summary: "Replaces a boolean literal with its opposite (true ↔ false).",
        defaultEnabled: true,
        confidence: .high,
        // Stays false until Phase 4's differential test proves the schemata
        // form agrees with isolated execution. No operator is grandfathered in.
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Inverted feature-flag and guard defaults are a recurring class of regression \
            in Swift apps; a boolean default that no test pins down can be flipped without \
            any test noticing.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .skipChildren }

            let original = node.literal.text
            guard let inverted = Self.inversion(of: original) else { return .skipChildren }

            record(MutationCandidate(
                node: node,
                replacementText: inverted,
                note: "Boolean literal `\(original)` inverted to `\(inverted)`."
            ))

            return .skipChildren
        }

        private static func inversion(of text: String) -> String? {
            switch text {
            case "true": "false"
            case "false": "true"
            default: nil
            }
        }
    }
}
