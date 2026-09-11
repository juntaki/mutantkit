import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes the `id:` argument from a `.task(id:)`/`.task(id:priority:)`
/// SwiftUI view modifier call, so the view's async task never restarts when
/// its identity-driving input changes.
///
/// **Fault contract.** A SwiftUI view remains alive while an input identity
/// changes, but asynchronous work that should restart for the new input does
/// not restart because `.task(id:)` was weakened to plain `.task`:
///
/// ```swift
/// .task(id: item.id) {
///     await reload(item)
/// }
/// ```
/// mutated to:
/// ```swift
/// .task {
///     await reload(item)
/// }
/// ```
///
/// **Fault evidence.** `zubair-io/Maple` PR #3018 (merge commit
/// `68c9f5614f2b3a7e92cfb7a35be9c9ac7b753dee`) fixes exactly this bug, in
/// production code, described in the PR's own body as **BLOCKING**:
/// `MuiRemoteImage`'s `@StateObject` controller captured `tiers` once at
/// first `init`, and its `.task { }` had no `id:`, so SwiftUI reusing the
/// view (List cells, record updates) with different tiers never updated the
/// displayed image. The fix changes `.task { await controller.start() }` to
/// `.task(id: tiers.ordered.map(\.1)) { await controller.start(tiers: tiers) }`
/// — this operator mutates back to the pre-fix state, dropping only the
/// `id:` argument (`tiers.ordered.map(\.1)`), never touching the closure
/// body or turning the call into a different modifier entirely. A dedicated
/// test in that PR (`testStartWithDifferentTiersResetsStateAndLoadsTheNewTiers`)
/// exercises the *controller's* restart behavior directly; see this
/// operator's own `faultEvidence` below for why that is a materially
/// different claim than "the View's `.task(id:)` modifier itself was
/// observed to restart," and what that gap means for this operator's
/// promotion state.
///
/// **Deliberately narrow v1 matcher, symbol-blind by construction (no
/// symbol resolution, matching every other operator in this catalog):**
///
/// 1. A call whose member name is exactly `task` (`member.declName.baseName.text
///    == "task"`), with a trailing closure present (`node.trailingClosure != nil`)
///    and no additional trailing closures. A bare `.task { ... }` with zero
///    arguments has no `FunctionCallExprSyntax.arguments` for this operator to
///    remove and is excluded by construction (nothing here to delete); an
///    unrelated method that merely happens to be named `task` (a project's own
///    queue/executor API, say) is symbol-blind, exactly like every other
///    method-name match in this catalog — an accepted, unmeasured risk, not
///    one this v1 attempts to rule out.
/// 2. Exactly one or two arguments, in this exact order: the first labeled
///    `id`, and — if a second argument exists at all — the second labeled
///    `priority`. Any other label, order, or argument count (a hypothetical
///    third argument, `priority` before `id`, a differently-labeled first
///    argument) is excluded outright: none of those is the real
///    `task(id:priority:_:)` overload's argument order, so mutating them
///    would not model this fault and risks not compiling at all under a
///    name-alike API this operator cannot see past.
///
/// **Replacement.** The matched `id:` argument is deleted; everything else is
/// carried over unmodified — the closure body byte-for-byte, the `priority:`
/// argument (if present) untouched including its own expression, and the
/// surrounding modifier chain. When `id:` was the *only* argument, the
/// now-empty parameter list's parentheses are also removed (`.task(id: x) { }`
/// becomes `.task { }`, not `.task() { }` — matching the real, idiomatic
/// zero-argument call shape SwiftUI code actually uses, confirmed directly
/// against a real `swiftc` compile that `.task() { }` and `.task { }` are
/// both accepted, but only the parenthesis-free form is the shape a human
/// author (and this operator's own fault evidence) actually writes). When
/// `priority:` remains, the parentheses and that single argument are kept,
/// with its own trailing comma removed so the result is exactly
/// `.task(priority: x) { }`, not `.task(priority: x,) { }`.
///
/// **Compile-safety reasoning, verified directly against a real `swiftc`
/// compile, not assumed** (see
/// `TaskIDRemovalCompileViabilityAcceptanceTests`): four representative
/// shapes — `.task(id:)` alone, `.task(id:priority:)`, a multiline `id:`
/// expression, and a nested modifier chain — all compile both before and
/// after mutation with zero diagnostics, using real `import SwiftUI` source,
/// not only a fake minimal stand-in. Removing `id:` (and optionally
/// `priority:`) from `task(id:priority:_:) -> some View` can never introduce
/// a type-inference or definite-initialization hazard the way
/// `ContinuationResumeRemovalOperator`'s `withCheckedContinuation` guard or
/// `RequiredDecodeIntroductionOperator`'s generic-`T` reasoning need to
/// consider: `task(id:priority:_:)`'s generic `ID: Equatable` parameter is
/// pinned entirely by the deleted `id:` argument's own expression, not by
/// anything the surrounding call depends on afterward, and the zero-argument
/// `task(priority:_:)` / `task(_:)` overloads SwiftUI already ships are
/// simply different, already-valid overloads of the same method name — this
/// operator's mutated call resolves to one of those, never to a shape with no
/// matching overload at all.
///
/// **Accepted, unmeasured risk: name-only matching.** No symbol resolution
/// confirms the receiver is actually a SwiftUI `View`, so a project's own
/// unrelated `.task(id:)`-shaped API (a custom scheduling/queue type, a test
/// helper) would also match. Per this catalog's symbol-blind design, this is
/// an accepted risk rather than one this v1 attempts to rule out; see this
/// operator's own `faultEvidence` and its corpus-validation document for
/// whether this materialized on real code, and by how much.
///
/// **`defaultEnabled: false`, `confidence: .experimental`, `schemataEligible:
/// false`.** See this type's own `faultEvidence` for the corpus-validation
/// evidence and promotion decision as of the 2026-09 round.
public struct TaskIDRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.swiftui.task-id-removal",
        version: 1,
        category: "swiftui",
        summary: "Removes the `id:` argument from `.task(id:)`, so the task never restarts " +
            "when its identity-driving input changes.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            zubair-io/Maple PR #3018 (merge commit 68c9f5614f2b3a7e92cfb7a35be9c9ac7b753dee), \
            BLOCKING finding: MuiRemoteImage's @StateObject controller captured tiers once at \
            first init, and its `.task { }` had no `id:`, so SwiftUI reusing the view (List \
            cells, record updates) with different tiers never updated the displayed image. \
            Fixed by `.task(id: tiers.ordered.map(\\.1)) { await controller.start(tiers: tiers) }` \
            -- this operator mutates back to exactly the pre-fix state. See this type's own doc \
            comment for the full matcher and compile-safety reasoning (verified against real \
            swiftc, including real `import SwiftUI` source, not only a fake minimal stand-in). \
            Corpus-measured 2026-09 on zubair-io/Maple's MapleUI package (SHA \
            c7b58159e3deac11198791276faf7c12f105a7c3): 4/4 real production `.task(id:)` \
            candidates discovered (MuiAvatar.body, MuiImage.body, MuiRemoteImage.body, \
            MuiBotOutput.body), all compile-viable (4/4 built, 0 build failures), 0/4 killed, \
            0/4 had their `id` expression actually change value during the run -- a real, \
            coverage-instrumented rerun (swiftpm-codecov-per-test) classified 3/4 as `noCoverage` \
            outright and the fourth (MuiImage.body) as coverage-attribution-ambiguous (see this \
            operator's own corpus document for why that fourth result is treated as unresolved, \
            not as a real execution). Manually confirmed by direct source inspection, not assumed: \
            none of the four Views is ever constructed by MapleUITests (no ViewInspector/snapshot/UI \
            host exists in this package), so `body` -- and therefore the `.task`/`.task(id:)` call \
            site itself -- structurally cannot execute under this project's plain XCTest suite, \
            regardless of what this operator does to it. Two of the four (MuiRemoteImage, \
            MuiBotOutput) have their *underlying* async method (`MuiRemoteImageController \
            .start(tiers:)`, `MuiBotOutputController.reveal(...)`) called directly and well-tested \
            by dedicated tests, including the PR's own new cancellation/reset test -- but those \
            tests bypass the View's `body`/`.task` modifier entirely, so they cannot observe this \
            operator's mutation either. This is exactly the structural gap this operator's own task \
            contract names in advance: source candidate exists and the mutant compiles, but no test \
            in this corpus ever reaches the point where changed SwiftUI identity semantics could be \
            exercised. A second corpus (standalone fixture, disclosed as authored, not real-world \
            evidence) demonstrates the operator's compile viability and matcher precision hold \
            outside Maple's own codebase, and constructively shows what a killing test for this \
            fault shape would need to look like (something that can observe restart-vs-no-restart, \
            which no plain XCTest can do against a real `View.body` without a live SwiftUI host). \
            Promotion decision: C, remain experimental -- 0 of the 4 real candidates ever executed \
            even once, a stronger and more definitive absence-of-signal than \
            apple.concurrency.post-await-cancellation-guard-removal's own 0/5-killed-but-covered \
            result was held to before landing at the same decision. Full evidence: internal \
            corpus-validation research for this operator (not part of this public repo).
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
                  member.declName.baseName.text == "task",
                  node.trailingClosure != nil,
                  node.additionalTrailingClosures.isEmpty
            else { return .visitChildren }

            guard let priorityArgument = Self.matchedPriorityArgument(node) else { return .visitChildren }

            record(MutationCandidate(
                node: node,
                replacementText: Self.replacementText(for: node, keeping: priorityArgument),
                note: "Removes the id: argument from .task(id:), so the task never restarts " +
                    "when its identity-driving input changes."
            ))

            return .visitChildren
        }

        /// Recognizes exactly `.task(id:)` (returns `.some(nil)`) or
        /// `.task(id:priority:)` (returns `.some(priorityArgument)`) — any
        /// other argument count, label, or order returns `nil` and excludes
        /// the call. The outer optional distinguishes "not a match at all"
        /// from "matched, no priority: to keep".
        private static func matchedPriorityArgument(_ node: FunctionCallExprSyntax) -> LabeledExprSyntax?? {
            let arguments = Array(node.arguments)
            guard !arguments.isEmpty, arguments.count <= 2 else { return nil }
            guard arguments[0].label?.text == "id" else { return nil }
            if arguments.count == 1 { return .some(nil) }
            guard arguments[1].label?.text == "priority" else { return nil }
            return .some(arguments[1])
        }

        /// `.task { body }` when `priorityArgument` is `nil` (no remaining
        /// argument, so the parentheses are dropped entirely — the real,
        /// idiomatic zero-argument shape, not `.task() { }`); `.task(priority:
        /// p) { body }` when it is not — same base expression, trailing
        /// closure, and every other trivia detail carried over unmodified,
        /// only the argument list (and, in the no-priority case, the
        /// parentheses) changed.
        private static func replacementText(for node: FunctionCallExprSyntax, keeping priorityArgument: LabeledExprSyntax?) -> String {
            guard let priorityArgument else {
                let closure = node.trailingClosure.map { closure -> ClosureExprSyntax in
                    closure.with(\.leftBrace, closure.leftBrace.with(\.leadingTrivia, .spaces(1)))
                }
                let newCall = node
                    .with(\.leftParen, nil)
                    .with(\.arguments, LabeledExprListSyntax([]))
                    .with(\.rightParen, nil)
                    .with(\.trailingClosure, closure)
                return newCall.trimmedDescription
            }

            let keptArgument = priorityArgument
                .with(\.leadingTrivia, [])
                .with(\.trailingComma, nil)
            let newCall = node.with(\.arguments, LabeledExprListSyntax([keptArgument]))
            return newCall.trimmedDescription
        }
    }
}
