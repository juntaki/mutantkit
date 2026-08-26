import Foundation
import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Embeds `swift.core.arithmetic-operator-replacement` points into a schema
/// binary — behind a closed scoring gate, the same discipline
/// `RelationalOperatorReplacementSchemataLowerer` documents (see
/// `SchemataLowererRegistry.builtIn`'s own doc comment: this type is never
/// listed there in this build, so it is never reached by
/// `SchemataChunkPlanner` in production, only exercised directly by this
/// file's own tests and by a dedicated validation-only registration commit —
/// see `Research/adr-0008-validation/protocol.md`'s "Protocol v2" addendum).
///
/// `ArithmeticOperatorReplacementOperator`'s own doc comment names the exact
/// risk this lowerer exists to route around, not merely note:
/// **the replacement operator is not guaranteed to exist for every type the
/// original operator works on.** `AdditiveArithmetic` requires both `+` and
/// `-` together, so every standard-library-conforming numeric type has both —
/// but `String`/`Array` overload `+` without a matching `-`. `Numeric`
/// requires `*` but not `/` — a bare `T: Numeric` generic parameter has no
/// `/` at all, so `lhs * rhs` mutating to `lhs / rhs` does not compile.
/// **A third asymmetric shape, not named in that doc comment, was found
/// empirically**: a first version of this lowerer that only excluded the two
/// named shapes broke a real chunk build against `apple/swift-algorithms`
/// (`Partition.swift:376`, `let lhsCount = lhs - bufferStart`) —
/// `UnsafeMutablePointer` supports `pointer - pointer` (a distance) but not
/// `pointer + pointer`, and the isolated-vs-schemata differential test this
/// lowerer's qualification pipeline requires caught it before promotion, not
/// after. That finding is why eligibility here proves a *positive*
/// allowlist (`safeArithmeticTypeNames`) rather than excluding known-bad
/// shapes one at a time: excluding shapes only ever catches the shapes
/// someone already thought of.
///
/// Unlike `RelationalOperatorReplacementSchemataLowerer` (where `<`/`>=`'s
/// shared `Bool` result and `Comparable`'s always-paired operators make this
/// a non-issue), this lowerer has no symbol resolution available
/// (`ArithmeticOperatorReplacementOperator.descriptor.requiresSymbolResolution`
/// is `false`, and no such infrastructure exists anywhere in this codebase
/// today) — so "prove the type" means resolving an operand's *declared*
/// type from a parameter, a `self.`-rooted or implicit-`self` stored
/// property, or a local `let`/`var` whose type is explicit or provable by
/// `isProvablyInt`'s bounded, sound recursive rule (literals, `.count`, and
/// `+`/`-`/`*`/`/` chains over such operands) — checked against a small,
/// named-safe allowlist. Every name-shadowing construct this codebase's own
/// grammar exposes (tuple/destructuring patterns, `for`/`guard`/`if case`/
/// `switch case`/`catch` bindings, closure captures, local functions,
/// `guard`'s block-continuation scoping, a bare `catch`'s implicit `error`)
/// stops resolution outright rather than risk silently reading the wrong
/// declaration's type — see `nearestDeclaredType`'s own doc comment for the
/// three rounds of independent Codex review that converged this. A literal
/// operand is proven safe only when paired with a proven-safe non-literal
/// sibling (see `typeVarianceRisk`'s own doc comment for the accepted,
/// differential-tested residual risk this carries, and why it is restored
/// rather than dropped). An operand whose declared type cannot be found this
/// way is rejected, never assumed safe. Each rejection maps to
/// `SchemataUnsupportedReason.typeVarianceUnproven` — "could not prove the
/// active and inactive schema type-check identically at this site" is
/// exactly the honest claim here, not "proven safe."
///
/// Lowering itself otherwise follows `RelationalOperatorReplacementSchemataLowerer`
/// exactly: a direct ternary applying the compiler's own overload resolution
/// to `lhs op rhs` on each branch (never through a generic helper that would
/// force both operands to unify to one type first), selected by the same
/// runtime selector protocol, so `Decimal`-vs-literal contextual typing and
/// any operator overload the original expression already relied on continue
/// to type-check exactly as before.
public struct ArithmeticOperatorReplacementSchemataLowerer: SchemataLowerer {
    public static let lowererID = "swift.core.arithmetic-operator-replacement.schemata"
    public static let lowererVersion = 1
    /// Same v3 runtime protocol every other schemata lowerer in this build
    /// uses — one shared runtime, not a second one invented for this
    /// operator.
    public static let runtimeABIVersion = BoolLiteralSchemataLowerer.runtimeABIVersion

    public let descriptor = SchemataLowererDescriptor(
        lowererID: lowererID, lowererVersion: lowererVersion, runtimeABIVersion: runtimeABIVersion,
        supportedOperatorIDs: [ArithmeticOperatorReplacementOperator.descriptor.id]
    )

    public init() {}

    // MARK: - Eligibility

