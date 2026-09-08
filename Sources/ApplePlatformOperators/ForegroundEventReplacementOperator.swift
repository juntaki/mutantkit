import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Replaces one of the two exact UIKit lifecycle-notification constants
/// `UIApplication.didBecomeActiveNotification` /
/// `UIApplication.willEnterForegroundNotification` with the other, in either
/// direction. The two constants are NOT semantically equivalent — see below —
/// so this operator models two distinct faults, not one undifferentiated
/// "swap a notification name" mutation.
///
/// **Fault model.**
///
/// - **Variant A: `didBecomeActive -> willEnterForeground`.** Work expected on
///   activation/cold launch is moved to an event that may not be emitted on
///   that path, so required startup/activation work is silently skipped.
///   Real-world evidence: Bugsnag Cocoa's own launch/session regression — a
///   non-UIScene app did not receive `willEnterForegroundNotification` on the
///   affected launch path, while `didBecomeActiveNotification` was emitted as
///   expected. A project that (incorrectly) moved activation-time work from
///   `didBecomeActive` to `willEnterForeground` would silently lose that work
///   on exactly that launch path.
/// - **Variant B: `willEnterForeground -> didBecomeActive`.** Work intended
///   only for a true background-to-foreground transition also runs on
///   activation events that are not foreground entries — e.g. re-activation
///   after a system interruption (a phone call, Control Center, an
///   authentication prompt) or another active-state transition that never
///   left the background. `didBecomeActiveNotification` fires on *every*
///   activation, a strict superset of `willEnterForegroundNotification`'s
///   "returned from the background" case, so this direction can cause
///   foreground-entry-only logic (a refresh, an analytics "session started"
///   event, a permission re-check) to run more often than intended.
///
/// These are genuinely different faults with different real-world
/// consequences (missed work vs. extra work), not two names for the same
/// mutation — corpus statistics and promotion decisions for this operator are
/// kept direction-specific throughout; see this type's own `faultEvidence`
/// and `Research/corpus-validation/foreground-event-replacement-2026-09/`.
///
/// **v1 matcher — exact member access only, two named constants, one type,
/// symbol-blind by construction (no symbol resolution, matching every other
/// operator in this catalog):**
///
/// 1. A `MemberAccessExprSyntax` whose base is a bare, unqualified
///    `DeclReferenceExprSyntax` identifier `UIApplication` — no property
///    access, no computed expression, nothing but the type name itself as a
///    namespace. `NSApplication.didBecomeActiveNotification`, a hypothetical
///    project-local `UIApplication` shadow, and anything not literally
///    `UIApplication.<member>` are excluded by this check alone.
/// 2. The member name is exactly `didBecomeActiveNotification` or
///    `willEnterForegroundNotification` — nothing else. In particular,
///    `didEnterBackgroundNotification`, `willResignActiveNotification`,
///    `willTerminateNotification`, and every other real
///    `UIApplication.*Notification` constant are all excluded outright, as
///    the task explicitly scopes this v1 to only the two constants above —
///    mutating any other pair is a separate, unimplemented fault claim.
///
/// Deliberately NOT matched in v1, each a disclosed, accepted false-negative
/// rather than a broader claim this operator does not yet have evidence for:
///
/// - **Implicit-member (dot-shorthand) syntax** — `.didBecomeActiveNotification`
///   at a `Notification.Name`-typed call site (e.g.
///   `NotificationCenter.default.addObserver(forName: .didBecomeActiveNotification,
///   ...)`), a real and plausibly common shape. Excluded because it has no
///   `UIApplication` base at all to match on structurally — recognizing it
///   would require either symbol/type resolution (`requiresSymbolResolution:
///   false` rules this out) or a name-only guess at any bare
///   `.didBecomeActiveNotification`/`.willEnterForegroundNotification`
///   implicit member anywhere, which risks matching an unrelated type's own
///   same-named static member with no base-type check to narrow it at all —
///   a materially different, unbounded risk profile than requiring the
///   explicit `UIApplication.` qualifier. Left for a future, separately
///   evidenced generalization, exactly as the task instructs "prefer exact
///   member-access syntax."
/// - **The legacy Objective-C-bridged spellings**
///   (`Notification.Name.UIApplicationDidBecomeActive` / their `NSNotification.Name`
///   equivalents) — explicitly out of scope per the task contract.
/// - **`NSApplication`'s AppKit equivalents, Scene-phase events, and every
///   other `UIApplication` lifecycle notification** — all explicitly out of
///   scope per the task contract.
///
/// **Replacement.** Only the member name changes; the base expression
/// (`UIApplication`) and every surrounding token, including any comment or
/// multiline layout around the member-access itself, is left untouched —
/// `MemberAccessExprSyntax.declName`'s base name is swapped in place, so a
/// `let name = UIApplication.didBecomeActiveNotification` becomes `let name =
/// UIApplication.willEnterForegroundNotification` with nothing else in the
/// statement disturbed, and the same holds for a call argument, an array/set
/// literal element, or a value split across lines.
///
/// **Compile-safety reasoning, verified directly against a real `swiftc`
/// compile using the actual `UIKit` module on the current Apple SDK, not
/// assumed** (see `ForegroundEventReplacementCompileViabilityAcceptanceTests`):
/// both `UIApplication.didBecomeActiveNotification` and
/// `UIApplication.willEnterForegroundNotification` are stored, non-generic
/// `static let` properties of type `Notification.Name`, declared on the same
/// type, with identical type and identical availability. Swapping one
/// literal member-access expression for the other, in either direction,
/// changes no type, introduces no generic-inference dependency (unlike
/// `ContinuationResumeRemovalOperator`'s `withCheckedContinuation` hazard),
/// and can never turn a non-empty block into an empty one (unlike
/// `ContinuationResumeRemovalOperator`'s switch-case/implicit-closure
/// hazards) — the replacement is a same-type, same-namespace value swap at an
/// expression position, structurally simpler than every other operator in
/// this Apple-platform catalog family. Every real UIKit-importing case this
/// operator's own RED tests describe (direct call argument, assignment,
/// array/set literal element, multiline member access) was additionally
/// confirmed to compile, in both directions, against the real
/// `iphonesimulator` SDK before landing — see that acceptance suite for the
/// exact invocations. No unviable outcome is expected or was observed in
/// this operator's own corpus (see `faultEvidence`); any future unviable
/// result on this operator would be a genuine surprise warranting individual
/// root-cause, not a shrug.
///
/// **Known-safe, expected special case: both constants intentionally
/// registered together.** Some correct code listens to both
/// `didBecomeActiveNotification` and `willEnterForegroundNotification` for
/// compatibility across lifecycle paths (mirroring this operator's own
/// Variant-A fault evidence — code that must run on *either* path). Mutating
/// one of the two observers in such code can produce "the same notification
/// registered twice" rather than a clean single-event swap — still a
/// meaningful mutant (one required lifecycle path disappears; the other is
/// now handled twice, which duplicate-event guards may mask), but this
/// operator does not special-case, deduplicate, or skip that shape: each
/// constant is still an independent, correctly-typed value swap regardless of
/// what else the surrounding code does with the sibling constant, and the
/// task contract requires this shape be covered by RED tests and reasoned
/// about during corpus survivor classification instead.
///
/// **`defaultEnabled: false`, `confidence: .experimental`, `schemataEligible:
/// false` — landed and stays here after corpus validation (2026-09),
/// promotion decision C, not B.** Both directions were found on real
/// production code in one real project, `segmentio/analytics-swift`
/// (`iOSLifecycleMonitor.swift`, SHA `c9a0d6305ac44dcacffeb450534ee8af214b6607`):
/// full 4/4 candidates run to completion, 3 `killedByAssertion`, 1
/// `survived` (individually root-caused as a genuine equivalent mutant in
/// its exact dispatch context — an already-present sibling `switch` case
/// for the replacement value made the mutated arm unreachable dead code,
/// confirmed by Swift's own documented first-match `switch` semantics, not
/// a matcher defect), zero `unviable`, zero `infrastructureFailure`, zero
/// integrity violations. Both directions have real signal: Variant A
/// (`didBecomeActive -> willEnterForeground`) killed once and survived once
/// (the equivalent-mutant case above); Variant B (`willEnterForeground ->
/// didBecomeActive`) killed both of its candidates. The killing tests
/// exercise a real `wasBackgrounded`-gated state machine through an
/// explicit background-then-foreground sequence, not a bare "did a
/// notification fire" check — classified as a "simulated lifecycle-semantic"
/// kill, stronger than a pure notification-contract test but short of a
/// real app/simulator lifecycle journey (not attempted; building one is out
/// of this task's scope). Two further real candidates
/// (`mixpanel/mixpanel-swift`, `ReactiveX/RxSwift`) were found and
/// investigated but rejected as unreachable without editing the external
/// project's own scheme/test-target configuration, which the task contract
/// forbids — disclosed, not silently excluded. **Not promoted to
/// `confidence: .medium`**: this catalog's own precedent for that promotion
/// (`ContinuationResumeRemovalOperator`, `RequiredDecodeIntroductionOperator`)
/// required two independently-verified real projects; only one was found
/// reachable this round despite a genuine search. Full evidence, the two
/// rejected candidates' own reasoning, and the adversarial review that
/// reached this conclusion:
/// `Research/corpus-validation/foreground-event-replacement-2026-09/`.
public struct ForegroundEventReplacementOperator: MutationOperator {
    /// The two supported constants and the direction each names, matched and
    /// replaced by exact string identity only.
    private enum Constant: String {
        case didBecomeActive = "didBecomeActiveNotification"
        case willEnterForeground = "willEnterForegroundNotification"

