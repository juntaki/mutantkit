import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Deletes a standalone function/method call statement whose return value is
/// discarded — Muter's `RemoveSideEffects`, generalized from
/// `LifecycleSuperCallRemovalOperator`'s fixed-name-list shape to an
/// arbitrary call. A call made purely for its effect (logging, caching, a UI
/// update, an analytics ping, cleanup) whose absence no test notices is
/// exactly the gap this operator exists to surface.
///
/// Full design, including three rounds of adversarial (codex) review and the
/// mistakes each round caught: `Research/operator-catalog/
/// side-effect-call-removal-design.md`. This implementation follows that
/// design's candidacy contract, extended after its own real-corpus/codex
/// review found the design under-scoped point 2 (see point 2's own note
/// below) and missed initializer delegation and subscripts entirely (see
/// points 8-9); see the design doc for the reasoning this doc comment only
/// summarizes, and this file's own inline comments for what changed since.
///
/// **Candidate when all of the following hold:**
/// 1. Used as a statement — climbing through any wrapping `try`/`await`,
///    the outermost wrapper's parent is a `CodeBlockItemSyntax`. The
///    *removed* node is that outermost wrapper, never the bare call: leaving
///    a dangling `try`/`await` keyword does not parse.
/// 2. Not the **last** statement of a `-> T` (`T` not `Void`)
///    function/method/computed-property/subscript body, and not the
///    **sole** statement of a same-shaped closure. The design's original
///    scope here was "sole statement only" — a post-implementation
///    review found that too narrow: a custom, non-stdlib function whose
///    own return type happens to be `Never` can be exactly as load-
///    bearing for an enclosing non-`Void` declaration's reachability as
///    the four denylisted stdlib names in point 6 are, and that hazard
///    exists for the *last* statement of a multi-statement body, not only
///    a sole one (`func value() -> Int { audit(); customNeverHelper() }`
///    compiles today without a `return`, precisely because
///    `customNeverHelper()` is unreachable-after; discovery has no symbol
///    resolution to know that about an arbitrary name). Closures are
///    still governed by "sole statement" only: Swift's implicit-return
///    sugar is for single-*expression* bodies specifically, so a
///    multi-statement closure's last bare statement is never affected
///    (scenario 10 in the design doc) — there is no `return`-based
///    control-flow hazard to protect against for them at all.
/// 3. Not the last statement of a `guard`'s `else` block, regardless of the
///    call's name — a `guard`-else is only valid Swift at all when its last
///    statement is a definite exit, so if the original source compiles with
///    this call there, removing it always breaks that guarantee.
/// 4. Not the sole statement of a `switch` case — Swift requires at least
///    one statement per case, regardless of what it is.
/// 5. Not inside a `@ViewBuilder`-style result-builder body
///    (`OperatorExclusions.isInsideResultBuilderBody`) — a result builder
///    rewrites every statement through `buildBlock`/`buildEither`/
///    `buildOptional`, a transform invisible to the parser.
/// 6. Not a call to one of four well-known, genuinely `Never`-returning
///    stdlib names (`fatalError`, `preconditionFailure`, `exit`, `abort`) —
///    unconditionally, regardless of position. Discovery cannot know
///    locally whether *this* occurrence happens to be load-bearing for some
///    enclosing declaration's reachability (a non-`Void` function whose
///    last statement is a trailing `fatalError()` compiles *without* an
///    explicit `return`, precisely because the compiler treats a call to a
///    `Never`-returning function as an unconditional "unreachable after
///    this" fact) — so these four are excluded everywhere, matching both
///    Muter's own precedent and the master plan's explicit "never remove by
///    default" list. `assertionFailure` is deliberately **not** in this
///    list: its actual stdlib signature returns `Void`, not `Never` (it is
///    stripped to a no-op in a release build), so the compiler never
///    relies on it for reachability anywhere, and it is a normal,
///    legitimate candidate — removing a defensive assertion is exactly the
///    kind of fault a suite should notice.
/// 7. Not named in `execution.operators.sideEffectCallRemoval.excludeCalls`
///    (`SideEffectCallRemovalSettings`) — the direct analogue of Muter's own
///    `excludeCalls`, which `MuterConfigImporter` maps onto this field
///    during `migrate --from-muter` rather than dropping it.
/// 8. Not a `super.*()` call, any name — added after a real-corpus
///    discovery sample against a real production app found `super.init(nibName:bundle:)` as
///    a candidate, which is a near-certain `unviable` mutant (a designated
///    initializer must call a superclass initializer, or delegate via
///    `self.init`, before it completes — Swift enforces this at compile
///    time). Not narrowed to `init` specifically: every other `super.*()`
///    call already belongs to `LifecycleSuperCallRemovalOperator`'s own,
///    separate (not yet promoted) fault model, and duplicating it here
///    under a different operator ID would double-count the same site.
/// 9. Not a `self.init(...)` call — a codex review of this implementation
///    (not the design doc) found the same initializer-delegation hazard
///    as point 8 applies here too: a convenience initializer must
///    delegate via `self.init` before it completes, unconditionally.
///    Narrowed to `init` specifically, unlike point 8's broader `super.*()`
///    exclusion: an ordinary `self.foo()` call carries no such
///    requirement and remains a normal candidate.
///
/// **`defaultEnabled: false`, `confidence: .experimental`.** Two open
/// questions block promotion, per the design doc: the exclusion
/// heuristics' real compile-viability rate, and result-builder detection's
/// real false-negative rate on a SwiftUI-heavy project. A real-corpus
/// discovery sample against a real production app confirmed the second question is a real,
/// live risk, not just a theoretical one: `Spacer()`/`ForEach` calls
/// nested inside an `HStack`'s own trailing closure (inside an
/// arbitrarily-named `some View` helper property, not literally `body`)
/// were proposed as candidates — `HStack`'s content parameter carries
/// `@ViewBuilder` on its own declaration inside SwiftUI's framework
/// source, invisible to a parser with no symbol resolution, exactly the
/// "custom `@resultBuilder` type used as a closure's parameter type" gap
/// `OperatorExclusions.isInsideResultBuilderBody`'s own doc comment
/// already named as accepted, not something this pass attempted to close.
/// The same sample, plus an independent codex review of this
/// implementation, found and closed three real compile-viability gaps
/// (points 2's "last, not just sole" extension, and points 8-9) before
/// this operator's own compile-viability question could be considered
/// even provisionally answered — still not a full corpus measurement,
/// which remains the open blocker.
public struct SideEffectCallRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.side-effect-call-removal",
        version: 1,
        category: "side-effect",
        summary: "Deletes a standalone function/method call statement whose return value is discarded.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            A call made purely for its effect (logging, caching, a UI update, an analytics ping, \
            cleanup) whose absence no test notices means the suite never proved the effect \
            actually happens — Muter's own most-cited operator for this exact reason \
            (`RemoveSideEffects`). Compile-viability and result-builder false-negative rate on a \
            real, SwiftUI-heavy project are both still open corpus questions; see the design doc \
            for what would close them.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(excludedCallNames: context.excludedCallNames, viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        private let excludedCallNames: Set<String>

        init(excludedCallNames: Set<String>, viewMode: SyntaxTreeViewMode) {
            self.excludedCallNames = excludedCallNames
            super.init(viewMode: viewMode)
        }

        /// Genuinely `Never`-returning stdlib names — see the type's own
        /// doc comment (point 6) for why these, and only these four, are
        /// excluded unconditionally regardless of position.
        private static let neverReturningDenylist: Set<String> = [
            "fatalError", "preconditionFailure", "exit", "abort"
        ]

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard !OperatorExclusions.isExcluded(node) else { return .visitChildren }
            guard let context = Self.statementContext(for: node) else { return .visitChildren }
            guard !OperatorExclusions.isInsideResultBuilderBody(Syntax(node)) else { return .visitChildren }

            // Real-corpus finding (Phase C3 corpus sample, a real production app):
            // `super.init(...)` was discovered as a candidate and would
            // have been an almost-certain `unviable` mutant — a designated
            // initializer must call a superclass initializer (or delegate
            // via `self.init`) before it completes; Swift enforces this at
            // compile time, unlike `super.viewDidLoad()`-style calls
            // (LifecycleSuperCallRemovalOperator's own, separate, not-yet-
            // promoted domain), which are only a behavioral convention.
            // Excluded on the same structural signal that operator already
            // uses (`member.base?.is(SuperExprSyntax.self)`) rather than
            // narrowing to `init` specifically: every other `super.*()`
            // call already belongs to that dedicated operator's fault
            // model, and duplicating it here under a different operator ID
            // would double-count the same site.
            guard !Self.isSuperCall(node) else { return .visitChildren }

            // Real-corpus/codex finding: `self.init(...)` is exactly as
            // compile-load-bearing as `super.init(...)` — a convenience
            // initializer must delegate via `self.init` before it
            // completes, unconditionally. Narrowed to `init` specifically
            // (unlike the broader `super.*()` exclusion above): an
            // ordinary `self.foo()` call carries no such requirement and
            // is a normal candidate.
            guard !Self.isSelfInitDelegation(node) else { return .visitChildren }

            if let calledName = Self.calledName(of: node) {
                guard !Self.neverReturningDenylist.contains(calledName) else { return .visitChildren }
                guard !excludedCallNames.contains(calledName) else { return .visitChildren }
            }

            guard !Self.isSoleStatementOfImplicitReturnClosure(context.item) else { return .visitChildren }
            guard !Self.isLastStatementOfNonVoidDeclarationBody(context.item) else { return .visitChildren }
            guard !Self.isLastStatementOfGuardElseBody(context.item) else { return .visitChildren }
            guard !Self.isSoleStatementOfSwitchCase(context.item) else { return .visitChildren }

            record(MutationCandidate(
                node: context.removalNode,
                replacementText: "",
                note: "Removes `\(node.trimmedDescription)`; any effect it has never happens."
            ))

            // Children are still walked: a trailing-closure argument
            // (`foo() { sideEffect() }`) can itself contain independently
            // removable statements, and a nested call used as a genuine
            // sub-expression (an argument, an assignment's RHS) is already
            // rejected by `statementContext` on its own, not by stopping
            // the walk here.
            return .visitChildren
        }

        // MARK: - Statement position (point 1)

        /// What removing `call` actually requires, when it is used as a
        /// statement: the node to delete (the outermost `try`/`await`
        /// wrapper, if any — never the bare call, which would leave a
        /// dangling keyword) and the `CodeBlockItemSyntax` it occupies
        /// (needed by every later structural check, which all reason about
        /// *the statement's position*, not the call expression itself).
        /// `nil` when `call` is not used as a statement at all (an
        /// argument, an assignment's right-hand side, a returned
        /// expression — anything whose immediate statement-wrapper's
        /// parent is not a plain `CodeBlockItemSyntax`).
        private static func statementContext(
            for call: FunctionCallExprSyntax
        ) -> (removalNode: Syntax, item: CodeBlockItemSyntax)? {
            var current = Syntax(call)
            while let parent = current.parent, parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) {
                current = parent
            }
            guard let item = current.parent?.as(CodeBlockItemSyntax.self) else { return nil }
            return (current, item)
        }

        /// True for `super.foo(...)`, any name — see the call site's own
        /// comment for why every `super.*()` call is excluded here rather
        /// than only `super.init(...)` specifically.
        private static func isSuperCall(_ node: FunctionCallExprSyntax) -> Bool {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
            return member.base?.is(SuperExprSyntax.self) == true
        }

        /// True for `self.init(...)` specifically — not every `self.*()`
        /// call, only the initializer-delegation form, which Swift
        /// requires a convenience initializer to reach unconditionally
        /// before it completes.
        private static func isSelfInitDelegation(_ node: FunctionCallExprSyntax) -> Bool {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "init"
            else { return false }
            // Unlike `super`, `self` has no dedicated syntax node kind --
            // it is an ordinary `DeclReferenceExprSyntax` whose base name
            // token happens to be the `self` keyword.
            return member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        }

        /// The called function/method's own base name — `foo` for both
        /// `foo()` and `object.foo()` — or `nil` when the callee is not a
        /// plain identifier or member access (a closure literal called
        /// immediately, a subscript-like call), which no name-based check
        /// (the denylist, `excludeCalls`) can meaningfully match against.
        private static func calledName(of node: FunctionCallExprSyntax) -> String? {
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text
            }
            if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
                return reference.baseName.text
            }
            return nil
        }

        // MARK: - Implicit return, closures (point 2)

        /// True when `item` is the sole statement of a closure whose
        /// return type cannot be proven `Void` from syntax alone — Swift's
        /// implicit-return sugar is specifically for single-*expression*
        /// closures, so this never fires for a closure with two or more
        /// statements (scenario 10: the last of several statements in an
        /// unannotated closure remains an ordinary, safe candidate,
        /// regardless of the closure's inferred type — a real hazard here
        /// would need `return`-based control flow, which a closure body
        /// never has). No annotation at all means the type is inferred
        /// entirely from context (a variable's declared type, a
        /// parameter's expected type), unprovable from syntax alone, so
        /// it is conservatively excluded.
        private static func isSoleStatementOfImplicitReturnClosure(_ item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
                  let closure = list.parent?.as(ClosureExprSyntax.self)
            else { return false }
            guard let returnClause = closure.signature?.returnClause else { return true }
            return !Self.isVoidType(returnClause.type)
        }

        // MARK: - Non-Void function/method/property/subscript bodies (point 2, extended)

        /// True when `item` is the **last** statement of a `-> T`
        /// (`T` not `Void`) function, method, computed property, or
        /// subscript body — not only when it is the body's *sole*
        /// statement (this design's original scope for point 2), extended
        /// after a real-corpus/codex finding: a custom, non-stdlib
        /// function whose own return type happens to be `Never` can be
        /// exactly as load-bearing for the enclosing declaration's
        /// reachability as `fatalError()` is (a non-`Void` function whose
        /// trailing statement is a call to *any* `Never`-returning
        /// function compiles without an explicit `return`, and discovery
        /// has no symbol resolution to rule an arbitrary callee name out).
        /// The unconditional four-name denylist above only ever protects
        /// against the four stdlib names; this protects every other name
        /// too, at the cost of conservatively excluding some genuinely
        /// safe trailing statements this design cannot tell apart from
        /// that hazard — the same trade-off
        /// `ElseClauseDeletionOperator.isSafePosition` already makes for
        /// the analogous "missing return" hazard on a dropped `else`.
        ///
        /// Closures are deliberately **not** covered here — see
        /// `isSoleStatementOfImplicitReturnClosure`'s own doc comment for
        /// why this entire hazard class does not exist for them.
        private static func isLastStatementOfNonVoidDeclarationBody(_ item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id else {
                return false
            }
            let container = list.parent

            // Implicit-getter shorthand (`var value: Int { ...; makeInt() }`,
            // or a subscript's own shorthand form) — the statement list
            // sits directly under `AccessorBlockSyntax` (its `.getter`
            // case), with no `CodeBlockSyntax` and no `AccessorDeclSyntax`
            // at all.
            if let accessorBlock = container?.as(AccessorBlockSyntax.self) {
                return Self.isNonVoidComputedPropertyOrSubscript(accessorBlock)
            }

            guard let codeBlock = container?.as(CodeBlockSyntax.self) else { return false }

            if let function = codeBlock.parent?.as(FunctionDeclSyntax.self) {
                guard let returnClause = function.signature.returnClause else { return false }
                return !Self.isVoidType(returnClause.type)
            }

            // Explicit `get { }` accessor, one level deeper than the
            // shorthand above: CodeBlockSyntax -> AccessorDeclSyntax ->
            // AccessorDeclListSyntax -> AccessorBlockSyntax. Only `get`
            // matters -- a `set` accessor's body is always `Void`-returning.
            if let accessor = codeBlock.parent?.as(AccessorDeclSyntax.self) {
                guard accessor.accessorSpecifier.tokenKind == .keyword(.get) else { return false }
                guard let accessorBlock = accessor.parent?.parent?.as(AccessorBlockSyntax.self) else {
                    return false
                }
                return Self.isNonVoidComputedPropertyOrSubscript(accessorBlock)
            }

            return false
        }

        /// A computed property's type comes from its own
        /// `PatternBindingSyntax.typeAnnotation`; a subscript's comes from
        /// `SubscriptDeclSyntax.returnClause` directly (subscripts always
        /// spell an explicit return type, unlike a property, which may
        /// omit `typeAnnotation` when it can be inferred from an
        /// initializer — a computed property never has an initializer, so
        /// a missing `typeAnnotation` there is simply not this operator's
        /// concern to resolve). Neither ever exposes a return clause the
        /// way a function does.
        private static func isNonVoidComputedPropertyOrSubscript(_ accessorBlock: AccessorBlockSyntax) -> Bool {
            if let binding = accessorBlock.parent?.as(PatternBindingSyntax.self) {
                guard let typeAnnotation = binding.typeAnnotation else { return false }
                return !Self.isVoidType(typeAnnotation.type)
            }
            if let subscriptDecl = accessorBlock.parent?.as(SubscriptDeclSyntax.self) {
                return !Self.isVoidType(subscriptDecl.returnClause.type)
            }
            return false
        }

        /// `Void` or `()` — the two syntactic spellings of no return value.
        /// Anything else, including a type that is only `Void` through a
        /// typealias this operator cannot see through, is not recognized
        /// as `Void` — the conservative direction (a missed exclusion would
        /// be a real bug; a missed *candidate* costs only one site).
        private static func isVoidType(_ type: TypeSyntax) -> Bool {
            if let identifier = type.as(IdentifierTypeSyntax.self) {
                return identifier.name.text == "Void"
            }
            if let tuple = type.as(TupleTypeSyntax.self) {
                return tuple.elements.isEmpty
            }
            return false
        }

        // MARK: - guard-else / switch-case (points 3, 4)

        /// A `guard`'s `else` block must end in a definite exit for the
        /// *original* source to compile at all — so if this call is
        /// genuinely the last statement there, removing it always breaks
        /// that guarantee, regardless of what the call is named (a custom,
        /// user-defined `Never`-returning helper is exactly as load-bearing
        /// as `fatalError` here, and discovery has no way to know its
        /// return type without symbol resolution).
        private static func isLastStatementOfGuardElseBody(_ item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id else {
                return false
            }
            guard let codeBlock = list.parent?.as(CodeBlockSyntax.self) else { return false }
            return codeBlock.parent?.is(GuardStmtSyntax.self) == true
        }

        /// Swift requires at least one statement per `switch` case,
        /// unconditionally — `case .ready: notify()` with `notify()`
        /// removed leaves an empty case, a compile error regardless of
        /// what `notify` is named. Only fires when this is the *sole*
        /// statement (count == 1); a case with a second statement is
        /// unaffected.
        private static func isSoleStatementOfSwitchCase(_ item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1 else { return false }
            return list.parent?.is(SwitchCaseSyntax.self) == true
        }
    }
}
