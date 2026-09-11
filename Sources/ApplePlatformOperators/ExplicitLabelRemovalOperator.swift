import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes an explicit SwiftUI `.accessibilityLabel(...)` modifier call by
/// replacing the whole call expression with its own receiver (base)
/// expression — not by deleting a containing statement — so a view that
/// depends on an explicit accessible name loses it, leaving the realized
/// accessibility element unnamed, incorrectly named, or dependent on
/// incidental child/system semantics.
///
/// **Fault contract.**
/// ```swift
/// Button {
///     close()
/// } label: {
///     CloseGlyph()
/// }
/// .accessibilityLabel("Close")
/// ```
/// mutated to:
/// ```swift
/// Button {
///     close()
/// } label: {
///     CloseGlyph()
/// }
/// ```
///
/// **Fault evidence.** RevenueCat/purchases-ios PR #7357: a real,
/// community-reported VoiceOver failure on an icon-only button; the
/// production fix adds an explicit `.accessibilityLabel(...)`, and the
/// project subsequently added a real XCUITest/AX-tree regression path
/// demonstrating RED/GREEN when that label is removed — the project's own
/// methodological finding was that unit/view-model tests can prove which
/// label string *would be* derived, but never that it reaches the realized
/// accessibility tree. Element X iOS PR #5890: an independent accessibility
/// audit adds several more explicit `.accessibilityLabel(...)` calls (avatar
/// edit button, pinned-items "view all" button, pinned-message button),
/// independent evidence that missing explicit labels recur outside
/// RevenueCat. See the internal corpus-validation research for this
/// operator (not part of this public repo) for the full evidence.
///
/// **v1 matcher — SwiftUI modifier call only, symbol-blind by construction
/// (matching every other operator in this catalog):**
///
/// 1. A `FunctionCallExprSyntax` whose called expression is a
///    `MemberAccessExprSyntax` with `declName.baseName.text ==
///    "accessibilityLabel"` and a non-`nil` `base` — the receiver being
///    replaced into. A bare, unqualified `accessibilityLabel(...)` call (no
///    base at all — a free function, never a real SwiftUI modifier shape)
///    has nothing to preserve and is excluded by construction.
/// 2. No argument-shape restriction beyond "at least the call parses" — the
///    canonical `"Close"`, a `Text(...)`, or an arbitrary identifier
///    expression are all accepted without inspecting the argument's type,
///    per the task's own instruction not to special-case the label
///    argument's type absent compiler evidence requiring it.
/// 3. Deliberately excludes: `.accessibilityHint`, `.accessibilityValue`,
///    `.accessibilityIdentifier`, `.accessibilityAddTraits`,
///    `.accessibilityRemoveTraits`, `.accessibilityElement`,
///    `.accessibilityHidden` — none of those base names match
///    `"accessibilityLabel"` exactly, so no explicit exclusion list is
///    needed; the exact-name match already rejects them, and also rejects
///    any identifier that merely *contains* the substring
///    `"accessibilityLabel"` (`declName.baseName.text` is compared for
///    equality, not containment).
/// 4. UIKit/AppKit's `button.accessibilityLabel = "Close"` property
///    assignment is a `SequenceExprSyntax`/`InfixOperatorExprSyntax`
///    assignment, never a `FunctionCallExprSyntax` at all — structurally
///    invisible to this matcher, which only ever visits call expressions.
///    Out of v1 scope by construction, not by an explicit exclusion.
///
/// **Replacement.** The matched call is replaced by its own `base`
/// expression's trimmed source text, verbatim — never by deleting the
/// containing statement. This is the operator's required semantic model
/// (see the task's own point 4): a shape like
/// ```swift
/// apply { view in view.accessibilityLabel(label) }
/// ```
/// becomes
/// ```swift
/// apply { view in view }
/// ```
/// — deleting the whole statement here would leave an empty closure body
/// that no longer returns a `View`, which is not this fault's shape at all.
/// A chained call — `view.accessibilityLabel(label).frame(...)` — is
/// unaffected beyond the matched call itself: `.frame(...)`'s own
/// `MemberAccessExprSyntax.base` is exactly the matched
/// `FunctionCallExprSyntax`, replaced by its own `base`
/// (`view.accessibilityLabel(label)` -> `view`), so the surrounding chain,
/// argument, and closure structure is carried over unmodified — this
/// operator only ever changes the one matched node's own text.
///
/// **Accepted, unmeasured risk: name-only matching.** No symbol resolution
/// confirms the receiver is actually a SwiftUI `View` (or that this project
/// even imports SwiftUI) — a custom, unrelated method literally named
/// `.accessibilityLabel(...)` on some other type is a known potential false
/// positive, per this catalog's symbol-blind design. See this operator's
/// own `faultEvidence` and corpus-validation document for how often this
/// materialized on real code, and by how much.
///
/// **SF Symbol / fallback-name masking — not a matcher concern, a semantic-
/// classification concern.** A view whose child already carries a
/// system-provided default accessibility description (an SF Symbol image,
/// visible text) may remain named after this mutation even with no explicit
/// label at all — the explicit label was semantically redundant in that
/// context, not a matcher defect, and this operator does not special-case
/// or exclude such receivers: doing so would confuse "mutation
/// applicability" with "whether the removed label was semantically
/// necessary here," which the task's own point 10 requires classifying
/// per-survivor from the *realized* accessibility tree, not from source
/// alone. See the corpus document for that classification.
///
/// **`defaultEnabled: false`, `confidence: .experimental`, `schemataEligible:
/// false`.** See this type's own `faultEvidence` for the corpus-validation
/// evidence and promotion decision as of the 2026-09 round.
public struct ExplicitLabelRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.accessibility.explicit-label-removal",
        version: 1,
        category: "accessibility",
        summary: "Removes an explicit `.accessibilityLabel(...)` SwiftUI modifier call, replacing " +
            "it with its own receiver expression, so the realized accessibility element loses its " +
            "explicitly-supplied name.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            RevenueCat/purchases-ios PR #7357: a real, community-reported VoiceOver failure on an \
            icon-only button, fixed in production by adding an explicit SwiftUI \
            `.accessibilityLabel(...)`; the project subsequently added a real XCUITest/AX-tree \
            validation path and demonstrated RED/GREEN when that label is removed. Methodological \
            finding carried into this operator's own design: unit/view-model tests can prove which \
            label string is derived, but never that it reaches the realized accessibility tree -- \
            only a real XCUITest/AX-tree assertion can. Element X iOS PR #5890: an independent \
            accessibility audit adds several more explicit `.accessibilityLabel(...)` calls (avatar \
            edit button, pinned-items "view all" button, pinned-message button), independent \
            real-fault evidence that missing explicit labels recur outside RevenueCat. Full \
            corpus evidence, including the internal Phase 5A fixture's operator-generated (not \
            hand-applied) kill, external-project preflights, survivor classification, and the \
            adversarial self-review: internal corpus-validation research for this operator \
            (not part of this public repo).
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
                  member.declName.baseName.text == "accessibilityLabel",
                  let base = member.base
            else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: base.trimmedDescription,
                note: "Removes the explicit `.accessibilityLabel(...)` modifier; the realized " +
                    "accessibility element loses its explicitly-supplied name."
            ))

            // Children are still walked: an argument expression to this very
            // call (e.g. a nested `Text(...)`) cannot itself be another
            // `.accessibilityLabel(...)` receiver chain member of *this*
            // call, but a sibling subtree elsewhere in the base expression
            // (a chained call further to the left) may still contain its
            // own, independently-removable `.accessibilityLabel(...)` site.
            return .visitChildren
        }
    }
}