    public func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility {
        guard point.operatorID == ArithmeticOperatorReplacementOperator.descriptor.id else {
            return .isolatedOnly(reason: .operatorNotYetLowered(operatorID: point.operatorID))
        }

        let verification = SourceAnchorVerifier.verify(point, against: source, depth: .full)
        guard verification.isValid else {
            return .isolatedOnly(reason: .structuralConflict(reason: verification.diagnosis))
        }
        guard let resolved = Self.resolveInfix(for: point, in: source) else {
            return .isolatedOnly(reason: .structuralConflict(reason: "no InfixOperatorExprSyntax parent resolved at the anchor"))
        }
        guard !OperatorExclusions.isInsideResultBuilderBody(Syntax(resolved.infix)) else {
            return .isolatedOnly(reason: .resultBuilderBody)
        }
        // See `RelationalOperatorReplacementSchemataLowerer.isDirectlyWrappedInTryOrAwait`
        // for why this is checked at the infix level in addition to (never
        // instead of) each operand's own check below.
        if Self.isDirectlyWrappedInTryOrAwait(resolved.infix) {
            return .isolatedOnly(reason: .asyncOrThrowingExpression)
        }
        if let reason = Self.unsafetyReason(for: resolved.infix.leftOperand) {
            return .isolatedOnly(reason: reason)
        }
        if let reason = Self.unsafetyReason(for: resolved.infix.rightOperand) {
            return .isolatedOnly(reason: reason)
        }
        if let reason = Self.typeVarianceRisk(
            originalOperator: point.originalText, for: resolved.infix, leftOperand: resolved.infix.leftOperand,
            rightOperand: resolved.infix.rightOperand
        ) {
            return .isolatedOnly(reason: reason)
        }

        let envelope = ByteRange(
            start: resolved.infix.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: resolved.infix.endPositionBeforeTrailingTrivia.utf8Offset
        )
        return .eligible(loweringKind: .expressionTernary, rewriteEnvelope: envelope, conflictKeys: [])
    }

    /// Identical resolution strategy to
    /// `RelationalOperatorReplacementSchemataLowerer.resolveInfix` — the
    /// operator token anchor alone carries no operand information; the infix
    /// parent is where `leftOperand`/`rightOperand` live. Re-parses from
    /// `source` fresh every call, never reuses a tree from an earlier call.
    static func resolveInfix(for point: MutationPoint, in source: Data) -> (infix: InfixOperatorExprSyntax, operatorNode: Syntax)? {
        guard let operatorNode = SourceAnchorVerifier.matchedNode(for: point, in: source),
              let infix = operatorNode.parent?.as(InfixOperatorExprSyntax.self)
        else { return nil }
        return (infix, operatorNode)
    }

