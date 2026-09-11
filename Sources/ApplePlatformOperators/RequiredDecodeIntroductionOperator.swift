import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces the canonical backward-compatible-decode shape
/// `try container.decodeIfPresent(T.self, forKey: key) ?? fallback` with
/// `try container.decode(T.self, forKey: key)` — the accidental regression
/// that turns an optional, schema-evolution-safe field back into a required
/// one.
///
/// **Fault evidence.** This is the real-world shape a project introduces
/// *on purpose* to stay backward compatible when a persisted `Codable` model
/// gains a new field, and the shape this operator mutates is the accidental
/// reversion of that fix:
///
/// - Le Chariot, `Scxttk/lechariot-app` PR #40: a persisted model gained a
///   new field; backward compatibility required `decodeIfPresent` plus a
///   default, and the project explicitly mutation-tested the inverse change
///   (back to `decode`) and confirmed old fixtures failed to decode with
///   `keyNotFound`. Unusually direct evidence — the external project
///   effectively performed this exact mutation by hand and recorded the
///   result. https://github.com/Scxttk/lechariot-app/pull/40
/// - Wikipedia iOS (`wikimedia/wikipedia-ios`): persisted data receives
///   newly-added fields with explicit `decodeIfPresent(...) ?? default`
///   compatibility handling and round-trip tests exercising old stored data
///   against the current model.
///
/// **Expected test surface.** Ordinary unit tests that decode old, on-disk
/// or hard-coded fixture JSON predating the new field — the mutant should
/// fail those tests with a `DecodingError.keyNotFound`, not a hang and not a
/// silent wrong-value substitution. This is a fast, decode-time failure
/// mode, structurally different from `apple.concurrency.continuation-resume-removal`'s
/// dominant `verifiedTimeout` outcome.
///
/// **Matcher — the canonical shape only, four positive constraints, all
/// required together:**
///
/// 1. A call whose member name is exactly `decodeIfPresent` (name-only, no
///    symbol resolution — matching every other operator in this catalog).
/// 2. Exactly two arguments: the first unlabeled and itself a member-access
///    ending in `.self` (the `<Type>.self` shape), the second labeled
///    `forKey:`. This intentionally excludes the single-argument
///    `decodeIfPresent(_:)` overload used by `UnkeyedDecodingContainer` (no
///    `forKey:` label is possible there, so requiring the label already
///    excludes it) and any call with additional arguments (no known stdlib
///    overload has more than two, so a third argument means this is not the
///    canonical shape this operator is scoped to).
/// 3. The call sits under a **plain** `try` — climbing from the call, its
///    immediate parent must be a nil-coalescing (`??`) expression (item 4),
///    and *that* expression's immediate parent must be a `TryExprSyntax`
///    with no `?`/`!` mark. `try?` turns a thrown error into `nil`, which
///    then feeds the *same* `??` fallback — a materially different program
///    already tolerant of a decode failure, not the fault shape this
///    operator targets. `try!` is already a crash-on-throw declaration by
///    the original author; removing the tolerant half of a statement that
///    already asserts it cannot fail does not model the same real-world
///    "forgot to keep this optional" mistake.
/// 4. The call is the immediate left operand of a nil-coalescing (`??`)
///    expression (SwiftParser only produces this shape after
///    `SyntaxFolding.fold` — see that type's own doc comment — the raw
///    parse leaves `??` as a flat, unresolved sequence element).
///
/// Bare `decodeIfPresent(...)` with no `??` fallback at all is naturally
/// excluded by constraint 4 (there is no nil-coalescing expression for it to
/// be the left operand of) — that shape does not have a default value to
/// silently drop, so replacing it with `decode(...)` would be a different,
/// legitimate operator's job (a plain call-argument mutation), not this
/// one's.
///
/// **Replacement.** The *whole* nil-coalescing expression is replaced —
/// `container.decodeIfPresent(T.self, forKey: key)` (method name only
/// changed to `decode`; the two arguments are carried over completely
/// unmodified, so any project-specific `CodingKeys` case or type expression
/// survives verbatim) — dropping `?? fallback` entirely. The enclosing
/// `try` is left untouched, since `decode(_:forKey:)` is throwing exactly
/// like `decodeIfPresent(_:forKey:)` is.
///
/// **Why dropping a `fallback` with side effects is not a special case.**
/// The research handoff asks this question explicitly: could the
/// nil-coalescing right-hand side ever be "semantically part of decode
/// failure handling" in a way that makes dropping it a different, unrelated
/// mutation rather than this one? Reasoned through and rejected: `??`'s
/// right-hand side only ever runs when the *left* side is `nil` — i.e. when
/// the key is present but decodes to a `nil` payload that `decodeIfPresent`
/// itself represents as `Optional.some(.none)` collapsing to `.none`, or
/// more commonly, simply is not this operator's failure path at all
/// (`decodeIfPresent` returns `nil` when the key is *absent*, not when
/// decoding throws — a thrown decode error propagates through `try`
/// regardless of the `??`, exactly as it does after this mutation). So the
/// right-hand side is definitionally the *missing-key* compatibility value,
/// never an error-recovery expression a `catch` or `try?` would be — dropping
/// it (including any side effect it has, such as a logging call or a
/// computed default) is exactly the real-world fault this operator models,
/// not an unrelated behavior change riding along with it. No exclusion is
/// needed or added for this.
///
/// **Compile-safety reasoning, adversarial review round 1 (verified against
/// real `swiftc`, not assumed).**
///
/// - **Generic `T` inference does not depend on `??` here**, unlike
///   `apple.concurrency.continuation-resume-removal`'s
///   `withCheckedContinuation` hazard. `decodeIfPresent<T: Decodable>(_
///   type: T.Type, forKey key: Key) throws -> T?` and
///   `decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T`
///   both take `T.Type` as an *explicit* first argument (`T.self`), so `T`
///   is pinned by the argument itself in both the original and the mutated
///   call — the `??` operator contributes nothing to resolving `T`. This was
///   the exact class of hazard the continuation operator's guard exists for
///   (a generic parameter inferred *bidirectionally*, with the removed
///   expression as one of the pins); it structurally cannot occur here
///   because `T.self` alone already fully determines `T`.
/// - **`??`'s own type-checking already forces `fallback`'s type to unify
///   with `T`.** `decodeIfPresent(...)` returns `T?`; for `a ?? b` to
///   type-check at all, `b` must already be (or be convertible to) `T` — the
///   compiler enforces this on the *original* source before this operator
///   ever sees it. `decode(...)` returns `T` directly. So the assignment
///   target's effective type is `T` either way, before and after mutation:
///   removing the coalescing operator can never introduce a type mismatch a
///   correctly-compiling original didn't already rule out. Verified directly
///   with a battery of real `swiftc -typecheck` fixtures covering a plain
///   value type, an `Optional`-typed `T` (`Int?.self`, so the property is
///   `Int??` before collapsing), an array (`[String].self`), a
///   `RawRepresentable` enum, and a custom nested `Decodable` struct — every
///   one compiles both before and after the mutation.
/// - **A custom, non-stdlib `decodeIfPresent` naming collision is a real,
///   accepted risk this operator does not attempt to rule out.** No symbol
///   resolution is available, so nothing here confirms the receiver is
///   actually a `KeyedDecodingContainer`. A hypothetical type exposing its
///   own two-argument `decodeIfPresent(_:forKey:)`-shaped method with no
///   sibling `decode(_:forKey:)` would produce a mutant that fails to
///   compile (`unviable`), not merely an uninteresting one — a materially
///   different risk profile than
///   `apple.concurrency.continuation-resume-removal`'s name-only `resume`
///   matching, where a false positive costs only a low-value mutant, never a
///   broken build, because deleting a call is always compile-safe regardless
///   of receiver. This operator's risk is judged acceptable rather than
///   guarded against further, for the same reason the research handoff
///   accepts it: real Codable models overwhelmingly call the stdlib
///   `KeyedDecodingContainer.decodeIfPresent(_:forKey:)`, a homonym with a
///   matching `decode(_:forKey:)` sibling is the exceptional case rather
///   than the common one, and this is exactly the kind of risk corpus
///   validation exists to measure rather than to reason about in the
///   abstract — see the corpus evidence in this operator's `faultEvidence`
///   for whether it materialized on two real projects.
///
/// **`defaultEnabled: false`, `confidence: .medium` (corpus-validated
/// opt-in) as of the 2026-09 round.** Landed with real RED tests and
/// registry wiring at `confidence: .experimental`, then corpus-measured on
/// two real, standalone SwiftPM projects — `segmentio/analytics-swift`
/// (14/14 candidates run to completion: 2 `killedByAssertion`, 12
/// `verifiedTimeout`, 0 `survived`, 0 `unviable`) and
/// `amplitude/Amplitude-Swift` (3/3 candidates: 2 `killedByAssertion`, 1
/// `survived` — a specific, well-explained single test gap, not a
/// blind spot). Zero `unviable`/`infrastructureFailure` across both (17
/// candidates total); zero integrity violations. Full evidence, exact
/// commit SHAs and toolchains: the internal corpus-validation research
/// for this operator (not part of this public repo).
///
/// **Why opt-in, not default, despite clean compile safety.** The
/// `segmentio/analytics-swift` run found this operator's *dominant*
/// outcome was `verifiedTimeout` (12/14, ~3.5 minutes each), not the fast
/// `keyNotFound` throw this type's own doc comment above predicted as the
/// only failure mode — root-caused directly (see the corpus README's own
/// "The verifiedTimeout finding"), not assumed: a real hang in that
/// project's `Analytics` startup pipeline, which decodes an
/// `HttpConfig`-shaped settings payload on its startup critical path and
/// swallows the resulting thrown error inside an unbounded
/// `waitUntilStarted` wait instead of surfacing it. The
/// `amplitude/Amplitude-Swift` run shows the fast, cheap kill this
/// operator's cost story predicts *is* real (48-78s `killedByAssertion`)
/// — so the fast path is not hypothetical, only not the dominant one on
/// the harder of the two corpora. A materially different cost profile than
/// `profile: default` budgets for, the same reasoning
/// `apple.concurrency.continuation-resume-removal` was kept opt-in for —
/// reachable via `profile: experimental` or an explicit `operators.enable`
/// entry, not via `profile: default`.
///
/// `schemataEligible: false` remains unchanged — no schemata lowerer exists
/// for this operator; implementing one is explicitly out of scope for this
/// landing.
public struct RequiredDecodeIntroductionOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.persistence.required-decode-introduction",
        version: 1,
        category: "persistence",
        summary: "Replaces `decodeIfPresent(T.self, forKey:) ?? fallback` with `decode(T.self, forKey:)`, " +
            "turning a backward-compatible optional field back into a required one.",
        defaultEnabled: false,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Le Chariot, Scxttk/lechariot-app PR #40: a persisted model gained a new field; \
            backward compatibility required decodeIfPresent plus a default, and the project \
            explicitly mutation-tested the inverse change (back to decode) and confirmed old \
            fixtures failed to decode with keyNotFound -- the external project effectively \
            performed this exact mutation by hand. https://github.com/Scxttk/lechariot-app/pull/40 \
            Also grounded in wikimedia/wikipedia-ios's own decodeIfPresent(...) ?? default \
            compatibility handling for newly-added persisted fields, with round-trip tests against \
            old stored data. See this type's own doc comment for the full compile-safety reasoning \
            (verified against real swiftc, not assumed). Corpus-measured 2026-09 on \
            segmentio/analytics-swift (14/14 candidates: 2 killedByAssertion, 12 verifiedTimeout -- \
            root-caused to a real hang in that project's Analytics startup pipeline, not a harness \
            artifact -- 0 survived, 0 unviable) and amplitude/Amplitude-Swift (3/3 candidates: 2 \
            killedByAssertion, 1 survived -- a specific, well-explained single test gap). Zero \
            unviable/infrastructureFailure across both (17 candidates total); zero integrity \
            violations. Promoted confidence to medium on this evidence -- validated opt-in, not \
            default: the verifiedTimeout-dominant cost profile on the harder corpus, not compile \
            safety or signal quality, is why defaultEnabled stays false. Full evidence: internal \
            corpus-validation research for this operator (not part of this public repo).
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
        override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            guard let binaryOperator = node.operator.as(BinaryOperatorExprSyntax.self),
                  binaryOperator.operator.text == "??"
            else {
                return .visitChildren
            }

            guard let call = node.leftOperand.as(FunctionCallExprSyntax.self),
                  Self.isCanonicalDecodeIfPresentCall(call),
                  Self.isUnderPlainTry(node)
            else {
                return .visitChildren
            }

            record(MutationCandidate(
                node: node,
                replacementText: Self.replacementText(for: call),
                note: "Replaces the backward-compatible decodeIfPresent(...) ?? fallback with a " +
                    "required decode(...), so old fixtures missing this key fail with keyNotFound " +
                    "instead of falling back to the default."
            ))

            return .visitChildren
        }

        /// A call whose member name is exactly `decodeIfPresent`, with
        /// exactly two arguments: an unlabeled `<Type>.self` first argument
        /// and a `forKey:`-labeled second argument. See the operator's own
        /// doc comment (constraint 2) for why this excludes both the
        /// single-argument `UnkeyedDecodingContainer` overload and any call
        /// with more than two arguments.
        private static func isCanonicalDecodeIfPresentCall(_ call: FunctionCallExprSyntax) -> Bool {
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "decodeIfPresent"
            else { return false }

            let arguments = Array(call.arguments)
            guard arguments.count == 2 else { return false }

            let typeArgument = arguments[0]
            guard typeArgument.label == nil, Self.isTypeSelfExpression(typeArgument.expression) else { return false }

            let keyArgument = arguments[1]
            guard keyArgument.label?.text == "forKey" else { return false }

            return true
        }

        /// True for the `<Type>.self` shape (`Int.self`, `[String].self`,
        /// `MyModel.self`, `Int?.self`, ...) — a member access whose member
        /// name is exactly `self`. Deliberately does not attempt to confirm
        /// the base is actually a type expression (that needs symbol
        /// resolution); matching `.self` by name alone is precise enough in
        /// practice, since referring to a *value's* `.self` member as a
        /// decode-type argument is not real Swift usage.
        private static func isTypeSelfExpression(_ expression: ExprSyntax) -> Bool {
            guard let member = expression.as(MemberAccessExprSyntax.self) else { return false }
            return member.declName.baseName.text == "self"
        }

        /// True when `node` (the `??` expression whose left operand is the
        /// `decodeIfPresent` call) sits as the immediate, sole expression
        /// under a plain `try` — no `try?`/`try!`. See the operator's own
        /// doc comment (constraint 3) for why both marked forms are
        /// excluded.
        private static func isUnderPlainTry(_ node: InfixOperatorExprSyntax) -> Bool {
            guard let tryExpr = node.parent?.as(TryExprSyntax.self) else { return false }
            return tryExpr.questionOrExclamationMark == nil
        }

        /// `container.decode(T.self, forKey: key)` — same base expression
        /// and the same two arguments as the original call, verbatim, with
        /// only the member name changed from `decodeIfPresent` to `decode`.
        private static func replacementText(for call: FunctionCallExprSyntax) -> String {
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
                // Unreachable: isCanonicalDecodeIfPresentCall already
                // required this shape before this is ever called.
                return call.trimmedDescription
            }
            let renamedDeclName = member.declName.with(\.baseName, .identifier("decode"))
            let renamedMember = member.with(\.declName, renamedDeclName)
            let renamedCall = call.with(\.calledExpression, ExprSyntax(renamedMember))
            return renamedCall.trimmedDescription
        }
    }
}
