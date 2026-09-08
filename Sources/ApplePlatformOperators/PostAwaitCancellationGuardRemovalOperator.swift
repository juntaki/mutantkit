import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes the canonical post-await cancellation guard —
/// `guard !Task.isCancelled else { return }` — when it immediately follows a
/// code-block item that itself contains an `await`. Without it, a cancelled
/// async operation that nonetheless returns a (possibly stale) result gets
/// published or acted on anyway.
///
/// **Fault evidence.** Two real, independently-authored bug-fix PRs add
/// exactly this guard shape, in exactly this position, for exactly this
/// reason:
///
/// - `zubair-io/Maple` PR #3018 (merge commit
///   `68c9f5614f2b3a7e92cfb7a35be9c9ac7b753dee`): `MuiAvatar.loadPhoto()`
///   gains `let image = await MuiPlatformImage.load(from: url); guard
///   !Task.isCancelled else { return }` — the PR body states this "mirrors
///   the existing pattern in `MuiImage.load()`, so a stale decode can't
///   stomp a newer load's state." The same PR's `MuiRemoteImageController
///   .start(tiers:)` adds the identical guard directly after `let loaded =
///   try? await loader(url)`, with the PR's own comment: "a
///   non-cooperatively-cancelled loader can still return a value —
///   publishing it would overwrite the newer load's state with a stale
///   tier." A dedicated test in that PR
///   (`testCancellationStopsTheTierLoopAndLeavesIsErrorFalse`) drives a
///   cancellation mid-await and asserts the guarded code never runs.
/// - `whysasse/verso-app` PR #375 (merge commit
///   `0b6153b5c5cef3d83c6dc3b57772b172db8f839a`): `AddArticleView.save()`
///   gains `let pending = try await parserService.parse(url: url); guard
///   !Task.isCancelled else { return }`, with the PR's own comment: "the
///   user cancelled via the ✕ while this was in flight -- don't silently
///   land the save (or show a failure screen) on a dismissed sheet." The
///   same PR adds the identical guard as the first statement of two sibling
///   `catch` blocks (after a `try await` that threw) and of two further
///   near-duplicate `apply...` functions — five occurrences of the same
///   shape in one PR, all for the same reason.
///
/// Both PRs independently reach for the same three-part shape (await, then
/// `guard !Task.isCancelled else { return }`, then the code that must not
/// run late) to fix a *shipped* bug, not a hypothetical one — this operator
/// mutates back to the pre-fix state.
///
/// **Deliberately narrow v1 matcher.** Recognizes only:
///
/// 1. A standalone `guard` statement (`GuardStmtSyntax`).
/// 2. Exactly one condition, which is the direct negation of
///    `Task.isCancelled`: a `PrefixOperatorExprSyntax` with operator `!`
///    whose operand is a `MemberAccessExprSyntax` `isCancelled` member off a
///    bare `Task` identifier (`DeclReferenceExprSyntax`), name-matched only
///    like every other operator in this catalog (no symbol resolution, so a
///    locally-shadowed `Task` type is an accepted, unmeasured risk — the
///    same trade this catalog always makes). This structurally excludes
///    `if Task.isCancelled { return }` (a different statement kind, never
///    visited by this check at all — confirmed directly: parsing `if
///    Task.isCancelled { return }` produces no `GuardStmtSyntax` node
///    whatsoever), `guard !foo.isCancelled else { return }` (base identifier
///    is not `Task`), and any logical compound (`guard !Task.isCancelled &&
///    foo else { return }` parses its condition as a raw, unfolded
///    `SequenceExprSyntax`, not a `PrefixOperatorExprSyntax` — confirmed
///    directly; this operator does not fold sequences the way
///    `RequiredDecodeIntroductionOperator` does, so a compound condition is
///    excluded by construction, not by an explicit check). A guard with more
///    than one condition (`guard !Task.isCancelled, let x = y else { ... }`)
///    is excluded the same way: `conditions.count` must be exactly 1. Since
///    the only condition shape accepted is a bare expression, not an
///    optional-binding pattern, this guard can never introduce a binding —
///    "no bindings introduced" is a structural consequence of this check,
///    not a separate one.
/// 3. The `else` body is exactly one statement, a bare `return` with no
///    expression (`ReturnStmtSyntax` with `expression == nil`). This
///    excludes any `else` that runs cleanup before returning (`guard
///    !Task.isCancelled else { cleanup(); return }`) — a real shape this
///    operator deliberately does not touch, because deleting the guard there
///    would also delete `cleanup()`, a second, unrelated fault this operator
///    does not claim to model.
/// 4. The guard is not the first item of its enclosing `CodeBlockItemList`
///    (there is an immediately preceding sibling item), and that preceding
///    item's subtree contains at least one `AwaitExprSyntax` anywhere within
///    it (a plain `let value = await load()` satisfies this directly; a `for
///    x in xs { ... await ... }` loop immediately before the guard also
///    satisfies it, matching the real shape in Maple PR #3018's tier loop,
///    where the loop body's own `await` is what the following guard is
///    reacting to — checked by subtree search, not "is itself an
///    `AwaitExprSyntax`", deliberately looser than "is" to cover this real
///    corpus shape). A guard with no preceding item at all (first statement
///    of its block, as in Maple's own per-iteration `guard
///    !Task.isCancelled else { return }` placed *before* that iteration's
///    `await`) is excluded — that check is defending against cancellation
///    *before* work starts, a different, narrower fault than the one this
///    operator targets (late publication *after* an await returns), and is
///    out of scope by the task contract. **A real corpus finding, not a
///    fixture-only edge case:** the identical "no preceding item" exclusion
///    also fires for `whysasse/verso-app` PR #375's own `catch` blocks --
///    `do { let pending = try await parse(url); guard !Task.isCancelled else
///    { return }; ... } catch { guard !Task.isCancelled else { return };
///    errorMessage = ...; viewState = .failure }` -- the `do` block's guard
///    (after its own preceding `try await`) is a candidate, but the `catch`
///    block's guard, despite following a `try await` that *threw*, is not:
///    it is the first item of the `catch` body's own `CodeBlockItemList`,
///    with no sibling in that list to search for an `await` in. Reasoning
///    about a preceding item across the `do`/`catch` boundary would require
///    treating a thrown error as equivalent to a returned one for this
///    guard's purposes -- a second control-flow shape this v1 matcher
///    deliberately does not take on. Confirmed directly against this
///    project's own real shape (see
///    `Research/corpus-validation/post-await-cancellation-guard-removal-2026-09/`'s
///    standalone fixture, modeled on this exact PR): discovery finds the
///    `do` block's guard and skips the `catch` block's, exactly as this
///    reasoning predicts.
///
/// **Why removing this guard never requires a fifth, syntax-shape guard the
/// way the other two operators in this catalog need.** Both
/// `ContinuationResumeRemovalOperator` and `RequiredDecodeIntroductionOperator`
/// need extra exclusions because their mutation can *empty a block to zero
/// statements* (switch case, implicit-parameter closure) or *break generic
/// inference* that depended on the exact expression removed. Neither hazard
/// can occur here, verified directly against a real `swiftc` compile across
/// five representative shapes (plain `async` function, `async throws`
/// function, a `for` loop body, a `switch` case, and a `Task { }` closure —
/// see `PostAwaitCancellationGuardRemovalCompileViabilityAcceptanceTests`):
///
/// - **The block can never become empty.** Constraint 4 above requires a
///   preceding sibling item to exist and remain in place — removing the
///   guard always leaves at least that one statement behind. This is exactly
///   why this operator needs no switch-case-sole-statement guard (unlike
///   `ContinuationResumeRemovalOperator`'s guard 2): the shape this operator
///   matches can never be a `switch` case's *sole* statement, because a sole
///   statement has no preceding sibling to search for an `await` in.
/// - **The block can never be a single-expression implicit-return closure.**
///   That shape requires the closure's body to contain exactly one
///   statement, which is an expression, not a `guard`; a closure containing
///   both the required preceding item and this guard already has at least
///   two statements, so it is never eligible for implicit single-expression
///   return in the first place. This is exactly why this operator needs no
///   implicit-parameter-closure guard (unlike `ContinuationResumeRemovalOperator`'s
///   guard 3).
/// - **No generic-inference hazard exists.** Removing a `guard` statement
///   removes no expression any surrounding generic call depends on for type
///   inference — `Task.isCancelled` and a bare `return` both stand outside
///   any such inference chain by construction. This is exactly why this
///   operator needs no `withCheckedContinuation`-style guard (unlike
///   `ContinuationResumeRemovalOperator`'s guard 4).
/// - **No definite-initialization or missing-return hazard exists.** The
///   `else` body being a *bare* `return` (constraint 3) means the guard's
///   own immediate function-like context already returns `Void` (a bare
///   `return` is only legal there) — so removing this early-return path can
///   never turn a `Void`-returning context into one missing a value, unlike
///   `ElseClauseDeletionOperator`'s known non-`Void`/definite-assignment gap,
///   which exists precisely because that operator's deleted branch can be
///   the difference between a value existing and not. No binding is
///   introduced by this guard's condition (constraint 2), so there is
///   nothing for later code to depend on being definitely initialized by it
///   either.
///
/// This was reasoned through structurally, then confirmed directly rather
/// than assumed: all five real-`swiftc` compile-viability cases above
/// compile both before and after mutation with zero diagnostics.
///
/// **Replacement.** The entire `guard` statement is deleted
/// (`replacementText: ""`) — its own leading/trailing trivia (the newline
/// and indentation around it) is untouched by this operator (matching every
/// other whole-statement-removal shape in this catalog), so the visible diff
/// is one blank line where the guard used to be, not a byte-for-byte
/// realignment of neighboring code.
///
/// **Accepted, unmeasured risk: name-only matching.** No symbol resolution
/// confirms the receiver is actually the stdlib `Task` type or that
/// `isCancelled` is actually `Task.isCancelled: Bool` rather than some
/// unrelated same-named API — matching every other operator in this
/// catalog's `requiresSymbolResolution: false` posture. A false positive
/// here costs one low-value mutant (deleting a statement is always
/// structurally safe by the reasoning above regardless of what `Task`
/// actually resolves to), never a broken build.
///
/// **Expected test surface.** Unlike `ContinuationResumeRemovalOperator`'s
/// dominant `verifiedTimeout` outcome (a dropped `resume()` blocks forward
/// progress entirely), this mutation's fault shape is a stale value or
/// side effect being *published despite* cancellation — the mutated code
/// still returns, still completes, it just does the wrong thing instead of
/// nothing. The natural kill mode is a fast, ordinary assertion against
/// published state after a task is cancelled (closer in shape to
/// `RequiredDecodeIntroductionOperator`'s `keyNotFound` than to
/// `ContinuationResumeRemovalOperator`'s hang), not a timeout — reasoned
/// from the fault's own semantics, then checked against real corpus
/// evidence rather than assumed; see this type's `faultEvidence` for
/// whether that held.
///
/// **`defaultEnabled: false`, `confidence: .experimental`, `schemataEligible:
/// false` — landed and stays here after corpus validation (2026-09),
/// promotion decision C, not B.** Compile safety is clean: two real corpora
/// (`zubair-io/Maple`'s `MapleUI` package, full 5/5 candidates; a
/// standalone fixture built to isolate one specific structural finding,
/// 4/4 candidates) together report zero `unviable`, zero
/// `infrastructureFailure`, zero integrity violations. But the one *real*
/// project run (`MapleUI`) showed **0/5 killed** — every real candidate
/// survived, each individually root-caused as either a genuine absence of a
/// targeted test or a guard masked by an unmutated sibling guard, never a
/// matcher defect. The only observed kills came from the standalone
/// fixture, which was authored specifically to produce them and is
/// disclosed as such — not independent real-world evidence. Per this
/// catalog's own promotion bar, "empirically useful" real-world signal
/// requires a real project's real test to have actually caught a real
/// instance of the mutation; that did not happen this round. See
/// `Research/corpus-validation/post-await-cancellation-guard-removal-2026-09/`
/// for the full per-candidate accounting, the search performed for a second
/// real corpus, and the adversarial review that reached this conclusion.
public struct PostAwaitCancellationGuardRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.concurrency.post-await-cancellation-guard-removal",
        version: 1,
        category: "concurrency",
        summary: "Removes a post-await `guard !Task.isCancelled else { return }`, " +
            "so a cancelled task's stale result is published anyway.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            zubair-io/Maple PR #3018 (merge commit 68c9f5614f2b3a7e92cfb7a35be9c9ac7b753dee): \
            MuiAvatar.loadPhoto() and MuiRemoteImageController.start(tiers:) both add \
            `guard !Task.isCancelled else { return }` immediately after an `await`, explicitly \
            "so a stale decode can't stomp a newer load's state" / "publishing it would overwrite \
            the newer load's state with a stale tier" (PR body, verbatim), with a dedicated test \
            (testCancellationStopsTheTierLoopAndLeavesIsErrorFalse) driving a real cancellation \
            mid-await. whysasse/verso-app PR #375 (merge commit \
            0b6153b5c5cef3d83c6dc3b57772b172db8f839a): AddArticleView.save() and three sibling \
            functions add the identical guard after a `try await parse(...)` / in the matching \
            `catch`, explicitly "don't silently land the save (or show a failure screen) on a \
            dismissed sheet" (PR body, verbatim) -- five occurrences of the same shape in one PR. \
            Both PRs independently converge on the same three-part shape (await, then \
            `guard !Task.isCancelled else { return }`, then code that must not run late) to fix a \
            shipped bug. See this type's own doc comment for the full narrow-matcher reasoning and \
            the direct swiftc compile-viability evidence (five representative shapes, zero \
            diagnostics before or after mutation). Corpus-measured 2026-09 on zubair-io/Maple's \
            MapleUI package (SHA c7b58159e3deac11198791276faf7c12f105a7c3, full 5/5 candidates: \
            0 killed, 5 survived -- each individually root-caused as a genuine test gap or a \
            guard masked by an unmutated sibling guard, never a matcher defect; 0 unviable, \
            0 infrastructureFailure) and a standalone fixture built to isolate the masking finding \
            (disclosed as authored, not real-world evidence: 2/4 killed by assertion, both fast, \
            confirming the predicted kill mode; 2/4 survived, reproducing Maple's own masking \
            relationship on purpose). Also found, via this round's corpus work: a guard that is \
            the first statement of a catch body (whysasse/verso-app PR #375's own shape, repeated \
            three times) is excluded by this operator's existing "preceding item" rule, since a \
            catch body's first item has no preceding sibling -- a real, now-documented scope \
            boundary, not a defect. Zero unviable/infrastructureFailure/integrity violations across \
            both corpora (9 candidates total). Promotion decision: C, remain experimental -- not \
            promoted to confidence: .medium, because the one real project run showed 0/5 real \
            kills, and "empirically useful real-world signal" (the bar continuation-resume-removal \
            and required-decode-introduction each cleared before their own promotion) was not met \
            this round. Full evidence, per-candidate accounting, the search performed for a second \
            real corpus, and the adversarial review that reached this conclusion: \
            Research/corpus-validation/post-await-cancellation-guard-removal-2026-09/.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
            guard Self.isNegatedTaskIsCancelledCondition(node),
                  Self.isBareReturnElseBody(node.body),
                  let item = node.parent?.as(CodeBlockItemSyntax.self),
                  let list = item.parent?.as(CodeBlockItemListSyntax.self),
                  let precedingItem = Self.precedingItem(of: item, in: list),
                  Self.containsAwait(Syntax(precedingItem))
            else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: "",
                note: "Removes the post-await cancellation guard, so a cancelled task's " +
                    "result is published or acted on anyway."
            ))

            return .skipChildren
        }

        /// True when `node` has exactly one condition, which is the direct
        /// negation (`!`) of a bare `Task.isCancelled` member access —
        /// name-matched only (`Task` as a plain identifier, `isCancelled` as
        /// its member), no symbol resolution, matching every other check in
        /// this catalog. A compound condition (`&&`), an optional-binding
        /// condition, a differently-named receiver, or a parenthesized
        /// operand (`!(Task.isCancelled)`, confirmed directly to parse its
        /// operand as a `TupleExprSyntax`, not a `MemberAccessExprSyntax`)
        /// all fail this check and are excluded.
        private static func isNegatedTaskIsCancelledCondition(_ node: GuardStmtSyntax) -> Bool {
            guard node.conditions.count == 1, let condition = node.conditions.first else { return false }
            guard case let .expression(expression) = condition.condition else { return false }
            guard let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" else {
                return false
            }
            guard let member = prefix.expression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "isCancelled",
                  let base = member.base?.as(DeclReferenceExprSyntax.self),
                  base.baseName.text == "Task"
            else { return false }
            return true
        }

        /// True when `body` is exactly one statement, a `return` with no
        /// expression. Excludes any `else` that performs cleanup (or returns
        /// a value, which cannot happen in a `Void`-context guard-else
        /// anyway) before returning.
        private static func isBareReturnElseBody(_ body: CodeBlockSyntax) -> Bool {
            guard body.statements.count == 1, let statement = body.statements.first else { return false }
            guard let returnStmt = statement.item.as(ReturnStmtSyntax.self) else { return false }
            return returnStmt.expression == nil
        }

        /// The sibling item immediately before `item` in `list`, or `nil` if
        /// `item` is the list's first element. A guard with no preceding
        /// item is excluded — this operator only targets a guard that
        /// follows work, never one that precedes it.
        private static func precedingItem(of item: CodeBlockItemSyntax, in list: CodeBlockItemListSyntax) -> CodeBlockItemSyntax? {
            var previous: CodeBlockItemSyntax?
            for candidate in list {
                if candidate.id == item.id { return previous }
                previous = candidate
            }
            return nil
        }

        /// True when `syntax`'s subtree contains at least one
        /// `AwaitExprSyntax` anywhere within it — deliberately a subtree
        /// search, not "is itself an await expression", so a `for`/`while`
        /// loop whose body contains an `await` (Maple PR #3018's tier loop:
        /// `let loaded = try? await loader(url)` inside a `for` iteration,
        /// with the guard reacting to that loop's own await) still counts as
        /// a qualifying preceding item.
        private static func containsAwait(_ syntax: Syntax) -> Bool {
            if syntax.is(AwaitExprSyntax.self) { return true }
            return syntax.children(viewMode: .sourceAccurate).contains { containsAwait($0) }
        }
    }
}
