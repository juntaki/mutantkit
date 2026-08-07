import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces a compound assignment operator with another.
///
/// v1 covers only `+= <-> -=` and `*= <-> /=`, one syntactic level up from
/// `ArithmeticOperatorReplacementOperator`. `%=` and the bitwise compound
/// assignments are deliberately out of scope for the same reason: each needs
/// its own validation this slice does not yet have.
///
/// **Not proven safe to compile by default**, for the identical reason
/// `ArithmeticOperatorReplacementOperator` is not: this operator has no
/// symbol resolution, and Swift's compound-assignment operators are not
/// guaranteed to come in matched pairs. `var text = ""; text += "a"` is
/// valid — `String` supports `+=` via `RangeReplaceableCollection` — but
/// `text -= "a"` is not, since `String` has no `-=` at all. `defaultEnabled`
/// stays `false` until a real project corpus's actual compile-failure rate
/// has been measured — see `CoreOperatorCompileViabilityAcceptanceTests`.
///
/// A targeted 50-mutant corpus run against a real project (see the internal
/// corpus-validation notes, not part of this public repo) measured
/// **0 unviable** and a healthy 37.5% kill rate, without
/// `ArithmeticOperatorReplacementOperator`'s runtime-instability pattern in
/// that same corpus (1/50 flaky, no timeouts). Still only one project's
/// data, not the multiple project shapes the operator catalog's promotion
/// bar calls for, and not proof the fixture-demonstrated compile risk above
/// can't occur elsewhere — this corpus's assignment usage simply didn't hit
/// it.
public struct AssignmentOperatorReplacementOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.assignment-operator-replacement",
        version: 1,
        category: "arithmetic",
        summary: "Replaces a compound assignment operator with another (`+=` <-> `-=`, `*=` <-> `/=`).",
        defaultEnabled: false,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Compound assignment is where accumulator and counter logic actually lives; a \
            swapped compound operator (`total += price` silently becoming `total -= price`) \
            breaks exactly the running-total bugs a suite that only checks the loop \
            terminated, not the final accumulated value, will not catch. Off by default: \
            this operator's replacement is not guaranteed to compile for every type the \
            original supports (see the type's doc comment) — enable explicitly, or via \
            `experimental`, until a real project corpus's compile-failure rate has been \
            measured.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    /// Same fixed, two-way pairing as `ArithmeticOperatorReplacementOperator`,
    /// one syntactic level up.
    private static let replacements: [String: String] = [
        "+=": "-=",
        "-=": "+=",
        "*=": "/=",
        "/=": "*="
    ]

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .skipChildren }

            let original = node.operator.text
            guard let replacement = AssignmentOperatorReplacementOperator.replacements[original] else {
                return .skipChildren
            }

            record(MutationCandidate(
                node: node,
                replacementText: replacement,
                note: "Compound assignment operator `\(original)` replaced with `\(replacement)`."
            ))

            return .skipChildren
        }
    }
}