        /// The other constant — what this one is replaced with.
        var replacement: Constant {
            switch self {
            case .didBecomeActive: .willEnterForeground
            case .willEnterForeground: .didBecomeActive
            }
        }

        /// Human-readable direction label, for `MutationCandidate.note` and
        /// corpus reporting — kept direction-specific per the task contract,
        /// never collapsed into one aggregate "foreground event swap" label.
        var directionLabel: String {
            switch self {
            case .didBecomeActive: "Variant A (didBecomeActive -> willEnterForeground)"
            case .willEnterForeground: "Variant B (willEnterForeground -> didBecomeActive)"
            }
        }
    }

    public static let descriptor = OperatorDescriptor(
        id: "apple.lifecycle.foreground-event-replacement",
        version: 1,
        category: "lifecycle",
        summary: "Replaces UIApplication.didBecomeActiveNotification with " +
            "willEnterForegroundNotification, or the reverse, so activation and " +
            "true-foreground-entry are confused.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            Two distinct real-world lifecycle-event-confusion faults, kept direction-specific: \
            Variant A (didBecomeActive -> willEnterForeground) is grounded in Bugsnag Cocoa's own \
            launch/session regression, where a non-UIScene app's launch path emitted \
            didBecomeActiveNotification but not willEnterForegroundNotification -- code that \
            (incorrectly) moved required activation-time work onto willEnterForeground would silently \
            skip it on exactly that path. Variant B (willEnterForeground -> didBecomeActive) models \
            foreground-entry-only logic incorrectly running on every activation, including \
            re-activation after a system interruption (a call, Control Center, an authentication \
            prompt) that is not a true background-to-foreground transition. See this type's own doc \
            comment for the full matcher, replacement, and compile-safety reasoning (verified against \
            a real swiftc compile using the actual UIKit module on the current Apple SDK). \
            Corpus-measured 2026-09 on segmentio/analytics-swift's iOSLifecycleMonitor.swift (SHA \
            c9a0d6305ac44dcacffeb450534ee8af214b6607): full 4/4 candidates, 3 killedByAssertion \
            (Variant A: 1/2; Variant B: 2/2), 1 survived (Variant A, individually root-caused as a \
            genuine equivalent mutant -- an already-present sibling switch case for the replacement \
            value made the mutated arm unreachable dead code), 0 unviable, 0 infrastructureFailure, \
            0 integrity violations. The killing tests exercise a real wasBackgrounded-gated state \
            machine through an explicit background-then-foreground sequence, not a bare notification- \
            fired check. Two further real candidates (mixpanel/mixpanel-swift, ReactiveX/RxSwift) were \
            found and investigated but rejected as unreachable without editing the external project's \
            own scheme/test-target configuration. Promotion decision: C, remain experimental -- not \
            promoted to confidence: .medium, because this catalog's own precedent for that promotion \
            required two independently-verified real projects, and only one was found reachable this \
            round despite a genuine search. Full evidence: \
            Research/corpus-validation/foreground-event-replacement-2026-09/.
            """
        ]
    )

    public init() {}

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            guard let base = node.base?.as(DeclReferenceExprSyntax.self),
                  base.baseName.text == "UIApplication",
                  let constant = Constant(rawValue: node.declName.baseName.text)
            else { return .visitChildren }

            let replacement = constant.replacement
            let renamedDeclName = node.declName.with(\.baseName, .identifier(replacement.rawValue))
            let renamedNode = node.with(\.declName, renamedDeclName)

            record(MutationCandidate(
                node: node,
                replacementText: renamedNode.trimmedDescription,
                note: "Replaces UIApplication.\(constant.rawValue) with " +
                    "UIApplication.\(replacement.rawValue) -- \(constant.directionLabel)."
            ))

            return .visitChildren
        }
    }
}
