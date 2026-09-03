import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Deletes an `if` expression's trailing `else` clause: `if a { X } else { Y }`
/// becomes `if a { X }`. The condition is never touched — only the `else`
/// branch's code is gone, so when `a` is now false, nothing runs at all
/// (not `X`, not `Y`) where the `else` branch used to run. In an `else if`
/// chain, each level's own `else` is an independent candidate — `if a {}
/// else if b {} else {}` yields two sites: dropping everything from the
/// first `else` (removing both the `b`-branch and the final `else`, so a
/// false `a` now falls straight through to nothing) and, independently,
/// dropping just the innermost `else` (keeping the `a`/`b` choice, removing
/// only the catch-all).
///
/// A suite that never exercises the `else` path — or never distinguishes
/// "the `else` branch ran" from "nothing happened" — will not notice it is
/// gone. This is a distinct fault from what
/// `RelationalOperatorReplacementOperator` or
/// `LogicalConnectorReplacementOperator` already cover: those mutate the
/// *condition*, this removes an entire *branch*, which a condition-only
/// mutation can never model (a condition mutation still runs some version
/// of both branches across a suite; a missing `else` makes the condition's
/// false case silently do nothing instead of whatever the `else` branch
/// would have done).
///
/// **Only the `else` clause is ever removed — never the `if` branch itself,
/// and never the condition.** Swift requires an `if` used as a statement to
/// have at least the `if` branch (there is no such thing as an `if`
/// statement with only an `else`), so `if`-without-`else` is always the
/// resulting shape, always legal.
///
/// **Only when the whole `if`/`else if`/`else` chain is used as a
/// statement, and — a second constraint two rounds of codex review found
/// missing from the first version — only when it is not the *last*
/// statement of a non-`Void` body.** Swift 5.9's `if`/`switch` expressions
/// (`let x = if cond { 1 } else { 2 }`, or a single-expression, non-`Void`
/// function/closure/computed-property body) require an `else` to produce a
/// value in every case; separately, even a last `if`/`else` whose branches
/// already `return` explicitly still needs the `else` to make every path
/// through a non-`Void` function return something — deleting it leaves the
/// condition's `false` case falling off the end with nothing, "missing
/// return in function expected to return 'T'" (a real compile failure
/// `-typecheck` alone does not catch; only a full compile does). Both
/// hazards apply only to the last item of a block, so discovery only needs
/// to check position when it *is* last, and only recognizes one enclosing
/// shape as safe there: a `FunctionDeclSyntax` with no `-> T` at all
/// (implicit `Void`, immune to both hazards). See `Visitor.isSafePosition`
/// for the full reasoning and the deliberately conservative fallback for
/// every other shape (`init`, computed properties, closures, subscripts).
///
/// Discovery walks up through any enclosing `else if` levels (each of
/// which is itself another `IfExprSyntax`, reachable only via the child it
/// parents at its own `elseBody` slot) to find the chain's true outermost
/// `if` before running either check — an `if` used as a statement, and its
/// position within its block, are both properties of the *whole chain*, so
/// this only needs to run once per chain, at whichever level is being
/// considered, not separately at each level.
///
/// **Excluded inside a result-builder body — except a capability-proven
/// allowlist, currently `@ViewBuilder` only.** A fourth codex review found
/// this needed regardless of last/non-last position: a result builder
/// transforms *every* statement, and `if`/`else` there compiles via
/// `buildEither(first:/second:)`, a different builder method than the
/// plain `buildOptional(_:)` a resulting else-less `if` would need — a
/// minimal custom builder can implement one without the other. See
/// `OperatorExclusions.isInsideResultBuilderBody` for the general
/// detection approach (shared with `side-effect-call-removal-design.md`'s
/// identical problem) and its accepted gaps.
///
/// This blanket rule was proven *over*-conservative for at least one real
/// builder: a real, compiled, run fixture showed a builder
/// implementing both `buildEither` *and* `buildOptional` compiles the
/// else-deleted form fine and produces a genuinely different runtime
/// result, while a second fixture implementing `buildEither` alone
/// reproduces the original hazard exactly (a real compile failure,
/// `swiftc` diagnostic: "add 'buildOptional(_:)' to the result builder").
/// Real SwiftUI's own `@ViewBuilder` was then confirmed, via a real
/// `-typecheck` against the iOS SDK, to compile both the with-`else` and
/// without-`else` forms of `View.body` — i.e. `ViewBuilder` is on the
/// `buildOptional`-implementing side of that boundary, not the other one.
///
/// Whether *any other* builder (`SceneBuilder`, `CommandsBuilder`,
/// `RegexComponentBuilder`, a custom type, ...) shares this capability is
/// unproven and not assumed — `isInsideKnownOptionalCapableResultBuilderBody`
/// below recognizes only an *explicit* `@ViewBuilder` attribute spelling,
/// deliberately narrower than `OperatorExclusions.hasBuilderAttribute`'s
/// own multi-name match, and deliberately not the structural
/// property-name fallback (`var body: some View` with no attribute at
/// all) either — that fallback only signals "probably some result
/// builder", never *which one*, so it cannot serve as proof of
/// `ViewBuilder` specifically and stays conservatively excluded. Broadening
/// past `ViewBuilder` requires the same fixture-pair proof for each
/// additional builder family, not a blanket allowlist.
///
/// Deliberately local to this operator, not folded into
/// `OperatorExclusions.isInsideResultBuilderBody` itself: that helper's
/// other callers (`SideEffectCallRemovalOperator`, every schemata lowerer)
/// have a different safety concern — any rewrite inside *any* result
/// builder body risks breaking that builder's own transform in ways this
/// `buildOptional`-specific proof says nothing about for them.
///
/// **`defaultEnabled: false`, `confidence: .experimental`.** A brand-new
/// operator with no Muter analogue — held to the same bar every other
/// unvalidated operator in this catalog is.
///
/// **Known, corpus-measured compile-risk gap:**
/// `isSafePosition` above guards exactly one completeness hazard — the
/// deleted `else` being the block's own implicit-return/missing-return value
/// at the *last* statement of a non-`Void` function. It has **no guard at
/// all** for a `let`/`var` binding, or a `self` stored property/`self.init`
/// delegation, that becomes definitely-initialized only because *both* the
/// `if` and `else` branches assign it — regardless of position within the
/// block. A real-build sweep of 19 candidates from a `swift-argument-parser`
/// sample found 10 (52.6%) actually fail to compile this way (8
/// definite-assignment, 2 initializer-completeness); a second, structurally
/// unrelated corpus (`swift-syntax`'s `SwiftParser`, 25 candidates)
/// confirmed the pattern is not project-specific — 20 (80.0%), all
/// definite-assignment. See
/// `ElseClauseDeletionCompileCorrectnessAcceptanceTests` for two RED
/// fixtures reproducing both classes. A narrow syntax-local guard
/// cannot close this gap without either missing real unsound candidates
/// (a diverging `throw`/`return`/`fatalError` in the deleted branch shares
/// no assignment target with the `if`-branch to key off of) or rejecting
/// real safe ones that share the identical "both branches assign the same
/// target" surface form (`elements[key] = ...`, a `var` already holding a
/// value from its own declaration). Closing this correctly needs a
/// backward-scope-declaration walk plus a control-flow-divergence
/// classifier — real, bounded, pure-syntax work, but a new capability class
/// beyond this operator's existing node-local checks, deliberately not
/// undertaken here. **This is exactly the risk `defaultEnabled: false`/
/// `confidence: .experimental` exists to contain — every mutant this
/// produces from the pattern above is correctly reported `unviable`
/// (confirmed via `mutantkit reproduce --run` against real corpus mutation
/// IDs), never miscounted as `survived`.**
public struct ElseClauseDeletionOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "swift.core.else-clause-deletion",
        version: 1,
        category: "conditional",
        summary: "Deletes an `if` expression's trailing `else` clause.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            A dropped `else` branch (a merge conflict that lost one side, a refactor that \
            inlined the `if` but missed the `else`) means the fallback/alternate path never \
            runs — the condition's false case silently does nothing instead, with no type \
            error and no obviously wrong shape to catch in review. A suite that only \
            asserts "some outcome happened" rather than which branch produced it will not \
            notice the `else` is gone.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
            guard let elseBody = node.elseBody else { return .visitChildren }
            guard !Self.isVacuousElseBody(elseBody) else { return .visitChildren }
            guard !OperatorExclusions.isExcluded(node) else { return .visitChildren }
            guard Self.chainIsUsedAsStatement(node) else {
                return .visitChildren
            }
            if OperatorExclusions.isInsideResultBuilderBody(Syntax(node)),
               !Self.isInsideKnownOptionalCapableResultBuilderBody(Syntax(node)) {
                return .visitChildren
            }

            record(MutationCandidate(
                node: node,
                replacementText: Self.withoutElse(node),
                note: "Removes the `else` clause; when the condition is false, nothing runs instead of the `else` branch's code."
            ))

            // The inner `if` of an `else if` is itself a child of this
            // node's `elseBody` and is visited independently as its own
            // candidate — both levels of a chain are genuinely distinct
            // mutations (see the type's doc comment), so children must
            // still be walked.
            return .visitChildren
        }

        /// An `else` clause with nothing meaningful inside it (`else { }`,
        /// or `else { /* comment only */ }`) is a no-op today: removing it
        /// changes no observable behavior, so the resulting "mutant" is
        /// equivalent to the original and can never be killed by any test
        /// suite — pure noise in a mutation report, not a fault a missing
        /// suite could reveal. Only the *specific* `elseBody` being deleted
        /// by this candidate is checked: in an `else if` chain, each level
        /// is visited (and recorded) independently, so a shallower level's
        /// `elseBody` is the nested `IfExprSyntax` for the next `else if`,
        /// never a bare `CodeBlockSyntax` — that shape is never vacuous
        /// (it still evaluates the next condition and may run its branch),
        /// only the innermost, catch-all `else { ... }` can be. Trivia
        /// (whitespace, comments) is deliberately not considered "content":
        /// `CodeBlockItemListSyntax.isEmpty` already ignores it, since
        /// trivia produces no runtime difference either.
        private static func isVacuousElseBody(_ elseBody: IfExprSyntax.ElseBody) -> Bool {
            guard case let .codeBlock(block) = elseBody else { return false }
            return block.statements.isEmpty
        }

        /// The chain's outermost `if` is the only place a value-position
        /// use (an `if` expression, not statement) can be detected: a
        /// nested `else if`'s own direct parent is always the outer
        /// `IfExprSyntax` it hangs off of (its `elseBody` slot), never a
        /// `CodeBlockItemSyntax`, regardless of how the whole chain is
        /// used. Climbing through every `IfExprSyntax` ancestor lands on
        /// that outermost node, whose parent *does* reflect the chain's
        /// real position — except that position is never `CodeBlockItemSyntax`
        /// directly: SwiftParser wraps a statement-position `if` in an
        /// `ExpressionStmtSyntax` first (`CodeBlockItemSyntax` →
        /// `ExpressionStmtSyntax` → `IfExprSyntax`), one layer this design's
        /// earlier draft missed.
        private static func chainIsUsedAsStatement(_ node: IfExprSyntax) -> Bool {
            var top = Syntax(node)
            while let parent = top.parent, parent.is(IfExprSyntax.self) {
                top = parent
            }
            guard let statementWrapper = top.parent?.as(ExpressionStmtSyntax.self) else { return false }

            // `retry: if condition { ... } else { ... }` is a legal labeled
            // `if` statement — `if` is one of the statement kinds Swift
            // allows a label on, same as a loop. A codex review of the
            // first version of this check found it missed exactly this:
            // the `ExpressionStmtSyntax` sits inside a `LabeledStmtSyntax`
            // wrapper before `CodeBlockItemSyntax`, so an unconditional
            // "parent must be CodeBlockItemSyntax" rejected every labeled
            // `if`, even though deleting its `else` is exactly as safe as
            // an unlabeled one's.
            let statementParent = Syntax(statementWrapper).parent
            let labeled = statementParent?.as(LabeledStmtSyntax.self)
            let itemCandidate = labeled.flatMap { Syntax($0).parent } ?? statementParent
            guard let item = itemCandidate?.as(CodeBlockItemSyntax.self) else { return false }

            return item.parent?.is(CodeBlockItemListSyntax.self) == true && Self.isSafePosition(of: item)
        }

        /// `if`-as-a-statement being used is necessary but not sufficient:
        /// a second codex review found the `if`/`else` chain can still make
        /// removal uncompilable when it is the *last* item of its enclosing
        /// block, two separate ways syntax alone can't always rule out —
        /// **(a)** it is silently the block's implicit return value (a
        /// single-expression, non-`Void` function/closure/property body,
        /// Swift 5.9's `if`-expression rule), and **(b)** even when each
        /// branch already has its own explicit `return`/`throw`, a
        /// non-`Void` function requires *every* path to return — deleting
        /// the trailing `else` leaves the condition's `false` path falling
        /// off the end of the function with nothing, "missing return in
        /// function expected to return 'T'" (confirmed with a full `swiftc`
        /// compile, not just `-typecheck`, which does not catch this class
        /// of error at all). Both hazards apply only to the *last* item of
        /// a block, so a non-last item is always safe regardless of
        /// declaration kind. A last item is safe only in the one shape this
        /// checks directly — a `FunctionDeclSyntax` with no `-> T` at all
        /// (implicit `Void`, which needs no return and cannot be an
        /// implicit-return value position either) — every other enclosing
        /// shape (explicit non-`Void` function, `init`, computed property,
        /// closure, subscript, or anything unrecognized) is conservatively
        /// excluded when the candidate is last, the same
        /// favor-false-negatives-over-broken-mutants trade-off this
        /// catalog's quality gate expects.
        private static func isSafePosition(of item: CodeBlockItemSyntax) -> Bool {
            guard let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return false }
            guard list.last?.id == item.id else { return true }

            guard let codeBlock = list.parent?.as(CodeBlockSyntax.self),
                  let function = codeBlock.parent?.as(FunctionDeclSyntax.self)
            else { return false }
            return function.signature.returnClause == nil
        }

        /// The capability-proven exception to the result-builder exclusion
        /// above — see the type's own doc comment for the full fixture
        /// evidence. Climbs every enclosing scope exactly like
        /// `OperatorExclusions.isInsideResultBuilderBody` does, but only
        /// ever matches an *explicit* `@ViewBuilder` attribute spelling,
        /// never the structural property-name fallback (which cannot say
        /// *which* builder is in play, only that one is likely present).
        private static func isInsideKnownOptionalCapableResultBuilderBody(_ node: Syntax) -> Bool {
            var current: Syntax? = node
            while let scope = current {
                if Self.hasExplicitViewBuilderAttribute(scope) { return true }
                current = scope.parent
            }
            return false
        }

        /// Checks the same three declaration shapes
        /// `OperatorExclusions.hasBuilderAttribute` does (a function, an
        /// accessor, or the enclosing `VariableDeclSyntax` for an implicit
        /// getter), but matches only the single name `"ViewBuilder"` —
        /// proven, not merely assumed, to implement `buildOptional` (real
        /// SwiftUI `-typecheck` evidence, see the type's own doc comment).
        /// A module-qualified spelling (`@SwiftUI.ViewBuilder`) is not
        /// recognized here either, the same accepted gap
        /// `OperatorExclusions.hasBuilderAttribute` already documents (its
        /// `attributeName` parses as a `MemberTypeSyntax`, not an
        /// `IdentifierTypeSyntax`) — missing this only ever costs a safe
        /// candidate, never admits an unproven one.
        private static func hasExplicitViewBuilderAttribute(_ node: Syntax) -> Bool {
            let attributes: AttributeListSyntax
            if let function = node.as(FunctionDeclSyntax.self) {
                attributes = function.attributes
            } else if let accessor = node.as(AccessorDeclSyntax.self) {
                attributes = accessor.attributes
            } else if let variable = node.as(VariableDeclSyntax.self) {
                attributes = variable.attributes
            } else {
                return false
            }
            return attributes.contains { element in
                guard let attribute = element.as(AttributeSyntax.self),
                      let name = attribute.attributeName.as(IdentifierTypeSyntax.self)
                else { return false }
                return name.name.text == "ViewBuilder"
            }
        }

        /// Everything from the node's own start through `body`'s trimmed
        /// end, verbatim — the condition, both braces, and every byte of
        /// the `if` branch's own trivia (including comments) survive
        /// untouched. Everything from there on (the trivia before `else`,
        /// `else` itself, and the entire `elseBody`) is simply not
        /// included in the replacement.
        private static func withoutElse(_ node: IfExprSyntax) -> String {
            let nodeStart = node.positionAfterSkippingLeadingTrivia.utf8Offset
            let bodyEnd = node.body.endPositionBeforeTrailingTrivia.utf8Offset - nodeStart
            let fullText = Array(node.trimmedDescription.utf8)
            return String(decoding: fullText[0 ..< bodyEnd], as: UTF8.self)
        }
    }
}
