import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces an explicit `return <expr>`'s value with a type-appropriate,
/// syntactically-justified neutral default.
///
/// Deliberately restricted to what the syntax alone can prove safe:
///
/// - The enclosing function's return type is syntactically `Optional`
///   (`T?` or `Optional<T>`) → the returned expression is replaced with
///   `nil`, whatever it is (except when it already reads `nil`, the no-op
///   this would otherwise produce).
/// - Otherwise, the returned expression's own literal kind decides its
///   neutral replacement: an integer literal → `0`, a string literal → `""`,
///   an array literal → `[]`, a dictionary literal → `[:]` — each skipped
///   when the literal is already that neutral value, so this operator never
///   emits a no-op mutant.
/// - A boolean literal return is left alone: that mutation already belongs
///   to `BoolLiteralInversionOperator`, and duplicating it here would double
///   -count the same site under two operator IDs.
/// - Anything else (a computed expression, a variable reference whose type
///   isn't visible from syntax alone, a return inside a closure or accessor
///   whose own return type isn't a plain function signature) is left
///   untouched — this operator only ever acts where the *syntax* already
///   proves the replacement is well-typed, never by inferring a type it
///   cannot see.
///
/// A function that always returns its literal default regardless of its
/// actual logic is exactly the "did the caller even check the result" gap
/// mutation testing exists to surface — a suite that only asserts the
/// result is non-nil or non-empty, not a specific expected value, will not
/// notice.
///
/// **`defaultEnabled: true`, provisional.** A real-project corpus run
/// measured a 29.4% kill rate, 0 unviable. Still only one project's data,
/// not yet the multiple project shapes the operator catalog's promotion
/// bar calls for; see the internal corpus-validation notes (not part of
/// this public repo).
public struct ReturnValueReplacementOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.return-value-replacement",
        version: 1,
        category: "literal",
        summary: "Replaces an explicit return's literal value with a type-appropriate neutral default.",
        defaultEnabled: true,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            A function that always returns its neutral default (`0`, `""`, `[]`, `nil`) \
            regardless of its actual logic is exactly the "did the caller even check the \
            result" gap mutation testing exists to surface - a suite that only checks a \
            value is non-nil or non-empty, not a specific expected value, will not notice.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        // Folded (see `SyntaxFolding`/`TernaryBranchSwapOperator`'s doc
        // comment): `nil as Int?`'s `as` is, like every other operator,
        // deferred to precedence folding by the raw parse — without this,
        // `isSyntacticallyNilEquivalent`'s `as`-cast case would never match,
        // since the expression it is given would still be an unresolved
        // sequence, not a real `AsExprSyntax`.
        let folded = SyntaxFolding.fold(context.sourceFile)
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(folded)
        return visitor.candidates
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            guard let expression = node.expression else { return .visitChildren }
            guard !OperatorExclusions.isExcluded(node) else { return .visitChildren }
            guard let returnType = Self.enclosingFunctionReturnType(of: Syntax(node)) else {
                return .visitChildren
            }

            if Self.isSyntacticallyOptional(returnType) {
                guard !Self.isSyntacticallyNilEquivalent(expression) else { return .visitChildren }
                record(MutationCandidate(
                    node: expression,
                    replacementText: "nil",
                    note: "Return value replaced with nil; the function's declared return type is Optional."
                ))
                return .visitChildren
            }

            if let replacement = Self.neutralLiteralReplacement(for: expression) {
                record(MutationCandidate(
                    node: expression,
                    replacementText: replacement,
                    note: "Return value replaced with its type's neutral default."
                ))
            }

            return .visitChildren
        }

        /// Walks up from a `return` statement to the return type of the
        /// nearest plain function declaration containing it — stopping (and
        /// reporting no answer) at a closure, accessor, or subscript
        /// boundary first, since a return there belongs to a different,
        /// not-necessarily-annotated return type this operator does not
        /// attempt to resolve.
        private static func enclosingFunctionReturnType(of node: Syntax) -> TypeSyntax? {
            var cursor: Syntax? = node.parent
            while let current = cursor {
                if let function = current.as(FunctionDeclSyntax.self) {
                    return function.signature.returnClause?.type
                }
                if current.is(ClosureExprSyntax.self) || current.is(AccessorDeclSyntax.self)
                    || current.is(SubscriptDeclSyntax.self) {
                    return nil
                }
                cursor = current.parent
            }
            return nil
        }

        /// `T?` or `Optional<T>` — the two syntactic spellings of an
        /// optional return type. Anything else (including a type that is
        /// only optional through a typealias this operator cannot see
        /// through) is not recognized as optional.
        private static func isSyntacticallyOptional(_ type: TypeSyntax) -> Bool {
            if type.is(OptionalTypeSyntax.self) { return true }
            if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Optional" {
                return true
            }
            return false
        }

        /// Every syntactic spelling of "this expression already denotes
        /// nil" this operator recognizes: the bare literal, a cast of it
        /// (`nil as Int?`), and `.none` spelled as `Optional<T>.none` or
        /// bare `.none` (base-less, so it could only be resolved by the
        /// type checker — conservatively treated as nil rather than risk a
        /// false mutation). Replacing any of these with plain `nil` would be
        /// a same-value mutant — different text, identical runtime
        /// behavior — that can never be killed by any test, no matter how
        /// good: it isn't a real mutation to begin with, just noise in the
        /// report.
        ///
        /// `.none` with an explicit, non-`Optional` base (`State.none`, for
        /// some `enum State { case none }`) is deliberately NOT included
        /// here: that names a specific type's own `none` case, wrapped in a
        /// non-nil optional (`.some(State.none)`) once the function returns
        /// it — a real, distinguishable value, not nil. Replacing it with
        /// `nil` changes `.some(State.none)` to `.none` at the `Optional`
        /// level: a genuine mutation this operator must not exclude just
        /// because the member access is also spelled `.none`.
        private static func isSyntacticallyNilEquivalent(_ expression: ExprSyntax) -> Bool {
            if expression.is(NilLiteralExprSyntax.self) { return true }
            if let asExpression = expression.as(AsExprSyntax.self) {
                return isSyntacticallyNilEquivalent(asExpression.expression)
            }
            if let memberAccess = expression.as(MemberAccessExprSyntax.self),
               memberAccess.declName.baseName.text == "none" {
                guard let base = memberAccess.base else {
                    // Bare `.none` — its base type is only known to the type
                    // checker, which this operator does not run. Treated as
                    // nil-equivalent rather than risk emitting an
                    // undetectable same-value mutant on the common case
                    // (`Optional.none`, i.e. plain `nil`).
                    return true
                }
                return Self.namesOptional(base)
            }
            return false
        }

        /// Whether an expression is the bare `Optional` type name, spelled
        /// either plainly (`Optional`) or with an explicit generic argument
        /// (`Optional<Int>`) — the only two syntactic bases under which
        /// `.none` genuinely denotes nil rather than some other type's own
        /// case that happens to be named `none`.
        private static func namesOptional(_ expression: ExprSyntax) -> Bool {
            if let reference = expression.as(DeclReferenceExprSyntax.self) {
                return reference.baseName.text == "Optional"
            }
            if let generic = expression.as(GenericSpecializationExprSyntax.self) {
                return namesOptional(generic.expression)
            }
            return false
        }

        /// A literal's own neutral value for its kind, or `nil` when the
        /// expression is not one of the recognized literal kinds, or is
        /// already — however spelled — that neutral value. Checked
        /// structurally/by actual value, not by comparing source text: a
        /// text comparison alone would miss that `0x0`, `0b0`, and `0o0` are
        /// the same value `0` just spelled differently, that an empty raw
        /// string (`#""#`) is still an empty string, or that `[ ]` (with
        /// internal whitespace) is still an empty array — each of those
        /// would otherwise be "replaced" with a value it already has, the
        /// same kind of undetectable, same-value mutant `isSyntacticallyNilEquivalent`
        /// exists to rule out for the optional-return path.
        private static func neutralLiteralReplacement(for expression: ExprSyntax) -> String? {
            if let integer = expression.as(IntegerLiteralExprSyntax.self) {
                // Unparseable (not `nil`, not zero) is treated the same as
                // "already zero" — skipped, not mutated: proceeding on an
                // unrecognized spelling risks silently emitting a same-
                // value mutant exactly like the ones this value-aware check
                // exists to rule out, which is worse than missing a
                // legitimate mutation opportunity.
                guard let value = integerValue(of: integer.literal.text), value != 0 else { return nil }
                return "0"
            }
            if let string = expression.as(StringLiteralExprSyntax.self) {
                guard !Self.isEmptyStringLiteral(string) else { return nil }
                return "\"\""
            }
            if let array = expression.as(ArrayExprSyntax.self) {
                guard !array.elements.isEmpty else { return nil }
                return "[]"
            }
            if let dictionary = expression.as(DictionaryExprSyntax.self) {
                if case .colon = dictionary.content { return nil }
                return "[:]"
            }
            // Boolean literals are `BoolLiteralInversionOperator`'s site, not
            // this operator's — recording it here too would double-count the
            // same site under two operator IDs. Every other expression kind
            // (a variable reference, a computed expression) is left alone:
            // this operator only acts where the syntax alone already proves
            // the replacement is well-typed.
            return nil
        }

        /// Whether a string literal's actual content is empty — regardless
        /// of quoting style (`""`, `#""#`, `##""##`, ...). Every string
        /// literal has at least one `StringLiteralSegmentListSyntax`
        /// element even when empty (a single zero-length `StringSegmentSyntax`),
        /// so checking `segments.isEmpty` is always false and never detects
        /// this; each segment's own content text must be inspected instead.
        /// An interpolation segment (`\(...)`) makes emptiness unprovable
        /// from syntax alone, so it is conservatively treated as non-empty.
        private static func isEmptyStringLiteral(_ string: StringLiteralExprSyntax) -> Bool {
            for segment in string.segments {
                guard let stringSegment = segment.as(StringSegmentSyntax.self),
                      stringSegment.content.text.isEmpty
                else {
                    return false
                }
            }
            return true
        }

        /// Parses an integer literal token's actual numeric value,
        /// understanding `0x`/`0b`/`0o` radix prefixes and `_` digit
        /// separators. `nil` (not zero) for anything this cannot parse —
        /// never assumed to be non-zero by default, which would risk
        /// treating an actually-neutral value as safe to "replace".
        private static func integerValue(of text: String) -> Int? {
            let digits = text.replacingOccurrences(of: "_", with: "")
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
                return Int(digits.dropFirst(2), radix: 16)
            }
            if digits.hasPrefix("0b") || digits.hasPrefix("0B") {
                return Int(digits.dropFirst(2), radix: 2)
            }
            if digits.hasPrefix("0o") || digits.hasPrefix("0O") {
                return Int(digits.dropFirst(2), radix: 8)
            }
            return Int(digits)
        }
    }
}
