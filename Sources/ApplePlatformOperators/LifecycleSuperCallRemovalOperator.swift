import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Removes the `super` call from an overridden UIKit/AppKit lifecycle method.
///
/// Forgetting `super.viewDidLoad()` is a real and recurring Apple-platform
/// defect: the code compiles, most of the screen works, and the breakage is
/// partial and state-dependent. A suite that never notices the omission is not
/// exercising the lifecycle at all.
///
/// **This type is a design/extension-point demonstration only. It is not
/// currently reachable from the CLI in any way** — `MutationRegistry` does not
/// import this module or list this operator in `builtIn`, so neither
/// `profile: experimental` nor an explicit `operators.enable:
/// [apple.lifecycle.super-call-removal]` can select it; `enable` would throw
/// an "unknown operator" error today. It has no RED tests: unlike every
/// operator in `SwiftCoreOperators`, there is no
/// `LifecycleSuperCallRemovalOperatorREDTests.swift` proving the `super`-call
/// discovery logic above actually matches (and only matches) what it claims
/// to. What exists here is the extension point — a demonstration that a
/// platform-specific operator needs nothing from the core beyond the same
/// `MutationOperator` protocol the core operators use.
///
/// The design is explicit that Apple-specific operators must be derived from
/// real bug-fix commits in shipping open-source apps, the way MDroid+ derived
/// its Android operators from a classified corpus of real faults. That study
/// has not been run yet. Before this operator could actually ship as
/// `experimental`, it would need: the fault study backing `faultEvidence`
/// below, real RED tests (positive/negative fixtures, `MutationID`
/// stability) mirroring an existing `SwiftCoreOperators` REDTests file, and
/// registry wiring — importing `ApplePlatformOperators` in
/// `MutationRegistry.swift` and adding this type to `builtIn`. Until all of
/// that lands, it stays exactly what it is today: a demonstration of the
/// extension point, compiled but unregistered.
public struct LifecycleSuperCallRemovalOperator: MutationOperator {
    public static let descriptor = OperatorDescriptor(
        id: "apple.lifecycle.super-call-removal",
        version: 1,
        category: "lifecycle",
        summary: "Removes the `super` call from an overridden view/scene lifecycle method.",
        defaultEnabled: false,
        confidence: .experimental,
        schemataEligible: false,
        requiresSymbolResolution: false,
        faultEvidence: [
            """
            PENDING FAULT STUDY. This operator is a plausible fault model, not yet an \
            evidence-backed one: no bug-fix commit corpus has been classified for it. It \
            must not be promoted to a default operator until real fixes from shipping apps \
            are collected and converted into fixtures.
            """
        ]
    )

    public init() {}

    /// Overridable methods where omitting `super` is known to break behaviour
    /// rather than merely being stylistically wrong.
    ///
    /// Matched on name only. Resolving the actual superclass would need a type
    /// checker, and discovery deliberately runs without one — a false positive
    /// here costs one `unviable` or one uninteresting survivor, which is a much
    /// cheaper failure than making planning depend on a working build.
    private static let lifecycleMethods: Set<String> = [
        "viewDidLoad",
        "viewWillAppear",
        "viewDidAppear",
        "viewWillDisappear",
        "viewDidDisappear",
        "viewWillLayoutSubviews",
        "viewDidLayoutSubviews",
        "viewSafeAreaInsetsDidChange",
        "updateViewConstraints",
        "didReceiveMemoryWarning",
        "layoutSubviews",
        "updateConstraints",
        "awakeFromNib",
        "prepareForReuse",
        "didMoveToSuperview",
        "didMoveToWindow",
        "traitCollectionDidChange"
    ]

    public func discover(in context: MutationContext) throws -> [MutationCandidate] {
        let visitor = Visitor(viewMode: .sourceAccurate)
        return visitor.collect(from: context)
    }

    private final class Visitor: MutationCandidateVisitor {
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  member.base?.is(SuperExprSyntax.self) == true
            else { return .visitChildren }

            let calledName = member.declName.baseName.text
            guard LifecycleSuperCallRemovalOperator.lifecycleMethods.contains(calledName) else {
                return .visitChildren
            }

            // Only remove the call when it is a statement in its own right.
            // `let x = super.layoutSubviews()` is not something we can delete
            // without leaving code that does not compile.
            guard node.parent?.is(CodeBlockItemSyntax.self) == true else { return .visitChildren }

            // The replacement is empty text, and the anchor excludes trivia, so
            // the surrounding indentation and newline survive — the line simply
            // goes blank, which is still valid Swift.
            record(MutationCandidate(
                node: node,
                replacementText: "",
                note: "Removes `super.\(calledName)()`, so the superclass's lifecycle work never runs."
            ))

            return .skipChildren
        }
    }
}