    /// `nil` when `operand` is safe to evaluate a second time. Identical
    /// discipline to `RelationalOperatorReplacementSchemataLowerer
    /// .unsafetyReason` — an operand kind not explicitly recognized here
    /// falls back to isolated, never assumed safe.
    private static func unsafetyReason(for operand: ExprSyntax) -> SchemataUnsupportedReason? {
        let unwrapped = Self.unwrapParentheses(operand)

        if let sequence = unwrapped.as(SequenceExprSyntax.self) {
            return .structuralConflict(reason: "unexpected unfolded SequenceExprSyntax: \(sequence.trimmedDescription)")
        }
        if Self.isSafeLeafOperand(unwrapped) {
            return nil
        }
        if let member = unwrapped.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            return Self.unsafetyReason(for: base)
        }
        return Self.unsafeOperandReason(for: unwrapped)
    }

    private static func isSafeLeafOperand(_ unwrapped: ExprSyntax) -> Bool {
        unwrapped.is(DeclReferenceExprSyntax.self) || unwrapped.is(IntegerLiteralExprSyntax.self)
            || unwrapped.is(FloatLiteralExprSyntax.self)
    }

    private static func unsafeOperandReason(for unwrapped: ExprSyntax) -> SchemataUnsupportedReason {
        if unwrapped.is(FunctionCallExprSyntax.self) {
            return .unsupportedOperand(reason: "function call operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(SubscriptCallExprSyntax.self) {
            return .unsupportedOperand(reason: "subscript operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(AwaitExprSyntax.self) || unwrapped.is(TryExprSyntax.self) {
            return .asyncOrThrowingExpression
        }
        if unwrapped.is(ClosureExprSyntax.self) {
            return .unsupportedOperand(reason: "closure operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(OptionalChainingExprSyntax.self) {
            return .unsupportedOperand(reason: "optional-chaining operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(ForceUnwrapExprSyntax.self) {
            return .unsupportedOperand(reason: "force-unwrap operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(MacroExpansionExprSyntax.self) {
            return .unsupportedOperand(reason: "macro-expansion operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(KeyPathExprSyntax.self) {
            return .unsupportedOperand(reason: "key-path operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(InOutExprSyntax.self) {
            return .ownershipSensitiveExpression
        }
        return .unsupportedOperand(reason: "unrecognized operand kind \(unwrapped.kind): \(unwrapped.trimmedDescription)")
    }
}

// MARK: - Type-variance risk (declared-type allowlist)

//
// Split into its own extension purely to keep `type_body_length` reviewable
// per declaration — still the same single type, same access level, no
// behavioral split.
extension ArithmeticOperatorReplacementSchemataLowerer {
    /// Standard-library scalar numeric types whose `+`/`-`/`*`/`/` behave
    /// exactly like the built-in arithmetic this lowerer's ternary shape
    /// assumes — every pair symmetric, no ad hoc single-sided overload.
    /// Deliberately narrow: a type not on this list is never assumed safe by
    /// omission, matching the discipline every other lowerer in this
    /// codebase already uses. `UnsafeMutablePointer`/`UnsafePointer` are
    /// deliberately *not* here — `pointer - pointer` (a valid distance) and
    /// `pointer + pointer` (invalid; only `pointer + Int` compiles) is
    /// exactly the asymmetric-`+`/`-` shape a real differential run against
    /// `apple/swift-algorithms` (`Partition.swift:376`,
    /// `let lhsCount = lhs - bufferStart`) found this lowerer's original,
    /// looser "reject only a literal String/Array operand" check missed —
    /// the chunk build failed with `binary operator '+' cannot be applied to
    /// two 'UnsafeMutablePointer<Self.Element>' operands`, not a per-mutant
    /// isolated result, because both branches of the ternary must compile
    /// for the whole chunk to build at all. That finding is why this
    /// allowlist approach (prove the type, don't just exclude the one
    /// concrete shape already caught by hand) replaced the original
    /// exclusion-only design.
    private static let safeArithmeticTypeNames: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float16", "Float80", "CGFloat", "Decimal"
    ]

    /// Every `+`/`-`/`*`/`/` variant needs both operands proven safe — no
    /// symbol resolution is available anywhere in this codebase, so "proven"
    /// means: a non-literal operand (identifier, `self.` member access, or a
    /// name whose type this file can *bound-recursively infer* — see
    /// `isProvablyInt`) whose own declared type appears on
    /// `safeArithmeticTypeNames`; or an integer *or float* literal
    /// (`declaredSafeType` treats both identically) *paired with* such a
    /// proven-safe non-literal sibling. Two non-literal operands must
    /// resolve to the *identical* type name, not merely two independently
    /// safe ones — a fourth-round independent Codex review found that an
    /// earlier version accepted e.g. `Int` paired with `Double`, which the
    /// stdlib itself never allows for any of these four operators
    /// homogeneously, so an original expression compiling with two
    /// differently-named safe types can only be going through a project-
    /// defined overload with no guarantee the mutated operator has a
    /// matching one. Two rounds of independent Codex
    /// review each targeted this: round 2 found "a literal is unconditionally
    /// safe" wrong (a literal's contextual type can be redirected by a
    /// heterogeneous overload); round 3 then found the "anchor to a
    /// concretely-typed sibling" fix itself theoretically incomplete against
    /// the same overload risk. Between round 3 and this version, real real-
    /// corpus site inspection (`apple/swift-algorithms` `Split.swift:131`,
    /// a real production app's own binary-header-parsing and
    /// binary-search-query source files) found that dropping
    /// literal-anchoring and local-variable resolution entirely — the
    /// round-3 "provably immune" design — leaves *zero* of this validation's
    /// three actual known-hang sites schemata-reachable at all, since every
    /// one of them mixes an integer literal with an un-annotated local or an
    /// implicit-`self` property. A structurally unreachable lowerer is not a
    /// safer one; it is simply useless for the corpus it exists to cover.
    /// Literal-anchoring is restored here as an accepted, differential-
    /// tested residual risk explicitly — not a claim the round-3 concern is
    /// wrong, but a judgment that it is the *same narrow tier* as the
    /// `typealias`-masking gap `declaredType(ofOperand:)` already accepts:
    /// both require a project author to have defined an unusual competing
    /// declaration that essentially never occurs in real code, and both are
    /// caught empirically by this lowerer's qualification differential
    /// before promotion, not eliminated by static proof.
    private static func typeVarianceRisk(
        originalOperator: String, for infix: InfixOperatorExprSyntax, leftOperand: ExprSyntax, rightOperand: ExprSyntax
    ) -> SchemataUnsupportedReason? {
        guard ["+", "-", "*", "/"].contains(originalOperator) else {
            // v1 of the isolated operator only ever pairs `+`<->`-` and
            // `*`<->`/` (see `ArithmeticOperatorReplacementOperator
            // .replacements`) — an unrecognized original operator text is
            // conservatively rejected rather than assumed to be one of
            // those two families.
            return .typeVarianceUnproven
        }
        let left = Self.declaredSafeType(leftOperand)
        let right = Self.declaredSafeType(rightOperand)
        // Two *distinct* named safe types (e.g. `Int` on one side, `Double`
        // on the other) are never accepted, even though each individually
        // sits on `safeArithmeticTypeNames` — found by an independent Codex
        // implementation review: the original code required only that each
        // side individually be "safe," which says nothing about whether the
        // *pair* actually compiles for both `originalOperator` and
        // `point.replacementText`. The stdlib's own arithmetic protocols
        // never mix concrete numeric types this way (`Int + Double` is
        // already a compile error, unconditionally, for any of the four
        // operators), so an original expression that DOES compile with two
        // differently-named safe types must be going through a project-
        // defined custom overload — and nothing proves that overload set is
        // symmetric across `+`/`-`/`*`/`/` the way the stdlib's own
        // protocol-derived overloads are. Requiring the same resolved type
        // name on both non-literal sides keeps every stdlib-numeric case
        // (which is always homogeneous) while closing this gap.
        switch (left, right) {
        case let (.named(leftType), .named(rightType)):
            return leftType == rightType ? nil : .typeVarianceUnproven
        case (.named, .literal), (.literal, .named):
            return nil
        default:
            return .typeVarianceUnproven
        }
    }

    /// A resolved operand's contribution to `typeVarianceRisk`: a literal
    /// has no fixed type of its own (`declaredSafeType` treats an integer
    /// and a float literal identically) and is only ever accepted paired
    /// with a `.named` sibling; `.named` carries the actual resolved type
    /// spelling so `typeVarianceRisk` can require *equality*, not just
    /// independent safety, between two non-literal operands; `.unsafe`
    /// covers everything else (unresolved, or resolved to a type outside
    /// `safeArithmeticTypeNames`).
    private enum OperandSafety: Equatable {
        case named(String)
        case literal
        case unsafe
    }

    /// Every named type spelling is trusted at face value — an in-scope
    /// `typealias Int = String`, a local nominal declaration (`struct Int {
    /// ... }`), or a generic parameter named `Int` could each make an unsafe
    /// type look safe, since no symbol resolution exists anywhere in this
    /// codebase to see through any of them (an independent Codex
    /// implementation review, round 8, confirmed the local-nominal-
    /// declaration and generic-parameter shapes are the same underlying gap
    /// as the already-accepted `typealias` case, not a new one — all three
    /// are just different syntactic vehicles for "a name on
    /// `safeArithmeticTypeNames` was shadowed by something this file has no
    /// way to see"). Intrinsic to the no-resolution approach this lowerer is
    /// built on, not a gap this function could close without that
    /// infrastructure — an accepted, extremely narrow residual risk
    /// (shadowing a standard-library numeric type name this way is
    /// exceptionally rare, unlike-real-world-code Swift), mitigated the same
    /// way every other residual risk here is: the isolated-vs-schemata
    /// differential test and real-project differential, not eliminated by
    /// this check alone.
    private static func declaredSafeType(_ operand: ExprSyntax) -> OperandSafety {
        let unwrapped = Self.unwrapParentheses(operand)
        if unwrapped.is(IntegerLiteralExprSyntax.self) || unwrapped.is(FloatLiteralExprSyntax.self) {
            return .literal
        }
        guard case let .type(typeName) = Self.declaredType(ofOperand: unwrapped) else {
            return .unsafe
        }
        return Self.safeArithmeticTypeNames.contains(typeName) ? .named(typeName) : .unsafe
    }

    /// A name resolution's three possible outcomes — never collapsed to a
    /// plain `String?`, because "this name is bound by something whose type
    /// this file cannot determine" (`.shadowed`) and "this name is not
    /// declared anywhere on the walked path at all" (`.notFound`) must be
    /// distinguished: `.shadowed` stops the outward walk immediately
    /// (silently falling through to an outer scope's same-named declaration
    /// would resolve the *wrong* binding — exactly the class of bug two
    /// rounds of independent Codex review found in earlier versions of this
    /// resolution), while `.notFound` lets the walk continue outward.
    enum NameLookup {
        case type(String)
        case shadowed
        case notFound
    }

    /// Resolves a plain identifier or a `self.`-rooted member access to its
    /// declared type. `self.x` is routed to `declaredType(ofStoredProperty
    /// Named:near:)` only — never the parameter/local search — because
    /// `self.` is Swift's own unambiguous "this is the instance member, not
    /// whatever local happens to share its name" disambiguation; resolving
    /// it through the same name-based parameter/local search a bare
    /// identifier uses would silently prefer a same-named parameter of a
    /// different, possibly-unsafe type (confirmed by this file's own
    /// `selfPropertyShadowedByDifferentlyTypedParameterResolvesToPropertyType`
    /// regression test). A *bare* identifier tries the parameter/local walk
    /// first (`nearestDeclaredType`) and, only when that comes back
    /// `.notFound` — genuinely nothing local shadows or declares this name
    /// anywhere on the walked path — falls back to the same stored-property
    /// lookup `self.x` uses, mirroring Swift's own real implicit-`self`
    /// resolution order (local scope, then instance member) rather than
    /// requiring every property reference in this codebase to spell `self.`
    /// explicitly (the common style in Swift method bodies omits it).
    /// `.shadowed` never falls through to this — a name that *is* some local
    /// construct this file cannot safely type is rejected outright, not
    /// reinterpreted as a property reference it structurally cannot be.
    private static func declaredType(ofOperand operand: ExprSyntax, depth: Int = 0) -> NameLookup {
        if let reference = operand.as(DeclReferenceExprSyntax.self) {
            let local = Self.nearestDeclaredType(ofIdentifier: reference.baseName.text, near: Syntax(operand), depth: depth)
            if case .notFound = local {
                return Self.declaredType(ofStoredPropertyNamed: reference.baseName.text, near: Syntax(operand), depth: depth)
            }
            return local
        }
        if let member = operand.as(MemberAccessExprSyntax.self), member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            return Self.declaredType(ofStoredPropertyNamed: member.declName.baseName.text, near: Syntax(operand), depth: depth)
        }
        return .notFound
    }

    /// Walks the *actual lexical ancestor chain* from `node` outward — never
    /// a whole enclosing scope's full descendant subtree — checking, at each
    /// level, in order: whether this level itself *shadows* `name` via a
    /// binding this file cannot (and, per the round-3 convergence below,
    /// does not even attempt to) type — a `for`/`guard`/`if case`/
    /// `switch case`/`catch` pattern, a closure capture, a local `let`/`var`
    /// of *any* pattern shape, or a local function declaration — which stops
    /// the walk outright; and only then a matching
    /// function/initializer/subscript/closure parameter, the sole remaining
    /// positive type source this function ever returns (`self.`-rooted
    /// stored-property resolution is a separate, parallel path — see
    /// `declaredType(ofOperand:)`). An unrelated sibling block's own items
    /// are never visited at all — a `CodeBlockItemListSyntax` belonging to a
    /// different `if`/`while`/`do` block is never an ancestor of `node` —
    /// fixing a real false-positive an independent Codex implementation
    /// review found in an earlier version of this function, which instead
    /// flattened an *entire* enclosing scope's descendants regardless of
    /// which nested block they actually lived in (see this file's own
    /// `unrelatedNestedBlockShadowingDoesNotFalsePositivelyMatch` regression
    /// test; the shadow-stops-the-walk behavior itself is pinned by
    /// `controlFlowAndClosureCaptureBindingsShadowAnOuterSafeTypeInsteadOfFalsePositivelyResolvingIt`).
    ///
    /// A depth bound applied everywhere `nearestDeclaredType`/`isProvablyInt`
    /// recurse into each other (a local's un-annotated initializer
    /// referencing another local, transitively) — not expected to matter for
    /// any real expression (Swift's own declare-before-use rule already
    /// makes a true cycle impossible to compile), but a hard backstop
    /// against pathological input is cheap insurance against a hang or
    /// stack overflow in a tool that must stay reliable across arbitrary
    /// real source.
    static let maxResolutionDepth = 8

    /// **Round-3-to-round-4 convergence**: round 3 converged on treating
    /// every local as an opaque, un-typed shadow. Real known-hang site
    /// inspection afterward found that design unreachable in practice — real
    /// arithmetic overwhelmingly involves an un-annotated local
    /// (`var splitCount = 0`, `let mid = (low + high) / 2`) or a
    /// `for ... .enumerated()` index, not a bare, explicitly-typed
    /// parameter. Local resolution is restored here with the round-1–3
    /// shadow protections still fully intact (ancestor-only walk, full
    /// pattern-recursive name matching, `guard`'s block-continuation
    /// scoping, local-function/for/if/switch/catch/closure-capture shadow
    /// detection) — a matching local is a positive type source now *only*
    /// when its pattern is a plain (non-tuple, non-destructuring) identifier
    /// and its type comes from an explicit annotation or `isProvablyInt`'s
    /// bounded, sound recursive inference; anything else matching the name
    /// still stops the walk with `.shadowed`, exactly as
    /// before.
    private static func nearestDeclaredType(ofIdentifier name: String, near node: Syntax, depth: Int = 0) -> NameLookup {
        guard depth < maxResolutionDepth else { return .notFound }
        if let enumeratedType = declaredTypeOfEnumeratedForLoopFirstElement(named: name, near: node) {
            return .type(enumeratedType)
        }
        var cursor: Syntax? = node.parent
        while let current = cursor {
            if Self.introducesUnresolvedShadow(named: name, at: current) {
                return .shadowed
            }
            if let type = Self.declaredType(ofParameterNamed: name, in: current) {
                return .type(type)
            }
            if let itemList = current.as(CodeBlockItemListSyntax.self),
               let result = Self.declaredType(ofItemMatching: name, in: itemList, before: node.position, depth: depth) {
                return result
            }
            cursor = current.parent
        }
        return .notFound
    }

    /// One `CodeBlockItemListSyntax`'s own direct items, checked for a
    /// matching local `let`/`var`, local function declaration, or `guard`
    /// binding — split out of `nearestDeclaredType` purely to keep that
    /// function's cyclomatic complexity reviewable, not a behavioral split.
    /// `nil` means "nothing in this specific list matches `name` at all,"
    /// distinct from every `NameLookup` case this can otherwise return.
    ///
    /// Only items whose own position is *before* `before` (the original
    /// reference's position, threaded through unchanged across every
    /// recursive/ancestor call) are ever considered — an independent Codex
    /// implementation review found an earlier version scanned every item in
    /// the block regardless of order, so a `let a: Int` declared *after* an
    /// earlier `a + a` reference to an outer `String` parameter could
    /// incorrectly "resolve" that earlier reference to `Int`. Swift's own
    /// declare-before-use rule makes this comparison sound: nothing later in
    /// the same source position could be what an earlier reference actually
    /// names.
    private static func declaredType(
        ofItemMatching name: String, in itemList: CodeBlockItemListSyntax, before position: AbsolutePosition, depth: Int
    ) -> NameLookup? {
        for item in itemList where item.position < position {
            if let variableDecl = item.item.as(VariableDeclSyntax.self) {
                for binding in variableDecl.bindings where patternBindsName(name, binding.pattern) {
                    guard binding.pattern.is(IdentifierPatternSyntax.self) else { return .shadowed }
                    if let annotation = binding.typeAnnotation {
                        let typeText = annotation.type.trimmedDescription
                        return typeText.isEmpty ? .shadowed : .type(typeText)
                    }
                    if let initializer = binding.initializer?.value, Self.isProvablyInt(initializer, depth: depth + 1) {
                        return .type("Int")
                    }
                    return .shadowed
                }
            }
            if let functionDecl = item.item.as(FunctionDeclSyntax.self), functionDecl.name.text == name {
                return .shadowed
            }
            // `guard let`/`guard case` is the one binding form whose scope
            // is the *rest of this same block*, not a nested body — unlike
            // `if let`/`for`/`switch case`/`catch`, whose bindings only
            // ever live inside their own nested body and are therefore
            // already caught by `introducesUnresolvedShadow` when that
            // nested body's own ancestor chain is walked. A `guard` item is
            // a sibling of the reference here, in the very same list, never
            // an ancestor — so it would otherwise be invisible to this walk
            // entirely (confirmed by this file's own
            // `guardLetBindingShadowsOuterParameter` regression test, which
            // failed without this check).
            if let guardStmt = item.item.as(GuardStmtSyntax.self), Self.conditionsBindName(name, guardStmt.conditions) {
                return .shadowed
            }
        }
        return nil
    }

    /// The one specific for-loop shape this file trusts for a type without
    /// an explicit annotation to inspect: `for (index, x) in seq.enumerated()`
    /// (or any two-element tuple pattern) binds its *first* name to `Int` —
    /// not an inference, a fixed stdlib guarantee
    /// (`EnumeratedSequence.Iterator.Element == (offset: Int, element:
    /// Base.Element)`). Checked before the general shadow walk reaches this
    /// point — the for-loop's own pattern would otherwise correctly (and,
    /// for this one specific case, overly conservatively) shadow the name
    /// via `introducesUnresolvedShadow` — but this walk still runs that same
    /// shadow check itself against every *other* ancestor on the way up to
    /// the enclosing for-loop, so an intervening rebinding of `name` (an
    /// `if let`/`switch case`/`catch`/closure capture between `node` and the
    /// loop) stops the walk rather than being skipped past.
    private static func declaredTypeOfEnumeratedForLoopFirstElement(named name: String, near node: Syntax) -> String? {
        var cursor: Syntax? = node.parent
        while let current = cursor {
            if let forStmt = current.as(ForStmtSyntax.self) {
                if let tuple = forStmt.pattern.as(TuplePatternSyntax.self), tuple.elements.count == 2,
                   let first = tuple.elements.first?.pattern.as(IdentifierPatternSyntax.self), first.identifier.text == name,
                   let call = forStmt.sequence.as(FunctionCallExprSyntax.self),
                   let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                   member.declName.baseName.text == "enumerated", call.arguments.isEmpty,
                   let base = member.base, Self.isProvablyCollectionType(base, depth: 0) {
                    // Requiring the receiver to itself be a recognized
                    // stdlib-collection shape — found by an independent Codex
                    // implementation review: trusting *any* zero-argument
                    // `enumerated()` call by name alone, regardless of its
                    // receiver's type, let a project-defined type with its
                    // own differently-typed `enumerated()` method (e.g.
                    // returning `[(String, Element)]`) qualify its first
                    // tuple element as `Int`. Mirrors the same allowlist
                    // `isProvablyInt`'s own `.count` case already requires —
                    // real-world code essentially never re-overloads
                    // `enumerated()` on `Array`/`String`/`Set`/`Dictionary`.
                    return "Int"
                }
                // Any other for-loop pattern falls through to the ordinary,
                // conservative shadow walk — never assumed safe here.
                return nil
            }
            // A construct between `node` and its enclosing for-loop that
            // itself rebinds `name` (an `if let`/`switch case`/`catch`/
            // closure capture) must shadow the outer loop's index — found by
            // an independent Codex implementation review: this walk
            // previously jumped straight from `node` to the nearest
            // `ForStmtSyntax` ancestor, ignoring any such intervening
            // binding, so `for (index, _) in x.enumerated() { if let index =
            // someString { index + index } }` incorrectly resolved the
            // inner, differently-typed `index` as the outer loop's `Int`.
            // Checked only for non-`ForStmtSyntax` ancestors — the matching
            // for-loop itself is handled by the pattern check above, not by
            // this generic shadow check (which would otherwise treat the
            // for-loop's own intended binding as a shadow of itself).
            if Self.introducesUnresolvedShadow(named: name, at: current) {
                return nil
            }
            cursor = current.parent
        }
        return nil
    }

    /// A small, bounded, *sound* — never a probabilistic guess — recursive
    /// check for "this expression's type is `Int` with no other information
    /// needed": an integer literal (Swift's own `IntegerLiteralType` default
    /// absent other context, the same guarantee `Decimal`/custom-literal-type
    /// contexts could only override with information this function does not
    /// have — see this type's own residual-risk documentation), a
    /// `.count` member access on a base whose own declared type is a
    /// recognized standard-library collection shape (`Collection.count:
    /// Int` is a protocol requirement, but not every type spelling `.count`
    /// is actually a `Collection` — see `isProvablyCollectionType`),
    /// `+`/`-`/`*`/`/` between two such provably-`Int` operands, or an
    /// identifier that this same resolution (recursively) also proves `Int`.
    /// Never infers `Double`/`Float`/etc. — only the one type this
    /// validation's real known-hang sites actually need.
    private static func isProvablyInt(_ expr: ExprSyntax, depth: Int) -> Bool {
        guard depth < maxResolutionDepth else { return false }
        let unwrapped = Self.unwrapParentheses(expr)
        if unwrapped.is(IntegerLiteralExprSyntax.self) {
            return true
        }
        if let member = unwrapped.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "count", let base = member.base,
           Self.isProvablyCollectionType(base, depth: depth + 1) {
            return true
        }
        if let infix = unwrapped.as(InfixOperatorExprSyntax.self),
           let operatorText = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text,
           ["+", "-", "*", "/"].contains(operatorText) {
            return Self.isProvablyInt(infix.leftOperand, depth: depth + 1) && Self.isProvablyInt(infix.rightOperand, depth: depth + 1)
        }
        if let reference = unwrapped.as(DeclReferenceExprSyntax.self) {
            if case .type("Int") = Self.declaredType(ofOperand: ExprSyntax(reference), depth: depth + 1) {
                return true
            }
        }
        return false
    }

    /// Standard-library collection-shaped type spellings whose own `.count`
    /// is a fixed protocol requirement (`Collection.count: Int`) — trusted
    /// only when `base`'s own *declared* type (via the same machinery
    /// `hasProvenSafeType` uses, never an un-annotated inference) is
    /// syntactically one of these. An independent Codex implementation
    /// review found `.count` trusted unconditionally on *any* base was
    /// unsound: a user type can freely declare its own, differently-typed
    /// `count` property (`struct S { var count: String }`), and nothing
    /// about the member-access syntax alone rules that out. This narrows
    /// `.count` back to the one case it is actually guaranteed for, at the
    /// cost of real coverage this validation's own Corpus B site
    /// (`YOMSearchQuery.swift`'s `terms.count`, where `terms` is declared as
    /// a project-specific `FlatbufferVector<...>`, not a standard-library
    /// collection) can no longer reach — falling back to isolated mode
    /// there, not a silently-accepted risk.
    private static let collectionLikeTypeNames: Set<String> = ["String", "Substring", "ContiguousArray", "ArraySlice"]

    private static func isProvablyCollectionType(_ expr: ExprSyntax, depth: Int) -> Bool {
        guard depth < maxResolutionDepth else { return false }
        let unwrapped = Self.unwrapParentheses(expr)
        if unwrapped.is(ArrayExprSyntax.self) || unwrapped.is(StringLiteralExprSyntax.self) {
            return true
        }
        guard case let .type(typeName) = Self.declaredType(ofOperand: unwrapped, depth: depth + 1) else { return false }
        let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return true
        }
        if let genericBase = trimmed.split(separator: "<").first.map(String.init), Self.collectionLikeTypeNames.contains(genericBase) {
            return true
        }
        return Self.collectionLikeTypeNames.contains(trimmed) || trimmed == "Array" || trimmed == "Set" || trimmed == "Dictionary"
    }

    /// Every binding-introducing construct this file recognizes but cannot
    /// extract a type from: a `for` loop's pattern, a `guard`/`if`
    /// optional-binding or pattern-matching condition, a `switch case`
    /// pattern, a `catch` pattern, and a closure's capture list. Found by an
    /// independent Codex implementation review as a real gap in an earlier
    /// version of this file: none of these were recognized at all, so
    /// `nearestDeclaredType` walked straight past them to an outer,
    /// differently-typed declaration of the same name (e.g. `for a in
    /// values { a + a }` inside `func f(a: Int, values: [String])`
    /// incorrectly resolved the loop's own `String` `a` as the outer `Int`
    /// parameter). Each of these binds its name only within its own body —
    /// this function is called once per ancestor level, so a `false` result
    /// here does not mean "safe," only "not a shadow at *this* level";
    /// `nearestDeclaredType` still keeps walking outward when this returns
    /// `false`.
    private static func introducesUnresolvedShadow(named name: String, at current: Syntax) -> Bool {
        if let forStmt = current.as(ForStmtSyntax.self) {
            return patternBindsName(name, forStmt.pattern)
        }
        // `guard let`/`guard case` is deliberately not checked here — its
        // bound variable's scope is the *rest of the enclosing block*, not
        // a nested body, so `GuardStmtSyntax` is never actually an ancestor
        // of the reference it needs to shadow. See the dedicated check in
        // `nearestDeclaredType`'s own `CodeBlockItemListSyntax` handling.
        if let ifExpr = current.as(IfExprSyntax.self) {
            return Self.conditionsBindName(name, ifExpr.conditions)
        }
        if let whileStmt = current.as(WhileStmtSyntax.self) {
            return Self.conditionsBindName(name, whileStmt.conditions)
        }
        if let switchCase = current.as(SwitchCaseSyntax.self) {
            return Self.switchCaseBindsName(name, switchCase)
        }
        if let catchClause = current.as(CatchClauseSyntax.self) {
            return Self.catchClauseBindsName(name, catchClause)
        }
        if let closure = current.as(ClosureExprSyntax.self) {
            return Self.closureIntroducesUnresolvedShadow(named: name, closure)
        }
        if let accessor = current.as(AccessorDeclSyntax.self) {
            return Self.accessorIntroducesUnresolvedShadow(named: name, accessor)
        }
        return false
    }

    /// Split out of `introducesUnresolvedShadow` purely to keep that
    /// function's cyclomatic complexity reviewable, not a behavioral split.
    private static func closureIntroducesUnresolvedShadow(named name: String, _ closure: ClosureExprSyntax) -> Bool {
        for capture in closure.signature?.capture?.items ?? [] where capture.name.text == name {
            return true
        }
        // An *untyped* closure parameter matching `name` shadows an outer
        // declaration exactly like any other binding this file cannot type
        // — found by an independent Codex implementation review:
        // `declaredType(ofParameterNamed:in:)` already resolves an
        // *explicitly typed* closure parameter correctly, but for an
        // untyped one it returns `nil` ("not found here"), which
        // `nearestDeclaredType`'s caller previously read as "keep walking
        // outward" rather than "shadowed" — so `{ a, b in a + b }` could
        // resolve its own `a`/`b` to an outer, differently-typed `a: Int,
        // b: Int` parameter of the same name instead of stopping at the
        // closure's own (unknown-typed) parameter. A *typed* closure
        // parameter is deliberately excluded here — it is a genuine
        // positive type source, not a shadow, and
        // `declaredType(ofParameterNamed:in:)` already returns it.
        if let parameters = closure.signature?.parameterClause?.as(ClosureParameterClauseSyntax.self)?.parameters {
            for parameter in parameters where parameter.firstName.text == name && parameter.type == nil {
                return true
            }
        }
        // Shorthand closure parameters (`{ a, b in ... }`, no parentheses)
        // are a structurally distinct syntax node
        // (`ClosureShorthandParameterListSyntax`, not
        // `ClosureParameterClauseSyntax`) and are *never* typed by
        // construction — the grammar has no type-annotation slot for this
        // form at all — so any name match here is unconditionally a shadow.
        if let parameters = closure.signature?.parameterClause?.as(ClosureShorthandParameterListSyntax.self) {
            for parameter in parameters where parameter.name.text == name {
                return true
            }
        }
        return false
    }

    /// An accessor block's own implicit or explicit binding shadows an
    /// outer declaration of the same name — found by an independent Codex
    /// implementation review: `didSet`/`willSet`/`set` introduce
    /// `oldValue`/`newValue` (or an explicit name via `set(newVal)`) that
    /// this file cannot type, but nothing previously stopped the walk here,
    /// so `didSet { oldValue + oldValue }` could fall through to an
    /// identically-named, differently-typed *stored property* elsewhere on
    /// the type and incorrectly qualify the accessor's own implicit binding
    /// as that property's type.
    private static func accessorIntroducesUnresolvedShadow(named name: String, _ accessor: AccessorDeclSyntax) -> Bool {
        if let explicitName = accessor.parameters?.name.text {
            return explicitName == name
        }
        let specifier = accessor.accessorSpecifier.text
        if specifier == "didSet", name == "oldValue" {
            return true
        }
        if specifier == "willSet" || specifier == "set", name == "newValue" {
            return true
        }
        return false
    }

    private static func switchCaseBindsName(_ name: String, _ switchCase: SwitchCaseSyntax) -> Bool {
        for item in switchCase.label.as(SwitchCaseLabelSyntax.self)?.caseItems ?? [] where patternBindsName(name, item.pattern) {
            return true
        }
        return false
    }

    private static func catchClauseBindsName(_ name: String, _ catchClause: CatchClauseSyntax) -> Bool {
        let items = Array(catchClause.catchItems)
        if items.isEmpty {
            // A bare `catch {}` with no explicit pattern still binds the
            // caught error implicitly, as `error: any Error` — round-3
            // Codex implementation review found `catchItems` empty in
            // exactly this shape, so the explicit-pattern loop below would
            // silently see no binding at all here.
            return name == "error"
        }
        for item in items where item.pattern.map({ Self.patternBindsName(name, $0) }) ?? false {
            return true
        }
        return false
    }

    private static func conditionsBindName(_ name: String, _ conditions: ConditionElementListSyntax) -> Bool {
        for condition in conditions {
            switch condition.condition {
            case let .optionalBinding(binding):
                if Self.patternBindsName(name, binding.pattern) { return true }
            case let .matchingPattern(matching):
                if Self.patternBindsName(name, matching.pattern) { return true }
            default:
                continue
            }
        }
        return false
    }

    /// Whether `pattern` binds `name` anywhere within it — a plain
    /// identifier pattern (`a`), or recursively within a tuple/enum-
    /// associated-value/value-binding pattern (`(a, b)`, `.some(let a)`,
    /// `case let a`), by walking every descendant rather than special-
    /// casing each pattern shape individually.
    private static func patternBindsName(_ name: String, _ pattern: some SyntaxProtocol) -> Bool {
        if let identifier = Syntax(pattern).as(IdentifierPatternSyntax.self), identifier.identifier.text == name {
            return true
        }
        for child in pattern.children(viewMode: .sourceAccurate) where Self.patternBindsName(name, child) {
            return true
        }
        return false
    }

    private static func declaredType(ofParameterNamed name: String, in scope: Syntax) -> String? {
        if let function = scope.as(FunctionDeclSyntax.self) {
            return declaredType(ofParameterNamed: name, in: function.signature.parameterClause.parameters)
        }
        if let initializer = scope.as(InitializerDeclSyntax.self) {
            return Self.declaredType(ofParameterNamed: name, in: initializer.signature.parameterClause.parameters)
        }
        if let subscriptDecl = scope.as(SubscriptDeclSyntax.self) {
            return Self.declaredType(ofParameterNamed: name, in: subscriptDecl.parameterClause.parameters)
        }
        if let closure = scope.as(ClosureExprSyntax.self),
           let parameters = closure.signature?.parameterClause?.as(ClosureParameterClauseSyntax.self)?.parameters {
            for parameter in parameters where parameter.firstName.text == name {
                guard let type = parameter.type else { return nil }
                let typeText = type.trimmedDescription
                return typeText.isEmpty ? nil : typeText
            }
        }
        return nil
    }

    private static func declaredType(ofParameterNamed name: String, in parameters: FunctionParameterListSyntax) -> String? {
        for parameter in parameters {
            let matches = parameter.secondName?.text == name || (parameter.secondName == nil && parameter.firstName.text == name)
            if matches {
                let typeText = parameter.type.trimmedDescription
                return typeText.isEmpty ? nil : typeText
            }
        }
        return nil
    }

    static func bindingNames(_ variableDecl: VariableDeclSyntax) -> Set<String> {
        Set(variableDecl.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text })
    }

    /// `nil` when `name` matches a binding in `variableDecl` but neither an
    /// explicit type annotation nor `isProvablyInt`'s bounded inference over
    /// its initializer can type it — distinct from the binding not matching
    /// at all (checked separately via `bindingNames`, before this is ever
    /// called), so the caller can tell "shadowed, type unknown" apart from
    /// "not declared here."
    static func declaredType(ofBindingNamed name: String, in variableDecl: VariableDeclSyntax, depth: Int) -> String? {
        for binding in variableDecl.bindings {
            guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name else { continue }
            if let annotation = binding.typeAnnotation {
                let typeText = annotation.type.trimmedDescription
                return typeText.isEmpty ? nil : typeText
            }
            if let initializer = binding.initializer?.value, Self.isProvablyInt(initializer, depth: depth + 1) {
                return "Int"
            }
            return nil
        }
        return nil
    }
}
