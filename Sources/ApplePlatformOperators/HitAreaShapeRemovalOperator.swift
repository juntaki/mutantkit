import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes an explicit `.contentShape(Rectangle())` modifier call attached to
/// (or nested inside) a SwiftUI `Button`'s `label:` closure, replacing the
/// whole call expression with its own receiver (base) expression — not by
/// deleting a containing statement — so a control that visually occupies a
/// larger rectangular area loses its explicitly expanded tap/hit area,
/// leaving only its rendered glyph/content pixels hit-testable.
///
/// **Fault contract.**
/// ```swift
/// Button {
///     select()
/// } label: {
///     HStack {
///         Text(name)
///         Spacer()
///         Image(systemName: "chevron.right")
///     }
///     .contentShape(Rectangle())
/// }
/// .buttonStyle(.plain)
/// ```
/// mutated to:
/// ```swift
/// Button {
///     select()
/// } label: {
///     HStack {
///         Text(name)
///         Spacer()
///         Image(systemName: "chevron.right")
///     }
/// }
/// .buttonStyle(.plain)
/// ```
/// Without the explicit content shape, SwiftUI only hit-tests the label's
/// actually-drawn content — the transparent `Spacer`/padding region that was
/// visually part of the row's tap target becomes dead.
///
/// **Fault evidence.** cashubtc/wallet PR #305 (merge commit
/// `c121fe87cdf798f488877c982c6b166315ae6bb2`): a real iOS mint-selector bug
/// — a "liquid glass" pill was drawn across a whole padded frame, but neither
/// the glass fill nor its fallback background expanded the hit area, so only
/// the glyphs inside responded to taps; the fix adds
/// `.contentShape(Rectangle())` directly to the button's label content. The
/// same PR independently moved a `Spacer(minLength: 8)` from outside a
/// `Button` (dead, per the PR's own commit message) to inside it, ahead of
/// its own `.contentShape(Rectangle())` call, so the spacer's width is
/// covered by the expanded hit area too — same fault family, same fix
/// mechanism. cwharris77/depth PR #476 (merge commit
/// `d2f7ed1a577ac596497b3ebd4217e848200bc2d2`, "DEP-281"): five independent
/// picker-sheet/list rows across four files
/// (`HistorySeasonSheet.swift`, `TeamDetailView.swift`, `TeamListView.swift`
/// twice, `SeasonPicker.swift`) share the identical shape — `HStack { Text;
/// Spacer; trailingGlyph }` inside a `Button`'s label, no
/// `.contentShape(Rectangle())` — so the trailing `Spacer`'s transparent
/// stretch between the leading label and the trailing checkmark/percentage
/// never registered a tap; the fix adds `.contentShape(Rectangle())` to each
/// row's label content. Both PRs were verified to exist and merge on GitHub
/// (diffs fetched directly from `patch-diff.githubusercontent.com`) as part
/// of this operator's own research; see
/// `Research/corpus-validation/hit-area-shape-removal-2026-09/README.md` for
/// this operator's own corpus evidence, including which parts of this
/// evidence were externally re-verified (cloned/built/tested) versus cited
/// from the diff alone.
///
/// **v1 matcher — SwiftUI modifier call only, symbol-blind by construction
/// (matching every other operator in this catalog):**
///
/// 1. A `FunctionCallExprSyntax` whose called expression is a
///    `MemberAccessExprSyntax` with `declName.baseName.text ==
///    "contentShape"` and a non-`nil` `base` — the receiver being replaced
///    into.
/// 2. Exactly one, unlabeled argument whose expression is itself a
///    zero-argument call to `Rectangle()` (bare `DeclReferenceExprSyntax` or
///    a qualified `MemberAccessExprSyntax`, e.g. `SwiftUI.Rectangle()`) —
///    the *exact* shape named in the task's own fault contract. This
///    deliberately excludes the `eoFill:`-taking overload
///    (`.contentShape(Rectangle(), eoFill: true)`) and the
///    `ContentShapeKinds`-taking overload
///    (`.contentShape(.dragPreview, Rectangle())`) by construction: neither
///    has `Rectangle()` as its sole, unlabeled argument, so this matcher
///    never has to special-case drag-preview, context-menu-preview, or
///    non-tap-interaction content shapes — see the task's own point 6.
/// 3. `Circle()`, `Capsule()`, `RoundedRectangle(...)`, or any other shape
///    expression is rejected by the same argument check (its called
///    expression's base name is not exactly `"Rectangle"`, or it is not a
///    zero-argument call at all) — these may encode intentionally
///    nonrectangular interaction semantics, per the task's own point 6, and
///    are excluded by construction rather than by an explicit denylist.
/// 4. **Button-ancestry requirement** (the task's own point 5: "if robust
///    Button-ancestry detection is practical with SwiftSyntax, v1 SHOULD
///    require it" — it is practical here, so v1 requires it). The matched
///    call must satisfy one of two independent conditions, both symbol-blind
///    and both discovered necessary against real code during this
///    operator's own corpus audit (see the corpus document) rather than
///    invented up front:
///    - **Nested inside the label closure.** A `ClosureExprSyntax` ancestor
///      that is itself the `label:` closure of an enclosing `Button(...)`
///      call, recognized in three shapes:
///      - *Two-trailing-closure form* (`Button { action } label: { content }`):
///        the closure is a `MultipleTrailingClosureElementSyntax` whose
///        `label` token reads `"label"`.
///      - *Labeled-argument form* (`Button(action: { ... }, label: { ... })`):
///        the closure is the expression of a `LabeledExprSyntax` whose own
///        `label` token reads `"label"`.
///      - *Single-trailing-closure-with-an-`action:`-argument form*
///        (`Button(action: onTap) { content }`): the closure is the call's
///        sole trailing closure, with no `label:` tag at all (Swift's
///        trailing-closure sugar drops the label for the one remaining
///        closure parameter once `action:` is already supplied as an
///        ordinary argument) — recognized only when the call's own
///        argument list actually contains an `action:`-labeled argument,
///        which is what tells this apart from a bare `Button { action }`
///        whose sole trailing closure is the *action*, not the label
///        (found on real code: cwharris77/depth's `DepthTopNavToolbar.swift`).
///      The ancestor walk does not stop at the first closure boundary
///      crossed — a `.contentShape(Rectangle())` nested inside an
///      intermediate `VStack { ... }` (or any other non-`Button` closure)
///      still finds its enclosing `Button` label further up the same chain.
///      It does stop being satisfied by a closure that is a `Button`'s
///      *action* closure (the first, unlabeled trailing closure of a
///      two-trailing-closure call, or a bare single trailing closure with
///      no `action:` argument on the call): a `.contentShape(Rectangle())`
///      written inside a button's action body is not this fault's shape.
///    - **Chained directly onto the Button call's own result**, e.g.
///      `Button { ... } label: { ... }.contentShape(Rectangle())` — the
///      matched call's receiver chain, walked back through each
///      `MemberAccessExprSyntax` base, roots in a call to `Button(...)`.
///      Semantically the same fault (expanding the button's own realized
///      tap area) at a different, equally real syntactic position (found on
///      real code: cwharris77/depth's `DepthSegmentedControl.swift`).
/// 5. **`.buttonStyle(.plain)` is not a matcher condition.** Per the task's
///    own point 15, many real hit-area bugs occur specifically with
///    `.plain` (system/default button styles often already supply their own
///    broad hit region, masking this fault), but this v1 matcher does not
///    require it — narrowing to only `.plain`-styled buttons would require
///    either symbol resolution (to know a style modifier really targets
///    this `Button`) or a fragile sibling-syntax heuristic, and the task's
///    own corpus evidence (both cited PRs) did not show non-`.plain`
///    candidates to be materially more likely to be false positives. See
///    the corpus document for how this played out on real code.
///
/// **Replacement.** The matched call is replaced by its own `base`
/// expression's trimmed source text, verbatim — never by deleting the
/// containing statement, mirroring `ExplicitLabelRemovalOperator`'s
/// receiver-preserving strategy exactly, which the task requires for
/// compile safety in closure-return / trailing-modifier-chain contexts (a
/// content shape modifier is very often the last call in a `some View`
/// closure body; deleting the whole statement there would delete the only
/// return expression).
///
/// **Accepted, unmeasured risk: name-only matching.** No symbol resolution
/// confirms the receiver is actually a SwiftUI `View`, that the enclosing
/// `Button(...)` call actually resolves to `SwiftUI.Button`, or that
/// `Rectangle()` resolves to `SwiftUI.Rectangle` rather than some unrelated
/// type of the same name — a custom, unrelated method literally named
/// `.contentShape(...)` on some other type, taking an argument literally
/// named `Rectangle()`, inside a call to some other type literally named
/// `Button`, is a known potential (if narrow) false positive, per this
/// catalog's symbol-blind design. See this operator's own `faultEvidence`
/// and corpus-validation document for how often anything like this
/// materialized on real code.
///
/// **`defaultEnabled: false`, `confidence: .experimental`, `schemataEligible:
/// false`.** See this type's own `faultEvidence` for the corpus-validation
/// evidence and promotion decision as of the 2026-09 round.
public struct HitAreaShapeRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.swiftui.hit-area-shape-removal",
        version: 1,
        category: "swiftui",
        summary: "Removes an explicit `.contentShape(Rectangle())` modifier call attached to a " +
            "SwiftUI Button's label content, replacing it with its own receiver expression, so the " +
            "control's realized tap area shrinks to only its rendered glyph/content pixels.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            cashubtc/wallet PR #305 (merge commit c121fe87cdf798f488877c982c6b166315ae6bb2): a real \
            iOS mint-selector bug -- a "liquid glass" pill drawn across a whole padded frame did not \
            expand its own hit area, so only the glyphs inside registered taps; the production fix \
            adds `.contentShape(Rectangle())` directly to the button's label content, and separately \
            moves a `Spacer(minLength: 8)` inside the same button ahead of that content shape so the \
            spacer's width is also covered. cwharris77/depth PR #476 (merge commit \
            d2f7ed1a577ac596497b3ebd4217e848200bc2d2, "DEP-281"): five independent picker-sheet/list \
            rows across four files share the identical `HStack { Text; Spacer; trailingGlyph }` \
            inside a `Button` label with no `.contentShape(Rectangle())`, so the trailing Spacer's \
            transparent stretch never registered a tap; the fix adds `.contentShape(Rectangle())` to \
            every affected row. Both PRs were independently confirmed to exist and be merged on \
            GitHub as part of this operator's own research (not fabricated); see this operator's \
            own corpus-validation document for exactly which parts of this evidence were externally \
            re-verified end to end (clone/build/test) versus cited from the diff alone, the internal \
            Phase 5A fixture's operator-generated (not hand-applied) kill, survivor classification, \
            and the adversarial self-review: \
            Research/corpus-validation/hit-area-shape-removal-2026-09/.
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
                  member.declName.baseName.text == "contentShape",
                  let base = member.base,
                  Self.hasExactRectangleArgument(node),
                  Self.isInsideButtonLabel(node) || Self.isChainRootedInButtonCall(base)
            else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: base.trimmedDescription,
                note: "Removes the explicit `.contentShape(Rectangle())` modifier from a Button's " +
                    "label content; the realized tap area shrinks to only the label's rendered content."
            ))

            // Children are still walked: a nested view builder inside this
            // very call's own argument list (there is none for a bare
            // `Rectangle()`, but a sibling subtree elsewhere in the base
            // expression -- a chained call further to the left, or another
            // Button entirely -- may still contain its own, independently
            // removable `.contentShape(Rectangle())` site.
            return .visitChildren
        }

        /// Exactly one unlabeled argument, a zero-argument call to
        /// `Rectangle()` (bare or qualified). See this type's own doc
        /// comment, matcher point 2, for why this rejects the `eoFill:` and
        /// `ContentShapeKinds` overloads by construction.
        private static func hasExactRectangleArgument(_ call: FunctionCallExprSyntax) -> Bool {
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil,
                  let shapeCall = argument.expression.as(FunctionCallExprSyntax.self),
                  shapeCall.arguments.isEmpty
            else { return false }

            if let decl = shapeCall.calledExpression.as(DeclReferenceExprSyntax.self) {
                return decl.baseName.text == "Rectangle"
            }
            if let member = shapeCall.calledExpression.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text == "Rectangle"
            }
            return false
        }

        /// Walks every ancestor of `node`, without stopping at the first
        /// closure boundary crossed, looking for a `ClosureExprSyntax` that
        /// is itself a `Button`'s `label:` closure. See this type's own doc
        /// comment, matcher point 4, for the two closure shapes recognized
        /// and why the walk does not stop early.
        private static func isInsideButtonLabel(_ node: some SyntaxProtocol) -> Bool {
            var current: Syntax? = Syntax(node)
            while let candidate = current {
                if let closure = candidate.as(ClosureExprSyntax.self), isButtonLabelClosure(closure) {
                    return true
                }
                current = candidate.parent
            }
            return false
        }

        private static func isButtonLabelClosure(_ closure: ClosureExprSyntax) -> Bool {
            guard let parent = closure.parent else { return false }

            // `Button { action } label: { content }` — the second, labeled
            // trailing closure.
            if let element = parent.as(MultipleTrailingClosureElementSyntax.self) {
                guard element.label.text == "label",
                      let call = element.parent?.parent?.as(FunctionCallExprSyntax.self)
                else { return false }
                return isButtonCall(call)
            }

            // `Button(action: { ... }, label: { ... })` — an ordinary
            // labeled argument whose value happens to be a closure.
            if let labeledExpr = parent.as(LabeledExprSyntax.self) {
                guard labeledExpr.label?.text == "label",
                      let call = labeledExpr.parent?.parent?.as(FunctionCallExprSyntax.self)
                else { return false }
                return isButtonCall(call)
            }

            // `Button(action: onTap) { content }` — a *single* trailing
            // closure with no `label:` tag at all, because the call already
            // supplies `action:` as an ordinary (non-closure) argument, so
            // Swift's trailing-closure sugar drops the label for the one
            // remaining closure parameter. Discovered on real code
            // (cwharris77/depth's `DepthTopNavToolbar.swift`) during this
            // operator's own corpus audit: a bare `Button { ... }` (whose
            // sole trailing closure is the *action*, matcher point 4's
            // action-closure exclusion) is syntactically identical at this
            // node -- the presence of a real `action:` argument on the call
            // is what tells them apart without symbol resolution.
            if let call = parent.as(FunctionCallExprSyntax.self), call.trailingClosure?.id == closure.id {
                guard isButtonCall(call) else { return false }
                return call.arguments.contains { $0.label?.text == "action" }
            }

            return false
        }

        private static func isButtonCall(_ call: FunctionCallExprSyntax) -> Bool {
            if let decl = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return decl.baseName.text == "Button"
            }
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text == "Button"
            }
            return false
        }

        /// True when `expr`, or the call at the root of its own modifier
        /// chain (walking back through `base` on each `MemberAccessExprSyntax`
        /// receiver), is itself a call to `Button(...)`. Covers
        /// `.contentShape(Rectangle())` chained directly onto a Button's own
        /// result -- e.g. `Button { ... } label: { ... }.contentShape(Rectangle())`
        /// -- rather than nested inside the label closure itself. Discovered
        /// on real code (cwharris77/depth's `DepthSegmentedControl.swift`)
        /// during this operator's own corpus audit: semantically the same
        /// fault (expanding the Button's own realized tap area), attached at
        /// a different, equally real syntactic position.
        private static func isChainRootedInButtonCall(_ expr: ExprSyntax) -> Bool {
            guard let call = expr.as(FunctionCallExprSyntax.self) else { return false }
            if isButtonCall(call) { return true }
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  let base = member.base
            else { return false }
            return isChainRootedInButtonCall(base)
        }
    }
}
