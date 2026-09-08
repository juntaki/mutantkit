import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes a call to `resume()`/`resume(returning:)`/`resume(throwing:)`/
/// `resume(with:)` on a continuation, when it is a statement in its own
/// right.
///
/// **Fault evidence.** Grounded in a real, classified corpus of 15
/// independently-verified bug-fix commits across 4 open-source Swift
/// projects (`apple/swift-async-algorithms`, `apple/swift-nio`,
/// `pointfreeco/swift-composable-architecture`,
/// `pointfreeco/swift-concurrency-extras`), Category B specifically — "a
/// continuation (or set of pending continuations) never gets resumed" — 5
/// of those 15 commits. See `Research/fault-taxonomy/apple-concurrency-operators-research.md`
/// (internal, not part of this public repo) for the full corpus, the
/// classification methodology, and this operator's own self-assessment
/// against the catalog's promotion bar. A real MutantKit run against
/// `swift-async-algorithms` independently reproduced this exact fault
/// shape by accident (an unrelated operator hit a continuation-resume call
/// site and produced a genuine, reproducible hang) — this operator makes
/// that fault reachable on purpose, with a diff that says what actually
/// happened, instead of waiting for an unrelated mutation to stumble into
/// it.
///
/// **`defaultEnabled: false`, `confidence: .medium` (corpus-validated opt-in).**
/// Landed with real RED tests and registry wiring, then corpus-measured on
/// two real projects (2026-09): `apple/swift-async-algorithms` (75/75
/// candidates run to completion — 34 killed, 19 survived, 18 `noCoverage`,
/// 4 `infrastructureFailure`, all four root-caused to a corpus-selection
/// artifact, not an operator defect: a trait-gated file compiled out under
/// the default build configuration) and `apple/swift-nio` (the full 38
/// discovered candidates run to completion — 18 killed, 1 survived, 12
/// `noCoverage`, 5 `infrastructureFailure` root-caused to a legacy
/// duplicate target never linked into the configured test targets, same
/// artifact shape as swift-async-algorithms'). The swift-nio run found 2
/// genuinely `unviable` candidates — a real compile-safety gap this
/// operator's guards did not yet cover, described below — closed before
/// this promotion, then re-verified at zero `unviable` against the same
/// real corpus. Zero integrity violations on either project. Full
/// evidence, exact commit SHAs, toolchain versions and per-mutant tables:
/// `Research/corpus-validation/continuation-resume-removal-2026-09/`.
///
/// **Why opt-in, not default, despite clean corpus results.** Compile
/// safety and signal quality both check out, but the cost profile does
/// not fit `profile: default`: on both projects, every covered candidate's
/// dominant outcome was `verifiedTimeout`, not a fast `killed`/`survived`
/// verdict, and each `verifiedTimeout` costs on the order of 5-15 minutes
/// of wall time (the mutant's own test timeout, doubled by
/// `confirmTimedOutMutants`). A dropped `.resume()` call is exactly the
/// fault MutantKit's own README names as the reason it owns its timeout
/// machinery ("A mutant that deletes a `continuation.resume()` hangs
/// forever") — the corpus run confirms this is the operator's *normal*
/// outcome shape, not an edge case: 21/34 kills on swift-async-algorithms
/// (61.8%) and all 18/18 kills on swift-nio were `verifiedTimeout`.
/// Real signal (it proves the exact one-line regression would hang CI),
/// but a materially different cost/value shape than every other operator
/// in this catalog — reachable via `profile: experimental` or an explicit
/// `operators.enable` entry, same as the rest of that profile's operators,
/// not via `profile: default`.
///
/// `schemataEligible: false` remains unchanged — an isolated-vs-schemata
/// differential proof is a separate, not-yet-attempted promotion gate; see
/// the research document's own "What would be needed before promoting any
/// of these" for what that would require.
///
/// **Scope, four restrictions, each verified against a real `swiftc`
/// compile rather than assumed:**
///
/// 1. Matched on method name only (`resume`), like every other operator in
///    this catalog family — no symbol resolution, so nothing here confirms
///    the receiver is actually an `UnsafeContinuation`/`CheckedContinuation`/
///    `UnsafeThrowingContinuation`/`CheckedThrowingContinuation`. A false
///    positive here costs one uninteresting mutant, not a wrong build.
/// 2. Never the sole statement of a `switch` case. Swift requires at least
///    one executable statement per case, unconditionally ("'case' label in
///    a 'switch' must have at least one executable statement", confirmed
///    directly with a full `swiftc -typecheck`) — deleting the sole
///    statement there is not merely a low-value mutant, it is a
///    non-compiling one. **An `if`/`else` branch body or a `catch` body do
///    not need this same exclusion** — confirmed directly with a full
///    `swiftc -typecheck` that `if x { }` and `catch { }` (empty bodies)
///    both compile — despite the research document above naming those two
///    shapes alongside `switch` as needing the same guard. Their claim was
///    empirically wrong for these two shapes specifically; verified, not
///    assumed, before excluding switch-case only.
/// 3. Never the sole statement of a closure whose parameter list is
///    entirely implicit (no `in` clause, no `signature` at all — the
///    `{ $0?.resume() }` shorthand). Confirmed directly: emptying such a
///    closure's body (`{ }`) fails to compile ("contextual type for
///    closure argument list expects 1 argument, which cannot be implicitly
///    ignored"), while a closure with an explicit parameter, even an
///    unused one (`{ cont in }`, `{ _ in }`), compiles fine empty. This
///    operator's own return-type reasoning needs no equivalent to
///    `SideEffectCallRemovalOperator`'s `isSoleStatementOfImplicitReturnClosure`
///    check: every `resume` overload returns `Void` unconditionally, so a
///    `resume()` call can never be a closure's non-`Void` implicit-return
///    value in the first place — the only real hazard here is the
///    parameter-omission one just described, not a return-type one.
/// 4. Never the last remaining `resume`-family call reachable inside the
///    trailing closure of `withCheckedContinuation`/
///    `withCheckedThrowingContinuation`/`withUnsafeContinuation`/
///    `withUnsafeThrowingContinuation` (matched by name only, same as
///    everywhere else here). Found on `apple/swift-nio`'s real corpus, not
///    a fixture-only risk: those four functions' generic `Success` type is
///    inferred bidirectionally from how the continuation is used inside
///    its own closure, and a `resume`/`resume(returning:)` call is one of
///    the things that pins it. Confirmed directly: `await
///    withCheckedContinuation { continuation in self.queue.async {
///    self.doSomething(); continuation.resume() } }`, in a function with no
///    explicit return type independently pinning `Success`, fails to
///    typecheck once its only `resume()` is removed ("generic parameter
///    'T' could not be inferred") — even though that call is not the sole
///    statement of its own block (`self.doSomething()` runs first), so
///    guards 2 and 3 above do not and should not catch it; this is a
///    distinct hazard from either. Also confirmed directly: a *second*
///    `resume`-family call anywhere else in the same continuation closure
///    (each branch of an `if`/`else`, say) is enough for inference to
///    succeed, so only the closure's *last* one is excluded. The sibling
///    check matches the enclosing closure's own continuation-parameter
///    name specifically, not `resume` by method name alone — an earlier
///    version of this guard matched by name only and was found, by
///    adversarial review, to under-exclude when an unrelated same-named
///    call was also present (`DispatchSourceTimer.resume()`, a real stdlib
///    API that plausibly co-occurs with a continuation in
///    timeout/cancellation code, could mask that the continuation's own
///    call was the closure's sole pin) — confirmed directly and fixed
///    before landing. Conservative by construction, not exhaustive:
///    whether removal actually compiles also depends on whether anything
///    *outside* the closure independently pins `Success` (an explicit
///    return-type annotation on the enclosing function, say) — confirmed
///    directly that such a case compiles fine even with zero `resume`
///    calls in the closure — but nothing here can see that without symbol
///    resolution, which `requiresSymbolResolution: false` rules out; this
///    excludes every case regardless, trading an unmeasured number of
///    false negatives for a guarantee of no new false positives from this
///    specific shape.
///
/// **Known trade-off (adversarial review, round 1): the closure exclusion
/// above is broader than the hazard it defends against.** It excludes
/// *every* closure with no explicit parameter clause, not only the ones
/// whose arity would make an empty body ambiguous. Confirmed directly:
/// `DispatchQueue.main.async { continuation.resume() }` empties to
/// `DispatchQueue.main.async { }`, which compiles fine — that closure
/// expects zero parameters, so there is no `$0` to leave unreferenced —
/// yet the guard excludes it anyway, since it cannot tell a zero-arity
/// closure from a one-arity one without symbol resolution. This is a
/// missed valid mutant (a false negative), never a broken one, and
/// `DispatchQueue.async`/completion-handler-style zero-argument closures
/// are arguably a more common real shape for resuming a continuation than
/// the one-argument `forEach` case this scope restriction was built
/// against. Left conservative rather than adding arity inference, which
/// `requiresSymbolResolution: false` rules out.
///
/// **Known-safe by construction, not by an explicit guard:** a `resume()`
/// call can never be the sole statement of a `guard`'s `else` body in
/// valid original source — Swift requires a `guard`-else to end in a
/// statement that does not fall through (`return`/`throw`/`break`/
/// `continue`/a `Never`-returning call), and `resume()` returns `Void` and
/// falls through, so any original source shaped that way would already
/// fail to compile before this operator ever saw it (confirmed directly:
/// `guard let x = y else { resume() }` alone is rejected, "'guard' body
/// must not fall through"). No separate exclusion is needed for a case
/// that cannot exist.
public struct ContinuationResumeRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.concurrency.continuation-resume-removal",
        version: 1,
        category: "concurrency",
        summary: "Removes a call that resumes a continuation, so the mutant never signals completion.",
        defaultEnabled: false,
        confidence: .medium,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Research/fault-taxonomy/apple-concurrency-operators-research.md \
            (internal, not part of this public repo), Category B: 5 independently- \
            verified bug-fix commits across apple/swift-async-algorithms, apple/swift-nio, \
            pointfreeco/swift-composable-architecture, and pointfreeco/swift-concurrency-extras, \
            each fixing a continuation that was never resumed on some code path. Corpus-measured \
            2026-09 on apple/swift-async-algorithms (75/75 candidates: 34 killed, 19 survived, \
            18 noCoverage, 4 infrastructureFailure -- root-caused, not an operator defect) and \
            apple/swift-nio (full 38/38 candidates: 18 killed, 1 survived, 12 noCoverage, \
            5 infrastructureFailure -- root-caused, not an operator defect). The swift-nio run \
            found 2 genuinely unviable candidates -- a real compile-safety gap not covered by the \
            first three guards (a resume() call that is its continuation-creating closure's sole \
            remaining pin for generic-parameter inference) -- closed with a fourth guard before \
            this promotion, re-verified at zero unviable against the same real corpus; the fix's \
            own adversarial review found and closed a second gap in the first attempt. Zero \
            integrity violations on either project; verifiedTimeout was confirmed as the dominant \
            outcome for covered candidates on both projects (100% on swift-nio), exactly as \
            this operator's own doc comment predicted. Full evidence: \
            Research/corpus-validation/continuation-resume-removal-2026-09/. Kept \
            `defaultEnabled: false` on cost grounds (each verifiedTimeout costs minutes, not \
            seconds), not on compile-safety or signal-quality grounds -- see the document's own \
            "What would be needed before promoting any of these" for the isolated-vs-schemata \
            differential proof still outstanding.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "resume"
            else { return .visitChildren }

            // Only remove the call when it is a statement in its own right.
            // `let x = continuation.resume()` is not something we can
            // delete without leaving code that does not compile (though
            // every `resume` overload actually returns `Void`, so this
            // exact shape would be unusual real code, not a hazard this
            // operator needs to reason about further).
            guard let item = node.parent?.as(CodeBlockItemSyntax.self) else { return .visitChildren }

            guard !Self.isSoleStatementOfSwitchCase(item) else { return .visitChildren }
            guard !Self.isSoleStatementOfImplicitParameterClosure(item) else { return .visitChildren }
            guard !Self.isSoleResumeCallInContinuationCreatingClosure(node) else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: "",
                note: "Removes the resume call, so nothing ever signals this continuation's completion."
            ))

            return .skipChildren
        }

        /// Swift requires at least one executable statement per `switch`
        /// case, unconditionally — `SwitchCaseSyntax.statements` is a bare
        /// `CodeBlockItemListSyntax`, no `CodeBlockSyntax` wrapper, unlike
        /// an `if`/`catch` body (see the type's own doc comment for the
        /// direct `swiftc` confirmation that those two do not need this
        /// same exclusion).
        private static func isSoleStatementOfSwitchCase(_ item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1 else { return false }
            return list.parent?.is(SwitchCaseSyntax.self) == true
        }

        /// True when `item` is the sole statement of a closure with no
        /// explicit parameter clause at all (the bare `{ $0.resume() }`
        /// shorthand) — see the type's own doc comment for the direct
        /// `swiftc` confirmation that emptying such a closure's body fails
        /// to compile, while a closure with an explicit parameter (even an
        /// unused one, `{ cont in }`/`{ _ in }`) does not.
        private static func isSoleStatementOfImplicitParameterClosure(_ item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
                  let closure = list.parent?.as(ClosureExprSyntax.self)
            else { return false }
            return closure.signature == nil
        }

        /// The four stdlib functions whose generic `Success`/`Failure` type
        /// is inferred bidirectionally from how their continuation is used
        /// inside their own trailing closure, name-matched only (no symbol
        /// resolution, matching every other check in this operator).
        private static let continuationCreatingFunctionNames: Set<String> = [
            "withCheckedContinuation", "withCheckedThrowingContinuation",
            "withUnsafeContinuation", "withUnsafeThrowingContinuation"
        ]

        /// True when `node` is the last surviving `resume`-family call
        /// reachable inside the trailing closure of a call to one of the
        /// four functions above — found on `apple/swift-nio`'s real corpus,
        /// not from a fixture: `await withCheckedContinuation { continuation
        /// in self.queue.async { self.doSomething(); continuation.resume() }
        /// }`, in a function with no explicit return type pinning `Success`,
        /// fails to typecheck once emptied ("generic parameter 'T' could not
        /// be inferred"), confirmed directly with a real `swiftc -typecheck`
        /// — this is a real MutantKit false positive on real code, not a
        /// fixture-only risk. Confirmed directly, also: a *second*
        /// `resume`-family call anywhere else in the same continuation
        /// closure (an `if`/`else`'s two branches, say) is enough for
        /// inference to succeed, so only the closure's *last* one is
        /// excluded — this is deliberately not the same check as "sole
        /// statement" above: `node` here is the last of *two* statements in
        /// its own block (`self.doSomething()` runs first), which the
        /// existing sole-statement guards do not and should not catch.
        ///
        /// Conservative by construction, not exhaustive: whether removal
        /// actually breaks the build also depends on whether anything
        /// *outside* this closure independently pins `Success` (an explicit
        /// return-type annotation on the enclosing function, say) —
        /// confirmed directly that such a case compiles fine even with zero
        /// `resume` calls in the closure — but nothing here can see that
        /// without symbol resolution, which `requiresSymbolResolution:
        /// false` rules out. This excludes every case regardless, trading a
        /// real but unmeasured number of false negatives (mutants that
        /// would in fact have compiled) for a guarantee of zero new false
        /// positives from this specific shape, the same trade this
        /// operator's other guards already make.
        private static func isSoleResumeCallInContinuationCreatingClosure(_ node: FunctionCallExprSyntax) -> Bool {
            guard let closure = nearestContinuationCreatingClosure(enclosing: Syntax(node)) else { return false }
            let parameterName = continuationParameterName(of: closure)
            return !containsAnotherResumeCall(in: Syntax(closure), excluding: node, onReceiverNamed: parameterName)
        }

        /// The name `resume`-family calls must be sent to for this closure's
        /// own continuation, so a same-named `resume()` on an unrelated
        /// receiver (`DispatchSourceTimer.resume()`, a real stdlib API that
        /// plausibly co-occurs with a continuation in timeout/cancellation
        /// code) is never mistaken for a second call that would keep type
        /// inference alive — found by adversarial review, not a fixture:
        /// matching `resume` by method name alone here, the same way
        /// discovery itself does, is wrong at this specific point, because
        /// here the question is not "is this a resume call" but "is this
        /// *this closure's own* continuation's resume call". Falls back to
        /// `$0` for a closure with no signature at all — reaching this point
        /// with such a closure cannot happen today, since
        /// `isSoleStatementOfImplicitParameterClosure` above already
        /// excludes a `resume()` that is the sole statement of one, but nothing
        /// stops a non-sole-statement one from reaching here, so this
        /// still needs a real answer rather than an assumption.
        private static func continuationParameterName(of closure: ClosureExprSyntax) -> String {
            guard let signature = closure.signature, let clause = signature.parameterClause else { return "$0" }
            switch clause {
            case let .simpleInput(shorthand):
                return shorthand.first?.name.text ?? "$0"
            case let .parameterClause(parameters):
                return parameters.parameters.first?.firstName.text ?? "$0"
            }
        }

        /// The base identifier a `resume`-family call was sent to, unwrapping
        /// optional-chaining (`continuation?.resume()`) and force-unwrap
        /// (`continuation!.resume()`) — both real shapes already covered by
        /// this operator's positive RED tests — so a wrapped reference to the
        /// same parameter is still recognized as the same receiver.
        private static func receiverName(of expr: ExprSyntax) -> String? {
            if let decl = expr.as(DeclReferenceExprSyntax.self) { return decl.baseName.text }
            if let optional = expr.as(OptionalChainingExprSyntax.self) { return receiverName(of: optional.expression) }
            if let forced = expr.as(ForceUnwrapExprSyntax.self) { return receiverName(of: forced.expression) }
            return nil
        }

        /// Walks upward from `syntax` to the nearest enclosing closure that
        /// is itself the trailing closure of a call to one of the four
        /// continuation-creating functions above, or `nil` if `syntax` is
        /// not inside one.
        private static func nearestContinuationCreatingClosure(enclosing syntax: Syntax) -> ClosureExprSyntax? {
            var current: Syntax? = syntax
            while let candidate = current {
                if let closure = candidate.as(ClosureExprSyntax.self),
                   let call = closure.parent?.as(FunctionCallExprSyntax.self),
                   call.trailingClosure?.id == closure.id,
                   isContinuationCreatingCall(call) {
                    return closure
                }
                current = candidate.parent
            }
            return nil
        }

        private static func isContinuationCreatingCall(_ call: FunctionCallExprSyntax) -> Bool {
            if let identifier = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return continuationCreatingFunctionNames.contains(identifier.baseName.text)
            }
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                return continuationCreatingFunctionNames.contains(member.declName.baseName.text)
            }
            return false
        }

        /// True when some `resume`-family call other than `target`, sent to
        /// `receiverName` specifically, appears anywhere within `syntax`'s
        /// subtree. The receiver check is load-bearing, not cosmetic: only a
        /// second call on the *same* continuation parameter keeps the
        /// compiler's type inference alive, so a same-named call on anything
        /// else must not count as one.
        private static func containsAnotherResumeCall(
            in syntax: Syntax,
            excluding target: FunctionCallExprSyntax,
            onReceiverNamed receiverName: String
        ) -> Bool {
            if let call = syntax.as(FunctionCallExprSyntax.self), call.id != target.id,
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "resume",
               let base = member.base, Self.receiverName(of: base) == receiverName {
                return true
            }
            return syntax.children(viewMode: .sourceAccurate).contains {
                containsAnotherResumeCall(in: $0, excluding: target, onReceiverNamed: receiverName)
            }
        }
    }
}
